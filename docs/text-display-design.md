# text-display-design.md

text-engine buffer 的**顯示層** —— 設計與分階段計畫。狀態:⏭ planned（2026-05-30 開檔）。

next-steps 的 **buffers basic** 底下有一串「buffer 怎麼顯示」的需求,本 doc 收三項相關的:
**CJK / linum?-mode / emacs-like face / fonts / color management**。
（同段的 *vim-like by default* 走 `evil-mode-design.md`、*overlay / org folding* 走
`folding-design.md`，不在本檔。）

這三項共通點:都是「text-engine buffer（`QPlainTextEdit` 顯示面）長什麼樣」的事 ——
字怎麼排（CJK）、行號（linum）、字體與顏色（face）。放一起因為它們會互相牽動（face 要
處理 CJK fallback、linum gutter 要跟 face 配色），分開做會三套各自為政。

## 背景 —— 現況盤點

- **CJK 已 ship 一部分**（權威 `LIMN-SPEC.org`）:v0.13/v0.13.1 CJK in minibuffer
  （batch 23，9/9 全綠）、container locale 設 `C.UTF-8`（否則 xdotool 拒 CJK 輸入）、
  v0.16 CJK 三件套、IME（CJK 複合輸入完成時送出，`LIMN-SPEC` §「輸入法」）。
  `buffer/text` 載入 UTF-8 含 CJK 檔案回正確字串（測試已涵蓋）。
  → **輸入 / minibuffer / 載入的 CJK 大致 ok;缺口在「text-engine buffer 內的 CJK
  顯示寬度 / 字體 fallback / 游標定位」是否都對**（尤其 BMP 外、全形寬度、混排）。
- **linum / face / color**:目前 text-engine 顯示是樸素 `QPlainTextEdit`，**沒有**行號
  gutter、**沒有**後端可控的 face/color 系統（顏色多寫死在 C++ 或 CSS）。這兩項基本是
  從零開（但 face 與 `view/overlays` 的 `text` type 已預留的 face 欄位相關 —— LIMN-SPEC
  v0.4 註「將來可能支援 face / 格式化欄位」）。

**結論:CJK 是「補缺口 + 確認 text-engine 內顯示正確」;linum 與 face/color 基本從零,
但要對齊 Emacs 的心智模型（buffer-local、mode 可覆寫）。**

## 目標（對齊 next-steps 大綱）

1. **CJK** —— 確保 text-engine buffer 內 CJK 顯示完全正確:全形寬度、字體 fallback
   （container 常缺 glyph → 豆腐字）、游標 / 選取 / 行寬計算對 CJK 正確、混排（CJK + ASCII）。
2. **linum?-mode** —— 行號 gutter，對齊 Emacs `display-line-numbers-mode`
   （absolute / relative / visual）。minor mode，buffer-local 開關。
3. **face / fonts / color management** —— 對齊 Emacs `face`:具名的視覺屬性集合
   （前景 / 背景 / 粗體 / 底線 / 字體），buffer-local 與 mode 可覆寫,後端是真相。
   把目前散在 C++/CSS 的寫死顏色收編成「後端定義 face → 前端套用」。

## 設計取向（待定案，先記方向）

- **大腦在後端**:face 定義表、line-number mode 狀態、CJK 字體偏好都是 Lisp 狀態
  （buffer-local / mode）。C++ 端照後端給的 spec 渲染。對齊 cursor-style 同款分工。
- **face 的 wire 形狀**:後端推一張 face 表 + per-range 的 face 套用，例如
  `view/faces {:default {:fg "#..." :bg "#..." :font "..."} :comment {...} ...}` +
  既有 `view/overlays` 的 `text` type 帶 `:face`。**這跟 folding/overlay 的 overlay
  primitive 是同一條管線**（overlay 帶 face）→ 與 `folding-design.md` 共用,別造兩套。
- **linum gutter 落點**:`QPlainTextEdit` 的左 margin paint（Qt 標準做法是
  `QAbstractTextDocumentLayout` + 自繪 line number area）。relative line number 跟
  evil 的游標行連動（`evil-mode-design.md`）。
- **CJK 字體 fallback**:在 container / macOS 上指定 CJK fallback 字族（Noto CJK 之類），
  確保無豆腐;行寬 / 游標定位用 `QFontMetrics` 對全形字正確量測。
- **color management**:預設配色（dark / light）做成 face 表的 theme,對齊 Emacs
  custom-theme;與 annotation 的 tag 顏色（`annotation-store-design.md`）共用色票。

## 開放問題

- face 的範圍:先做「整個 buffer 一個 default face + 少數具名 face（comment/string/
  keyword 給未來 syntax highlight 用）」夠不夠?還是一步到位做 per-character face?
  傾向:先 default + 少數具名 + overlay 套用,syntax highlight 留後續。
- linum 與 CJK / 折疊的互動:折疊（`folding-design.md`）後行號要顯示「實際行」還是
  「可見行」?relative 怎麼算?
- color theme 是 defcustom / init.lisp 設,還是內建幾套切換?（對齊 leader-keys 的
  config 落點。）
- CJK 缺口具體有哪些 —— 要先在 text-engine buffer 實測一份 CJK 文件,列出壞點,再排優先。

## 分階段 sub-roadmap（planned）

- [ ] §1 CJK 缺口盤點:在 text-engine buffer 開一份 CJK 文件,實測寬度 / fallback /
      游標 / 選取 / 混排,把壞點列成表寫進本 doc。
- [ ] §2 CJK 字體 fallback + 全形寬度 / 游標定位修正。
- [ ] §3 face 系統:後端 face 表 + wire（與 overlay `:face` 共管線）+ 前端套用 default face。
- [ ] §4 color theme（dark/light face 表）+ 收編散落的寫死顏色;與 tag 色票共用。
- [ ] §5 linum-mode（absolute / relative / visual，buffer-local minor mode，gutter 自繪）。
- [ ] §6 鍵位 / config:`SPC t l`（toggle linum）、theme 切換,收進 leader + defcustom。

## 驗證

- **headless 可測**:face 表的解析 / buffer-local 覆寫邏輯、linum mode 狀態切換、CJK
  `buffer/text` round-trip、行寬計算（給定字串算 column）—— 寫 unit test。
- **真機目視**（CJK 無豆腐、行號對齊、配色、游標落在全形字正確位置）:走 walkthrough
  （繁中、絕對路徑、印「預期看到什麼」+ y/n/c/a，CLAUDE.md §6）。CJK 尤其需要目視,
  因為「寬度差一格 / 字體 fallback 成豆腐」headless 量不到。

## 關聯

- `folding-design.md` —— overlay primitive 與 `:face` 同管線,共用,別造兩套。
- `evil-mode-design.md` —— relative line number 跟游標行連動。
- `annotation-store-design.md` —— tag 顏色與 face 色票共用。
- `cursor-style-design.md` —— 游標渲染（本 doc 管字 / 行 / 色,游標另檔）。
- `LIMN-SPEC.org` v0.13 / v0.16（CJK）/ §「輸入法」(IME) —— CJK 的權威現況。
