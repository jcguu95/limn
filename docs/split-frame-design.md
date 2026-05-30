# split-frame-design.md

多 `DocumentView`(per-window)重構 —— 設計與分階段計畫。起於 v0.39.x sprint。

本文件是 C++ Qt 層(`MainWidget`、`DocumentView`、`PdfViewOpenGLWidget`、
`LimnCommand`、`LimnWindowRegistry`)與 Lisp 層(`backend/limn-pdf-mode.lisp`、
`limn-runtime.lisp`)之間的工作契約,目標是把現有的「單一 `DocumentView`」viewport
改造成真正的「每個 window 各自一份 `DocumentView`」的 widget tree。

## 架構決策(已定案,勿再翻案)

> 這一段是整份文件最重要的前提。後面所有階段都建立在這兩個決定上。

### 決策一 —— Single Process(單一程序)

**整個 limn 前端就是「一個 Qt process」。** MuPDF 是以 library 的形式(`-lmupdf`)
連進這個 process,從來不是獨立程序。要同時呈現 N 份文件,就是在**這同一個 process**
裡放 N 個 `DocumentView` + N 個 `PdfViewOpenGLWidget`,全部掛進同一個 `QSplitter`。

**明確否決的方案:多程序(「開兩個 sioyek」)。** 那條路內部雖然零改造,但要把兩個程序
無縫拼進同一個 frame,等於跨程序的視窗鑲嵌(window embedding)。這在 macOS(我們的主力平台)
上基本不可行 —— macOS 不讓你把別的 process 的 NSWindow reparent 進自己的 view 階層,
頂多得到兩個各自獨立、要自己同步位置的 OS 視窗,焦點會閃、無共用標題列。所以**不走多程序**。

切框本身由 `QSplitter` 免費提供;`MainWidget::add_split_pane` 也已經證明「一個 process 裡
跑多個 `PdfViewOpenGLWidget`」可行。我們缺的只是「讓每個 pane 有自己的 `DocumentView`」。

### 決策二 —— 肥做法(per-pane 真正的 live DocumentView)

**每個可見 pane 都給它一個真正、完整、活著的 `DocumentView`。** 不搞「只留一個 live DV +
其他 pane 用快照/點陣圖虛擬化」那種精巧但脆弱的省記憶體做法。

「肥」肥在哪、不肥在哪,講清楚:

- **變多的只有 `DocumentView` 這個輕量狀態物件**(記著:看哪份 `Document`、第幾頁、縮放、捲動
  位置)。多開幾個 pane 就多幾個這種小物件。
- **重的資源全部繼續共用**:`document_manager_`(快取 `Document`)、`checksummer_`、
  `PdfRenderer` 那 4 條 render 執行緒、全域 `fz_context`。**不會**每個 pane 各跑一套引擎。

換句話說:engine 層(`Document`/MuPDF)本來就能在一個 context 裡握多份文件,**現況就已支援**;
我們唯一要做的是讓 view 層(`DocumentView`)從「一個共用」變成「per-pane 一個」。選「肥」是因為
它簡單、正確、好驗證 —— 寧可多花幾個小物件的記憶體,也不要為了省那點記憶體去養虛擬化的複雜度。

## limn 的設計哲學(為什麼上面兩個決策很自然)

再次強調,免得日後忘記初衷:

- **後端(SBCL Lisp REPL)才是大腦 / source of truth。** buffer、window、mode、keymap 這些
  概念全部活在 Lisp 那邊;C++ Qt 端只是一個**透過 JSON Unix-socket wire 講話的薄 client / 渲染層**。
- **Emacs 式的心智模型**:buffer / window / mode / keymap。一份開啟的 PDF 是一個 buffer;
  一個顯示區是一個 window;`DocumentView` 就是「某個 window 正看著某個 buffer 的視角」。
- **正因為「大腦在後端、前端是 client」**,split 的協調(誰是 focused、view/* 指令送給誰)天生
  就由後端的 window/frame registry 主導 —— Single Process 的前端只要忠實地把 N 個 view 畫出來、
  並把輸入回報給後端即可。這也是為什麼「肥做法 + 單程序」跟 limn 的架構最契合:前端保持笨而直接,
  聰明的狀態管理留在 Lisp。

## 背景 —— 現況(v0.39.10)

- `MainWidget` 目前只擁有**一個** `DocumentView* document_view_`、以及一個面向使用者的
  `PdfViewOpenGLWidget* opengl_widget_`。它也有一個 `viewport_splitter_`(`QSplitter`)
  跟一個 `add_split_pane(orient)` method,後者會往 splitter 裡再加*額外*的
  `PdfViewOpenGLWidget` —— 但那些 pane **共用**同一個 `DocumentView*`。所以今天的
  `add_split_pane` 只會給你兩個顯示*相同內容*的 viewport;捲動/縮放其中一個會同時影響另一個。

- `LimnWindowRegistry` 已經在追蹤*邏輯上*的多 window 模型:`LimnWindow`(每個 window
  各自的 page/zoom/offset/buffer_id/selection/overlays/modeline/frame_id/floats)以及
  `focused_id()`(當前作用中的 LimnWindow)。v0.15 已經實作了**虛擬**的 per-window 狀態 ——
  在 `bridge/win-focus` 時,把當前 live DV 的連續欄位(`zoom`、`offset_x`、`offset_y`)
  快照進「先前 focused 的 `LimnWindow`」,再把目標 window 的快照還原回同一個 live DV。
  也就是說 page/zoom/offset 在 *registry* 裡是 per-window 的;但 OpenGL widget 裡任一時刻
  **只有一個 window 是可見的**。

- `bridge/win-split` 已經會配置一個新的 `LimnWindow`,且(自 v0.8 起)會呼叫
  `MainWidget::add_split_pane` —— 但同樣地,兩個 pane 共用同一個 DV,所以目前還沒有
  真正有用的 split UX。

- **此外還有第二套「手刻的」split 機制**,它完全*不*走 `bridge/win-split` /
  `LimnWindowRegistry`:也就是 M-N 標記清單的 **notes panel**(`main_widget.cpp` 裡的
  `enter_text_panel` / `exit_text_panel`,加上 `limn-pdf-mode.lisp` 裡的 `chrome/focus-pane`
  與 `%notes-focus-*` helper)。它把 `text_widget_` 從 `main_stack_` reparent 出來、放進
  `viewport_splitter_` 當左 pane,然後靠同時翻動三樣東西來「假裝」雙 window 焦點:w1 後端的
  `*window-active-buffer*`、前端的 `win->buffer_id`、以及一條手刻的 CSS focus 邊框。
  這其實**就是本文件所描述的 window 系統的雛形** —— 詳見下方專門的技術債章節。Phase 3 落地時
  必須把它收編(subsume),否則我們會同時養著兩套平行、且會逐漸分歧的 window 機制。

## 稽核 —— `limn_command.cpp` 裡 `document_view()`(無參數)的呼叫點

`grep -n "document_view()" sioyek/pdf_viewer/limn_command.cpp` 得到 11 個命中
(全部在 `limn_command.cpp`;`_main_widget.cpp` 裡剩下的命中是 `helper_document_view()`,
是另一個不相干的 singleton):

| 行號 | 呼叫端 / 情境                          | 語意意圖                  |
|------|----------------------------------------|---------------------------|
| 345  | `cmd_*` post-open                       | active DV(剛開檔)        |
| 497  | `cmd_bridge_win_focus` —— save drift     | active DV(前一個 focused)|
| 639  | `cmd_view_set` —— gated `is_active`      | active DV                 |
| 1476 | `cmd_view_selection_get`                | active DV(focused win)    |
| 1590 | `cmd_view_scroll` —— gated `is_active`   | active DV                 |
| 1699 | `buffer/open` —— register doc            | singleton(重新載入)      |
| 1867 | text↔pdf 切換 —— re-attach               | active DV                 |
| 2389 | `cmd_view_get` —— gated `is_active`      | active DV                 |
| 3200 | `rebuild_overlay_raster`                | focused DV                |
| 3681 | `cmd_test_page_pixel_rect`              | focused DV                |
| 3880 | `widget_to_page_norm`(滑鼠座標)         | focused DV                |

外加 `main_widget.h:27` 的 public accessor。

**結論:** `limn_command.cpp` 裡每一個呼叫點在語意上都是指「focused window 的 DV」。
沒有任何一個是指「所有 DV」或「任意 singleton」。今天它們之所以等價,只是因為目前只有一個 DV。

## 目標資料模型(最終狀態)

```
MainWidget
└── viewport_splitter_ : QSplitter           (root layout)
    ├── ViewportPane "w1"                    (每個 type=tiled 的 LimnWindow 對應一個)
    │   └── QStackedWidget                   (PDF | text)
    │       ├── PdfViewOpenGLWidget          (自己的 DocumentView*)
    │       └── QPlainTextEdit
    ├── ViewportPane "w2"
    │   └── ...
    └── ...
```

不變量(Invariants):

- 每個 `type == "tiled"` 的 `LimnWindow` 與一個 `ViewportPane` 一對一對應
  (目前還無名 —— 待辦:引入一個 `ViewportPane` struct,把 `DocumentView*` +
  `PdfViewOpenGLWidget*` + 可選的 text widget + 所屬 `win_id` 綁在一起)。
- `windows->focused_id()` 依然代表「其 pane 當前驅動鍵盤/滑鼠、並接收 view/* 指令的那個
  LimnWindow」。
- `MainWidget::document_view()`(無參數)回傳 **focused** pane 的 DV。在這個定義下,
  所有既有呼叫點的語意都維持不變。
- 新增的 `MainWidget::document_view(const QString& win_id)` 回傳指定 window 的 pane DV,
  未知則回傳 `nullptr`。
- 浮動 window(Floating windows):延後。在 tiled split 穩定之前,只當作 `LimnWindow`
  紀錄存在即可。

## 待收編的既有特例 —— notes panel(`WINDOW-SYSTEM-DEBT`)

M-N 標記清單面板(於 PR #3、Bug-Set-B #3 出貨)是一套**早於**本多-DV 系統就做好、且能運作的
雙 window UX。它實質上是一個寫死的 `1×2` tiled split,繞過了本文件所描述的一切。把它列在這裡,
是為了不要忘記它、也不要讓它默默爛成孤兒 code。

**它今天做了什麼(手刻路徑):**

| 零件 | 位置 | 角色 |
|------|------|------|
| `enter_text_panel(ratio)` / `exit_text_panel()` | `main_widget.cpp` | 把 `text_widget_` 從 `main_stack_` reparent 進 `viewport_splitter_` 當左 pane(約 1/3);PDF 透過 `main_stack_` index 0 留在右 pane |
| `chrome/focus-pane` → `cmd_chrome_focus_pane` | `limn_command.cpp` | 設定 `win->buffer_id`、畫手刻 CSS focus 邊框(accent `#4a90d9`)、調整 ExtraSelection highlight 的 alpha(notes 70 / pdf 28) |
| `%notes-focus-pdf` / `%notes-focus-list` / `%notes-focus-other` | `limn-pdf-mode.lisp` | 翻動 w1 後端的 `*window-active-buffer*` + 呼叫 `chrome/focus-pane` + 重畫 overlays |
| `NOTES-PANEL-MODE`(minor) | `limn-pdf-mode.lisp` | 面板開啟期間,在 **PDF** buffer 上綁 `C-x o` → `pdf-notes-focus-other`、`q` → `pdf-notes-quit`;modeline 顯示 `Notes^` |

**為什麼它是技術債:**

1. 它從來沒有建立第二個 `LimnWindow`(沒有 `w2`)。「焦點」是在單一 window `w1` 上,靠翻動
   它的 active-buffer + 前端 `buffer_id` + 一條手動邊框*模擬*出來的。鍵還寫死 `win-id "w1"`。
2. focus 邊框、pane 尺寸、輸入路由全部都在這裡手刻,而不是來自一套通用的 window 系統。
3. 兩個 pane 仍然共用**那一個** `DocumentView` —— 正是 Phase 3 要移除的限制。

**收編計畫(作為 Phase 3 的「3c」步驟執行,見下方):**

在目標資料模型裡,notes panel *就只是一個普通的 2-pane tiled split*:`pane(w1)` 顯示 PDF
(stack index 0),`pane(w2)` 顯示 notes-list 的 text buffer(stack index 1)。遷移對照:

| 今天的手刻做法 | 變成(通用系統) |
|---------------|------------------|
| `%open-notes-list` 透過 `enter_text_panel` reparent | `bridge/win-split :dir "h"` → 新的 `w2`;把 notes-list buffer 掛到 `w2` 的 pane |
| `%notes-focus-other` / `chrome/focus-pane` | 通用的 `bridge/win-focus` 循環 + Phase 3 step-4 的 focused-pane 邊框 |
| `pdf-notes-quit`(`q`) | `bridge/win-close w2` |
| `NOTES-PANEL-MODE` 的 `C-x o` / `q` | 來自 leader-keys 的 `SPC w` 綁定(`SPC w w` other / `SPC w d` close)—— 這個 minor mode 可能整個退場,或只保留 `Notes^` 這個 modeline 標籤 |
| 手刻的 ExtraSelection alpha 調整 | 待決定:在通用邊框下保留它當作 focus 提示,還是直接拿掉 |

**行動項 —— 現在就先標記原始碼**,讓這筆債在 Phase 3 開工前就可被 grep 出來。在以下位置加上
一個指向本章節的 `WINDOW-SYSTEM-DEBT` 註記:`enter_text_panel` / `exit_text_panel`、
`cmd_chrome_focus_pane`、`%notes-focus-pdf` / `%notes-focus-list` / `%notes-focus-other`、
以及 `NOTES-PANEL-MODE` 的定義處。之後 `grep -rn WINDOW-SYSTEM-DEBT` 就會列出 Phase 3c
必須回頭處理的每一個點。

## 分階段計畫

### Phase 1 —— 稽核 + 設計文件(本檔)  ✅ 已完成

就是本檔。盤點每一個 `document_view()` 呼叫點與其逐點語意意圖。無 code 變更。

### Phase 2 —— 把 DV 從 `MainWidget` singleton 解耦(僅 overload）✅

目標:引入 `document_view(win_id)` overload,為一個 window 回傳對應的 DV —— 即使目前只有一個。
**無任何可見行為變化** —— 這個階段做完後,binary 應該看起來跟 v0.39.10 完全一致。

步驟:

1. 在 `main_widget.h` / `main_widget.cpp` 加上 `DocumentView* MainWidget::document_view(const QString& win_id)`
   overload。對任何 `win_id` 都回傳 `document_view_`(目前只有一個 DV)。把契約寫進註解。
2. 把 `limn_command.cpp` 裡 11 個有 `win_id` 在 scope 內的呼叫點遷移成 win-aware 形式。
   對於作用在 focused window 的點(3200、3681、3880、497)傳 focused id;對於 per-win 的
   handler(639、1476、1590、1867、2389),傳 local `win_id`。
3. 保留無參數的 `document_view()` 不動 —— 它現在代表「focused DV」(目前等價於 singleton)。
   `_main_widget.cpp` 裡 585+ 處用法維持不變。
4. Build + 冒煙啟動 binary。

### Phase 3 —— 在 QSplitter 裡放多個 DV(per-window viewport pane)

目標:真正地為每個 tiled `LimnWindow` 各實例化一個 `DocumentView*`,並掛到
`viewport_splitter_` 上。

步驟:

1. 新增 `MainWidget::ViewportPane` struct(或就用一個 `QHash<QString, PanelTuple>`),
   把 `win_id` → `{DocumentView*, PdfViewOpenGLWidget*, QStackedWidget*, QPlainTextEdit*}`
   對應起來。
2. `MainWidget::add_pane_for(win_id, orient)` —— 建立一個新的 `DocumentView`
   (共用 `db_manager_`/`document_manager_`/`checksummer_`),用 `PdfViewOpenGLWidget` 包起來,
   依指定方向插進 splitter。回傳新 pane。
3. `bridge/win-split` 呼叫 `add_pane_for(new_id, dir)`,把 page/zoom/offset/buffer 從
   `src` 複製到新的 DV。
4. `bridge/win-focus` 切換*作用中*的 pane 指示(對 focused 那個畫 CSS 邊框),並把接下來的
   view/* 指令重新導向到它。
5. `bridge/win-close` 移除 `win_id` 的 pane,並 `delete` 它的 DV/widget。
6. `MainWidget::document_view()`(無參數)變成:
   `return panes_.value(windows_->focused_id()).dv;`
   `MainWidget::document_view(win_id)` 對任何 win 回傳對應 DV。

#### 風險到底是什麼(精準版)

風險**只有一種**失敗模式,不是「改不動」也不是「會 crash」。3a 之後,`document_view_` 的
語意變成「**focused pane 的那個 DV**」,焦點一換就重新指過去。地雷長這樣:

```cpp
DocumentView* dv = document_view_;   // 此刻抓指標（focused = pane A）
... // 中間發生了某事，焦點切到 pane B
dv->scroll(...);                     // 慘：還在動 pane A，但使用者以為在動 B
```

或另一種:某段繼承自 sioyek 的舊碼在啟動時把 `document_view_` **快取進一個 member 變數**,
之後一直用那份;我們把它變成動態之後,那份快取就**過期**了。

特性:**它不會編譯錯、不會明顯 crash,而是「靜默打到錯的 pane」** —— 沒報錯,測試未必抓得到。
這就是它被標高風險的原因:細微、藏在我們沒完全摸透的繼承碼裡。

**為什麼它其實很窄、可控:**

1. `_main_widget.cpp` 那 585 處引用,**絕大多數本來就是要「focused 的那個 view」**(滑鼠點擊、
   render、當前捲動)→ 在「`document_view_` = focused」的定義下自動正確,不用改。
2. 危險的只有「**先抓指標 → 焦點切走 → 才用**」這種模式。而在單一同步指令 handler 內,焦點
   不會中途改變,所以那些也安全。真正危險的只剩:**(a) member 變數快取了 DV 指標、
   (b) async callback 捕捉了舊指標**。→ 這是一個**有界的 grep / 程式碼審查**,不是 585 個逐一檢查。

**而且風險是分階段的(這就是拆 3a/3b/3c 的理由):**

- **3a 零風險**:還沒有第二個可見 pane、也不關閉任何 pane。只是 (1) 讓 per-pane DV 可被建立、
  (2) 把 `document_view_` 改成「指 focused」—— 此刻只有一個 pane,focused 永遠是它,
  **畫面零變化、可用 1598/24 baseline 驗證無退化**。
- 上面那個「快取過期 / 打錯 pane」地雷,要到 **3b**(真有兩個 pane、焦點會動)才會引爆。
- pane 銷毀時的 dangling pointer / double-free,也只在 **3b 的 win-close** 路徑才出現;3a 不關 pane。

簡言之:`_main_widget.cpp` 有 585 處 `->document_view()` 引用、且很多直接戳 `document_view_`
member;Phase 3 必須讓 `document_view_` 始終指向 focused pane 的 DV。但這個風險窄(只有快取
模式)、且集中在 3b,**3a 安全到無聊**。

#### Phase 3 拆解(拆成 3a / 3b / 3c 來降風險)

Phase 3 是本文件裡最大、最高風險的一項 —— 它偏重前端,而且**headless 測試框架無法驗證 split
的視覺正確性**(這個教訓在 Bug-Set-B #3 已經痛過一次)。所以把它拆成三個可獨立出貨的子步驟,
每一步結束都要 build + 跑無退化的整合 baseline:

- **3a —— pane 基礎建設,但仍維持單一可見 pane。** 加上 `panes_` map + `add_pane_for`、
  為每個 pane 建立新的 `DocumentView`、把 `document_view()` 改走 focused pane。binary 應該
  跟今天**100% 一致**(單 pane)。這是高風險面的步驟(585 處 `document_view_` 戳點),但因為
  畫面零變化,可以完整地用*無退化*測試驗證。
- **3b —— 真正的第二個 pane。** 把 `bridge/win-split` / `win-focus` / `win-close` 接到
  真正的 pane 建立 / focus 邊框 / 移除,並把鍵盤輸入路由到 `windows_->focused_id()`,不再寫死
  `"w1"`。這是第一個*需要*人工目視驗證的步驟。
- **3c —— 收編 notes panel**(見上方 `WINDOW-SYSTEM-DEBT` 章節)。退掉手刻的
  `enter_text_panel` / `chrome/focus-pane` 路徑;把 M-N 面板重建在 `bridge/win-split` 之上。
  **狀態:曾於 v0.44.0/.1 併入 main,dogfood 抓到真機 reopen 重繪 bug 後已 revert
  出 main(2026-05-30),WIP 保留在分支 `wip/phase-3c`。** 實作的 Lisp/wire/幾何
  100% 正確(headless `bridge/viewport-debug` 顯示 reopen 後 count:2、實寬、
  visible),但**真實顯示器上**關閉 notes panel 再開時第二格不重繪——headless 與
  孤立測試都正常,只在完整 walkthrough 的真機 reopen 掛。試過 `setSizes` +
  `hide→show→raise` paint kick 都沒治好(見 ISSUES I-11)。**deferred**:它仍是
  Phase 6 win-undo 的前置,要做 Phase 6 前須先用真機 + 截圖管線把這個重繪 bug
  收掉(從 `wip/phase-3c` 接續)。

#### 誠實的工作量與風險評估

| 關注點 | 難度 | 備註 |
|--------|------|------|
| per-pane `DocumentView` 生命週期(建立/銷毀,共用 `db_/doc_manager_/checksummer_`) | 中 | 機械式工作,但要當心 close 時的 double-free |
| 跨 focus 切換維持 `document_view_` 有效 | **高** | 585 處直接戳;任何「跨 focus 切換還快取這個指標」的路徑都會默默壞掉。這是主要的正確性地雷 |
| 輸入路由改走 focused_id(取代寫死的 `w1`) | 中 | 會動到 app 層的 input filter;今天每個鍵都打向 `w1` |
| per-DV overlay raster(Phase 4) | 中偏高 | 今天 `LimnCommand` 上只有一張 `QImage` → 改成 per-`win_id` map;每個寫入點都得轉發到正確的 window |
| **視覺驗證** | **高(流程風險,非 code 風險)** | headless 看不到 split;需要你一輪輪 `HEADLESS=0` dogfood。這才是真正的排程風險,不是 code 本身 |

**結論(更新):** 3a/3b 已 ship(`v0.41.0`)。3c 一度併入又因真機重繪 bug revert
(WIP 在 `wip/phase-3c`,deferred,見上 + ISSUES I-11)。**剩下唯一還沒做的「新
前端能力」是 Phase 4 per-DV overlay raster** —— 而它只有在「真的開兩個 pane 各看
不同文件」時才需要,所以可以等到那個使用情境真正出現再做。

### Phase 4 —— per-DV overlay raster  ⏭ 唯一剩下的新能力(待真正多文件 pane 時做)

把 `LimnCommand::overlay_raster`(`QImage`)搬進 `LimnWindow`(或搬到 `LimnCommand` 上一個
新的 per-`win_id` map)。`rebuild_overlay_raster`、`cmd_view_overlays`、
`cmd_view_selection_set`、scroll handler 全部都要重畫正確 window 的 raster。
**`_main_widget.cpp` 的 selection-rendering 區塊只能動邊緣 —— 真正畫 overlay 本體的那段,依
scope 契約維持不動。**

### Phase 5 —— ~~Lisp 鍵位綁定(`C-x 2 / 3 / 0 / o / 1`)~~  ❌ 已被 leader-keys 取代

**這個 phase 不再以 `C-x` 形式存在。** 新 roadmap 的預設鍵位是 evil + Doom `SPC`
leader(見 `docs/leader-keys-design.md`),所以視窗鍵位是 **`SPC w`** namespace
(`SPC w /` vsplit、`SPC w -` hsplit、`SPC w d` close、`SPC w w` other、
`SPC w u`/`SPC w r` win-undo/redo…),不是 `C-x 2/3/0/o/1`。

底層指令(`bridge/win-split` / `win-focus` / `win-close`)**3b 已經做完**,所以這裡
本來就只剩「綁鍵」這件事 —— 而它現在**屬於 leader-keys feature 的 `SPC w` 子樹**,
不在本檔。換句話說:Phase 5 沒有獨立工作量,整個併進 leader-keys。

### Phase 6 —— win-undo tree(視窗配置 undo/redo)  ⏭ planned（2026-05-29 加入）

> 前提:Phase 3 落地後,「window 配置」才是一個有意義、可快照的東西
> (多個 pane、各自的 buffer/page/zoom/offset、splitter 比例、focused id)。
> 所以本階段**排在 3c 之後**;在只有單一 pane 的世界裡它沒有內容可 undo。

**目標:** 仿 Emacs 的 window 配置 undo —— 但要的是**樹**(undo *tree*),
不是 `winner-mode` 那種線性 ring。每次改動 window 佈局(split / close /
focus 切 buffer / 調整比例)就在樹上長一個節點;可以往回走、也可以從某個
歷史節點分叉出新枝,不會像線性 undo 那樣一往前走就丟掉另一條歷史。

**為什麼是樹、不是 ring:** 線性 winner-undo 的痛點是「undo 兩步 → 做新動作
→ 中間那條 redo 路徑永久消失」。樹保留所有分支,對「我剛剛那個三欄佈局跑哪
去了」這種需求友善。代價是 UX 要能在樹上導航(至少 undo/redo + 跳到節點)。

**狀態長什麼樣(window-config snapshot):**

```
window-config = {
  panes: [ {win_id, buffer_id, page, zoom, offset_x, offset_y} ... ],
  splitter_ratios: [...],
  focused_id: "wN",
}
```

這正是 `LimnWindowRegistry` 已經逐欄追蹤的東西(見背景章節);win-undo 只是
把「整個 registry + splitter 幾何」打包成一個不可變快照,推進一棵樹。

**架構落點:** 大腦在後端 —— 樹**住在 Lisp**(`limn/window` 或新的
`limn/winundo` package),沿用 `limn-undo` 已有的 undo-tree 資料結構(若
text buffer 的 undo 已是樹狀,直接複用;若是線性則先抽共用)。C++ 端只負責
「把一個 window-config 快照**套用**回 viewport」(重建 panes / 還原各 DV /
設 splitter 比例 / 設 focus)—— 等於 `win-split`+`win-focus`+`win-close`
的批次組合,Phase 3 的零件都已存在。

**粗略 sub-roadmap(待 3c 收尾後細化):**

1. Lisp:`capture-window-config` —— 從 registry + 前端查 splitter 幾何,組出
   不可變快照。
2. Lisp:undo-tree 結構(複用 `limn-undo`);每個改佈局的 wire 指令
   (`win-split`/`win-close`/`win-focus`/buffer 切換)做完後 push 一個節點。
3. Lisp:`apply-window-config` —— 把快照 diff 成最少的 split/close/focus 指令
   序列,送給前端重建。
4. C++:`bridge/win-config-apply` —— 一次套用整個佈局(冪等、可從任意現況收斂
   到目標),避免一指令一指令來回。
5. 鍵位:`C-c <left>` / `C-c <right>`(winner-style)或 `C-x w u` / `C-x w r`;
   樹導航另議。
6. 視覺驗證:headless 測 snapshot/apply 的等價性;佈局還原的目視驗證走
   walkthrough(見 CLAUDE.md §6)。

**狀態 checklist:**

- [ ] §6.1 capture-window-config 快照
- [ ] §6.2 undo-tree 結構 + 每個佈局指令 push 節點
- [ ] §6.3 apply-window-config(diff → 指令序列)
- [ ] §6.4 bridge/win-config-apply(冪等批次套用)
- [ ] §6.5 鍵位 + 樹導航
- [ ] §6.6 walkthrough 視覺驗證

## 周邊功能 —— Bookmark Everywhere(獨立任務,**不屬於** window split)

> 刻意排在 window split 之外,避免又長出一個特例。等 window 這條告一段落再做。

**構想:** 一個 bookmark = 「**一個具名、可持久化的觀看狀態快照**」=
`(文件路徑, 第幾頁, zoom, offset_x, offset_y[, rotation])`。在任何文件、任何視角下
「存一下」;之後從任何地方一鍵跳回那個**完整視角**(不只是頁碼,連縮放/捲動位置都還原)。

**為什麼便宜 —— 零件大多已存在:**

- **擷取 / 還原視角** = 跟 `LimnWindow` 在 `bridge/win-focus` 時做的 snapshot/restore
  (`page` / `zoom` / `offset_x` / `offset_y`)**是同一套機制**(v0.15)。bookmark 只是把那份
  快照**取個名字、寫進資料庫**而已。
- **儲存** = sioyek 已有資料庫(`local.db` / `shared.db`),且原生有 bookmark/mark 概念;
  我們也已做過 **position mark ring**(task B,跳回/跳前)。「具名、跨文件、可持久化」是這些的延伸。
- **跳回** = 「需要的話先開檔 → 設定 page/zoom/offset」≈ win-focus 的還原邏輯。

**與 window split 的綜效(這也是排在它之後做的原因):** 等 Phase 3a 有了 per-pane
`DocumentView`,「跳到某 bookmark」可以是「還原進 focused pane」,甚至「在新的 split 裡開這個
bookmark」。兩個功能天然組合。

**粗略步驟(待 window 收尾後細化):**

1. Lisp 端:`bookmark-set <name>` 讀目前 focused window 的視角快照、寫進 DB;
   `bookmark-jump <name>` 還原。沿用 mark-ring 的擷取/還原程式碼。
2. 列表 / 補全:用既有的 narrow/fuzzy(task A 的 search-upgrade)做 `bookmark-jump` 的選單。
3. 鍵位:`C-x r m`(set)/ `C-x r b`(jump),對齊 Emacs `bookmark-set` / `bookmark-jump`。

## 跨階段約束(Constraints)

- 所有變更都必須保留單一 window 的行為。
- `MainWidget::document_view()`(無參數)**不可移除** —— `_main_widget.cpp` 裡呼叫點太多。
- **不要**動到不相干的工作:`cmd_view_selection_*` 本體、`cmd_view_scroll` 的 win→page
  同步、`rebuild_overlay_raster` 裡的 selection-rendering 區塊、`_main_widget.cpp` 的
  滑鼠事件 handler、search code。
- 每個階段做完:build + 至少啟動一次 binary。

## 狀態(對齊新 roadmap)

已 ship(`v0.41.0`):

- [x] Phase 1 —— 稽核 + 設計文件
- [x] Phase 2 —— `document_view(win_id)` overload + 遷移呼叫點
- [x] Phase 3a —— pane 基礎建設 + `document_view()` 改走 focused(畫面零變化)
- [x] Phase 3b —— 真正的第二個 pane(`win-split`/`focus`/`close` + 輸入路由 + 游標捲動 + 視窗標題品牌化)。dogfood 12 項全通過,收尾於 commit `d80cc9b`,tag `phase-3b-complete`。
- [x] 開工 3a 前先用 `WINDOW-SYSTEM-DEBT` 標記原始碼(可 grep)

revert 出 main、WIP 保留、**deferred**:

- [~] **Phase 3c —— 收編 notes panel(`WINDOW-SYSTEM-DEBT`)** —— 曾於 v0.44.0/.1 併入,
      真機 reopen 重繪 bug 後 **revert 出 main(2026-05-30)**,WIP 在分支
      `wip/phase-3c`。Lisp/wire/幾何皆正確,只在真實顯示器上「關閉 notes 再開」第二格
      不重繪(headless / 孤立測試都正常)。見 **ISSUES I-11**。仍是 **Phase 6 的前置**;
      要做前須先用真機 + 截圖管線把重繪 bug 收掉(從 `wip/phase-3c` 接續)。

仍待做的新能力:

- [ ] **Phase 4 —— per-DV overlay raster** —— 唯一剩下的新前端能力。只有「真的開兩個
      pane 各看不同文件、各有 annotation/搜尋高亮」時才需要 → 等該情境出現再做。

已被取代 / 移交:

- [—] **Phase 5 —— ~~`C-x` window 綁定~~** —— 被 leader-keys 的 `SPC w` namespace 取代;
      底層指令 3b 已完成,只剩綁鍵,已移交 `docs/leader-keys-design.md`。本檔不再追蹤。

planned(前置 3c 尚未收尾):

- [ ] **Phase 6 —— win-undo tree(視窗配置 undo/redo,樹狀非線性)** —— 詳見上方 Phase 6
      章節。前置:3c(已 revert,在 `wip/phase-3c`,須先修真機重繪 bug 並併回)。

獨立任務:

- [ ] Bookmark Everywhere —— 具名視角快照 set/jump(註:跨-buffer 命名書籤已於
      optimistic-brahmagupta 分支 v0.37 另行實作)。

## 下一步(新 roadmap 下)

window split 這條的「真正收尾」已經不在關鍵路徑上 —— 3a/3b 已 ship、3c revert 後
deferred(WIP 在 `wip/phase-3c`)、Phase 5 移交 leader-keys。所以接下來:

1. **不動 window**。把力氣放在新 roadmap 的高優先:**Fuzzy Selector**
   (`docs/completion-ui-design.md`)與 **evil + leader-keys**
   (`docs/evil-mode-design.md` / `docs/leader-keys-design.md`)。
2. **3c(`wip/phase-3c`)**:deferred。要收尾時,先用真機 + 截圖管線把「reopen 第二格
   不重繪」這個真機 paint bug 修掉(見 ISSUES I-11),再重新 build + 完整 verify-3c.sh
   通過才併回 main。
3. **Phase 4(per-DV overlay)**:等到真的有「多 pane 各看不同文件」的使用情境再做。
4. **Phase 6(win-undo)**:前置 3c 尚未收尾,要動之前先把 3c 修好併回。
