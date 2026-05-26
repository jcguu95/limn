# v0.38 Dogfood II — Workflow Specs (session-scoped)

**Scope**：本檔只給此 session 用。**不要** 複製進 `~/.claude/`、CLAUDE.md、memory 路徑。
**儲存位置**：`./tmp/v038-dogfood-workflows.md`（worktree 內、untracked、session 結束統一刪）。
**所有 session-scope 輸出**（receipts / screenshots / 暫存 init.lisp / 暫存 fixtures）統一放 `./tmp/` 底下，session 結束 `rm -rf ./tmp/` 即清乾淨。
**目的**：把 30 個 dogfood workflow 寫成 agent-proof 規格，避免 v0.37 那種「我以為我在 dogfood，其實在 simulate」的 digression。

---

## 0. 全域規則（R1-R8）

| R# | 規則 | Why |
|----|------|-----|
| R1' | **預設 docker**（既有 OS-tier harness、reproducible、zero focus 干擾、無 permission gymnastics）。macOS host 僅用於：(a) W30 file-notify (kqueue vs inotify)、(b) IME / CJK 邊緣表面、(c) sprint 結尾抽 6-8 個 workflow 跑 macOS sanity sweep | 原 R1 撞到 Info.plist 缺、視窗註冊弱、Accessibility + Screen Recording 兩道權限、user 並行工作搶 focus。docker 才是 v0.37 OS-tier 已驗證的乾淨環境 |
| R2' | 鍵盤 **必須** 走外部 OS event：docker 用 `xdotool key X`、macOS 用 `osascript keystroke`。**禁止** `limn:call`、`(funcall ...)`、wire JSON 取代按鍵 | 把 binary 當黑盒 |
| R3' | 驗證 **必須** 走 screenshot + script：docker 用 `import` / `xwd`、macOS 用 `screencapture`。**禁止** `view/get`、`buffer-list`、`*messages*` 取代真實 UI 觀察 | wire state ≠ user-visible state |
| R4 | 受測必須載 **真實 init.lisp** (`/tmp/.limn/init.lisp`)。沒有就寫一份代表性的並 copy 到 `./tmp/init.lisp.baseline` 留檔 | default-only 跑不到 hot-reload / map! / hooks |
| R5 | 鍵與鍵之間 sleep 150-300ms | 模擬人類節奏，撞 focus race / debounce |
| R6 | 每個 checkpoint 截圖到 `./tmp/receipts/{workflow-NN}/step-{KK}.png` | 事後可抽查；session 結束統一清 |
| R7 | 每個 workflow **跑兩遍**：照腳本 + 變奏。兩遍都過才算 | 防 lucky path |
| R8 | 每個 workflow 開始前重啟 Limn（殺 process 再開），確保乾淨 state | 防上一個 workflow 殘留污染 |

**任一規則違反就是 workflow FAIL，不論結果**（自我違規一律記錄到 receipts）。

---

## 1. 工具基線

### 1.1 macOS key-send（osascript 模板）

```bash
# 單鍵
osascript -e 'tell application "System Events" to keystroke "j"'

# Modifier 組合
osascript -e 'tell application "System Events" to keystroke "s" using {command down}'  # C-x C-s 等
osascript -e 'tell application "System Events" to keystroke "g" using {control down}'  # C-g

# 特殊鍵
osascript -e 'tell application "System Events" to key code 36'                          # Return
osascript -e 'tell application "System Events" to key code 53'                          # Escape
osascript -e 'tell application "System Events" to key code 49'                          # Space
osascript -e 'tell application "System Events" to key code 123'                         # Left
osascript -e 'tell application "System Events" to key code 124'                         # Right
osascript -e 'tell application "System Events" to key code 125'                         # Down
osascript -e 'tell application "System Events" to key code 126'                         # Up
```

**Pre-flight**：每個 workflow 開頭必須先 `osascript -e 'tell application "limn" to activate'`（app name 為 `limn` 全小寫）。送鍵前若 frontmost app 不是 limn → 整個 workflow 直接 FAIL。

### 1.2 截圖

```bash
screencapture -x -t png ./tmp/receipts/{workflow-NN}/step-{KK}.png   # -x = 無快門音
screencapture -x -R 0,720,1440,180 ./tmp/.../chrome.png              # 指定矩形（chrome bar）
```

### 1.3 像素 / 結構檢查（python3 + Pillow）

```python
# 預期 ./tmp/lib.py，每個 workflow import
from PIL import Image
def mean_brightness(path, box=None):
    im = Image.open(path).convert("L")
    if box: im = im.crop(box)
    px = list(im.getdata()); return sum(px)/len(px)
def pixel_at(path, x, y):
    return Image.open(path).convert("RGB").getpixel((x, y))
def hash_region(path, box):
    return hash(Image.open(path).crop(box).tobytes())
```

若 Pillow 沒裝 → `pip3 install --user pillow` 或退而求其次用 `sips -g pixelHeight -g pixelWidth` + ImageMagick `compare`。

### 1.4 OCR（透過 nix）

不裝到 host，**用 nix shell**：

```bash
nix shell nixpkgs#tesseract --command tesseract input.png output -l eng
```

或者加進 `flake.nix` 的 devShell（更乾淨；但會動 flake，依規矩需 `deps:` commit message — v0.38 範圍內不動）。
所以 workflow 內一律寫成 `nix shell nixpkgs#tesseract --command tesseract ...` 的形式。第一次跑要等下載（之後 nix store 快取）。

備用：若 OCR 不必要（如純像素 hash 就能判斷），優先用 hash 比對。

### 1.5 Binary provenance 檢查

每個 workflow 開頭：

```bash
~/data/local/projects/sioyek-core/sioyek/limn.app/Contents/MacOS/limn --version
```

輸出的 git hash 必須等於 `git rev-parse HEAD`。不等 → STOP，重 build。

### 1.6 測試素材（固定）

| 用途 | 路徑 | 備註 |
|------|------|------|
| 短 paper | `sioyek/tutorial.pdf` | 隨 repo，~25 頁 |
| 長 paper | `/tmp/Mirror-Symmetry-[Hori-et-al].pdf` | 已就位 |
| CJK .org | `./tmp/fixtures/cjk-sample.org` | 第一次跑時建立 |
| 大檔 .org | `./tmp/fixtures/large.org` | ≥ 1MB，第一次跑時 generate |
| init.lisp | `/tmp/.limn/init.lisp` | workflow 22-27 編輯它；用 `LIMN_INIT_FILE=/tmp/.limn/init.lisp` 或對應 env / CLI flag 指定（pre-flight 確認 limn 真的吃這個路徑） |

---

## 2. Workflows（30 個）

每個 workflow 結構：
- **動作**（osascript / shell）
- **不准**（明確禁止的 cheat）
- **驗證**（screencapture + python 判定）
- **PASS 條件**（boolean）
- **變奏**（第二遍跑法）

---

### A. PDF 純閱讀

#### Workflow 01 — j×30 連續翻頁

- **動作**：開 `tutorial.pdf` → `osascript keystroke "j"` ×30，每次 sleep 200ms。
- **不准**：`(limn:call "view/next-page")`、`(pdf-next-page)`、任何 Lisp 直呼。
- **驗證**：
  1. 開檔後截圖 `step-00.png`，記 chrome bar 矩形 hash → H0。
  2. 每 5 次 `j` 截一張（共 6 張 + 起始 = 7 張）。
  3. 第 31 動作：送 `gg`（兩次 `g` 中間 sleep 100ms），截 `step-31.png`，hash → H31。
- **PASS 條件**：H31 == H0（gg 把頁回到起點）；且 7 張 chrome bar hash 彼此不同（每 5 頁變化）。
- **變奏**：第二遍改用 `space`（送 `key code 49`）取代 `j`，hash 序列必須一致。

#### Workflow 02 — 數字 prefix 跳頁

- **動作**：開 `tutorial.pdf` → 送 `1`, `2`, `g` → sleep 500ms → 送 `g`, `g`（gg）→ sleep 500ms → 送 `G`。
- **不准**：直呼 `(pdf-goto-page 12)`。
- **驗證**：3 張截圖各取 chrome bar hash。
- **PASS 條件**：H_after_12g != H_after_gg；H_after_gg == H0；H_after_G == H_last_page（last_page chrome 預先取一張參照）。
- **變奏**：改用 `5j` 跳 5 頁，再 `5k` 跳回，hash 對稱。

#### Workflow 03 — Zoom ±5 + reset

- **動作**：`+` ×5（每次 sleep 250ms）→ 截圖 → `-` ×5 → 截圖 → `=` reset → 截圖。
- **不准**：直接寫 zoom-level state。
- **驗證**：3 張截圖中央 200×200 內**有字** 的區塊像素變異數（variance）。
  - 放大後 variance 應顯著高於初始（粗字較稀疏）。
  - 縮回 + reset 後 variance 應 ≈ 初始（±5%）。
- **PASS 條件**：放大態 variance > 初始 × 1.3；reset 後 variance 在初始 ±5%。
- **變奏**：用 `f`（fit-width）、`F`（fit-page）取代 `=`，截圖必須與初始相近但不相同。

#### Workflow 04 — TOC 導航

- **動作**：開 paper → `o` 開 TOC → `下` ×3 → `RET` → 截圖。
- **不准**：`(toc-jump 3)`。
- **驗證**：截圖 chrome bar hash 與初始不同；TOC 視窗應消失（畫面主體區 hash 與「無 TOC 開啟」狀態一致）。
- **PASS 條件**：跳轉成功 + TOC 已關閉。
- **變奏**：`下` ×5 → `RET`，hash 必須再不同。

#### Workflow 05 — Dark mode toggle ×3（**known buggy**, G'-2）

- **動作**：開 `tutorial.pdf` → `d` ×3，每次 sleep 500ms，每次截圖。
- **不准**：讀 `view/get :|dark-mode|`。
- **驗證**：4 張截圖中央 100×100 平均亮度。
  - 預期序列：`[亮, 暗, 亮, 暗]`（亮 = brightness > 200, 暗 < 80）。
- **PASS 條件**：4 張亮度交替。
- **預期 FAIL**：v0.37 G'-2 reader bug — 第二次 `d` 不會切回亮。FAIL 走修復流程，這個是 v0.38 第一個必修 bug。
- **變奏**：`d` ×6，序列必須持續交替。

#### Workflow 06 — 搜尋 + n/N + C-g

- **動作**：開 `tutorial.pdf` → `/` 開搜尋 → 鍵入 "the"（5 字元，每字 sleep 80ms）→ `RET` → `n` ×3 → `N` ×2 → `C-g`。
- **不准**：`(pdf-isearch-next ...)`。
- **驗證**：
  1. 搜尋啟動後截圖：畫面應有 highlight（黃色像素 #FFD700 或 sibling 飽和黃）出現。
  2. `n` ×3 後截圖：chrome bar hash 與啟動時不同（換頁了 / hit 號變了）。
  3. `C-g` 後截圖：highlight 消失（中央 200×200 黃色像素 count == 0）。
- **PASS 條件**：highlight 出現 → 跳轉 → 清乾淨。
- **變奏**：搜尋 "and"，預期 hit 更多。

#### Workflow 07 — isearch 即時搜尋

- **動作**：`C-s` → 鍵入 "fig"（一字一字，每字 sleep 200ms）→ 截圖 → `BackSpace` → 截圖 → 鍵入 "ure" → 截圖 → `RET`。
- **不准**：bypass minibuffer。
- **驗證**：每張截圖 highlight 區段位置 / 數量應隨 query 改變（hash 全不同）。
- **PASS 條件**：4 張 hash 全不同；最終 hash 等於同樣查詢 "figure" 的非 incremental 版本。
- **變奏**：中途 `C-s` `C-s` 跳到下一個 hit。

---

### B. PDF 註解 + bookmark

#### Workflow 08 — 5 高亮 round-trip

- **動作**：開 `tutorial.pdf` → 用鍵盤選文（`v` 進選擇模式 → 方向鍵延伸選擇）→ `h` highlight。重複 5 次跨不同頁。`C-x C-c` 關 → 重開。
- **不准**：直接寫 sidecar 檔再宣稱「持久化」；直接呼 `(pdf-add-annotation ...)`。
- **驗證**：
  1. 5 次高亮後截圖 5 張，每張中央區黃色像素數 > 100。
  2. 重開後 navigate 到同 5 頁，每張截圖黃色像素 > 100（與第一遍 ±10%）。
- **PASS 條件**：5/5 sidecar 持久化 + 視覺上重現。
- **變奏**：第二遍改用 `mouse drag` 選文（用 `cliclick` 若可裝；否則跳）。

#### Workflow 09 — 建/刪/再建高亮

- **動作**：3 段高亮 → 中間那段刪掉（選回那段 → `d` 或 `M-x pdf-delete-annotation-at-point`）→ 重開驗證 → 再新增第 4 段。
- **不准**：bypass UI。
- **驗證**：截圖 sequence 黃色像素數 `[3 段, 2 段（中間少了）, 3 段（再加）]`。
- **PASS 條件**：sequence 符合。
- **變奏**：刪掉第一段而非中間段。

#### Workflow 10 — 跨檔 bookmark

- **動作**：開 paper A → `mm` 設 bookmark `m` → 切到 paper B（`C-x C-f` 另一檔）→ `mb` 設 bookmark `b` → 切回 A → `'m` 跳。
- **不准**：bookmark/get wire query。
- **驗證**：
  1. paper A 跳 `'m` 後 chrome hash 必須等於設 `m` 當下的 hash。
  2. paper B 切過去後 `'b` 同樣。
- **PASS 條件**：兩個 bookmark 各自跳對。
- **變奏**：A 設兩個 bookmark `'a` 和 `'b`，互跳。

#### Workflow 11 — annotation + bookmark 混合

- **動作**：page 1 高亮 2 段 → 跳 page 50（`50g`）→ 高亮 1 段 → bookmark page 50（`mk`）→ 關 → 重開 → `'k` 跳 → 截圖。
- **不准**：直查 sidecar 內容。
- **驗證**：重開後跳 `'k` 截圖黃色像素 > 100；翻回 page 1 截圖黃色像素 > 200（2 段）。
- **PASS 條件**：3 段都還在，bookmark 跳對。
- **變奏**：bookmark 設在 page 30 而非 50。

#### Workflow 12 — sidecar 手動破壞

- **動作**：高亮幾段 → 退 → `rm /tmp/.limn/annotations/*.lisp`（若 init.lisp 改寫 sidecar 位置則對應路徑）→ 重開檔。
- **不准**：在 Limn 內 unmark 不算（要從外部）。
- **驗證**：截圖：黃色像素 count == 0；Limn 沒有 crash（process 還活）。
- **PASS 條件**：clean restart + no crash。
- **變奏**：寫入損壞 sidecar（`echo garbage > ...lisp`）再開。

#### Workflow 13 — PDF → .org 複製文字（**high risk**）

- **動作**：開 paper → 選一段文（`v` + 方向鍵）→ `M-w` copy → `C-x C-f ./tmp/notes.org` → `C-y` paste → `C-x C-s`。
- **不准**：用 `(kill-new "..."), (insert ...)` 偷渡。
- **驗證**：
  1. `cat ./tmp/notes.org` 應有貼上的內容。
  2. 內容應為純文字（無 NUL、無控制字元 < 0x20 除了 `\n`）。
  3. 字數 > 20。
- **PASS 條件**：3 項全綠。
- **變奏**：選跨頁 / 跨欄的段落。

---

### C. .org / 文字編輯

#### Workflow 14 — 新建 .org 寫 TODO

- **動作**：`C-x C-f ./tmp/v038-todo.org` → 鍵入 10 行 `* TODO ...`（每行 sleep 100ms，含 `RET`）→ `C-x C-s` → `C-x C-c` → 重開 limn → `C-x C-f` 同檔。
- **不准**：用 shell `echo` 創檔再宣稱「測試」。
- **驗證**：
  1. 重開後截圖：visible 內容應有 10 行 `* TODO`。
  2. `wc -l ./tmp/v038-todo.org` == 10（或 11 帶尾換行）。
- **PASS 條件**：file 內容 + 視覺都對。
- **變奏**：10 行裡混 5 行 `* DONE`。

#### Workflow 15 — 既有 .org 加子項

- **動作**：開 `CHANGELOG.org` → `C-s` 搜尋 "v0.37" 跳過去 → 移到該段尾 → `RET` 加行 → 鍵入 `**  - new sub-item` → `C-x C-s`。
- **不准**：直接 sed/awk 改檔。
- **驗證**：
  1. `git diff CHANGELOG.org` 顯示 +1 行符合鍵入內容。
  2. 縮排與上下文一致（`*` 數量正確）。
- **PASS 條件**：diff 乾淨單行 add。
- **變奏**：在不同 heading 下加。

#### Workflow 16 — CJK 編輯

- **動作**：建立 `./tmp/fixtures/cjk-sample.org` 含「測試中文編輯能力」→ limn 開 → 移到「中」前 → 刪「中」→ 鍵入「英」→ 存 → 重開 → 截圖。
- **不准**：用 sed `s/中/英/`。
- **驗證**：
  1. 重開後 file 內容 == "測試英文編輯能力"。
  2. UTF-8 byte sequence 正確（`file --mime-encoding` 報 utf-8）。
  3. 截圖能看到中文字（中央區字元數 > 0；像素 variance 高表有複雜字形）。
- **PASS 條件**：3 項全綠。
- **變奏**：加入 IME 輸入（若 IME 可程式控）。

#### Workflow 17 — 跨檔 kill / yank

- **動作**：開檔 A 含 "hello world" → mark + `C-w` "world" → `C-x b` 切檔 B → `C-y`。
- **不准**：手動 setf kill-ring。
- **驗證**：檔 A 剩 "hello "；檔 B 結尾新增 "world"。截圖兩檔可見。
- **PASS 條件**：兩端內容對。
- **變奏**：連 kill 三段、檔 B yank 三次。

#### Workflow 18 — Query-replace within region

- **動作**：開含 5 個 "foo" 的檔 → mark 包住前 3 個 → `M-x query-replace` `foo`→`bar` → `!` (replace all in region)。
- **不准**：`(replace-regexp-in-region ...)`。
- **驗證**：file 內容含 3 個 "bar" + 2 個 "foo"。
- **PASS 條件**：count 正確。
- **變奏**：mark 包後 3 個。

#### Workflow 19 — Query-replace-regexp 互動

- **動作**：開檔含 10 個 "fooN"（N=0-9）→ `M-x query-replace-regexp` `\bfoo([0-9])\b` → `bar\1` → `y/n/y/n/!` 互動。
- **不准**：bypass minibuffer。
- **驗證**：file 內容 `[bar0,foo1,bar2,foo3,bar4,bar5,bar6,bar7,bar8,bar9]`（前 4 個 y/n/y/n + 後 6 個全替換）。
- **PASS 條件**：sequence 對。
- **變奏**：mid-loop 按 `C-g` 中止。

#### Workflow 20 — 新檔 → 寫 → 落地

- **動作**：`C-x C-f ./tmp/fresh-{timestamp}.txt`（檔不存在）→ 打 "hello"  → `C-x C-s` → shell `cat` 確認。
- **不准**：先 touch 再 find-file。
- **驗證**：shell `test -f` 成功；內容 == "hello\n"。
- **PASS 條件**：file 落地。
- **變奏**：路徑含中文目錄名。

#### Workflow 21 — 編大檔不卡（**high risk**）

- **動作**：generate `./tmp/fixtures/large.org` （1.5MB，~30k 行）→ limn 開 → 計時：`C-v` ×10、`M-v` ×5、`M->` 跳尾、`M-<` 跳頂。
- **不准**：偷讀只渲染 visible 區段。
- **驗證**：
  1. 每個操作 wall-clock < 500ms。
  2. 截圖：跳尾後 chrome bar 行號 ≈ 30000。
- **PASS 條件**：4 個操作都 < 500ms + 跳尾正確。
- **變奏**：3MB / 60k 行。

---

### D. init.lisp / 客製化

**前置**：v038 開始前先建立 `./tmp/init.lisp.baseline`（代表性 init.lisp，含幾條 map! / 一個 hook / 一個 defun）。每個 D 系列 workflow 開始時 `cp ./tmp/init.lisp.baseline /tmp/.limn/init.lisp`，跑完還原。

#### Workflow 22 — keybind + hot-reload

- **動作**：編 init.lisp 加 `(limn/keymap:map! pdf-mode-map "n" 'pdf-next-page)` → 存 → 在 Limn 內 `M-x reload-init-file` → 開 PDF → 按 `n` → 截圖。
- **不准**：重啟 Limn 取代 hot-reload。
- **驗證**：
  1. 按 `n` 前後 chrome bar hash 不同（翻頁了）。
  2. *messages* buffer 沒有 error（截圖看訊息區）。
- **PASS 條件**：reload 成功 + n 真的翻頁。
- **變奏**：綁 `N` 為 prev-page 同時測。

#### Workflow 23 — 新 defun + 綁鍵

- **動作**：init.lisp 加 `(defun my-jump-mid () ... (pdf-goto-page (/ (pdf-total-pages) 2)))` 並綁 `<SPC>m` → hot-reload → 按 `<SPC>m` → 截圖。
- **不准**：直接呼 my-jump-mid。
- **驗證**：截圖 chrome bar 顯示頁碼 == total/2 （±1）。
- **PASS 條件**：跳到中頁。
- **變奏**：跳 1/3 處 (`<SPC>t`)。

#### Workflow 24 — 預設 zoom = 150%

- **動作**：init.lisp 加 `(setf *default-pdf-zoom* 1.5)`（或對應 setting）→ 重啟 Limn → 開 PDF → 截圖。
- **不准**：開檔後手動按 `+`。
- **驗證**：截圖中央區 variance 應顯著高於 zoom=1.0 的同檔同頁參照截圖（≥ 1.3×）。
- **PASS 條件**：載入時即 zoom。
- **變奏**：改 init.lisp 為 0.75，重啟。

#### Workflow 25 — which-key prefix（**high risk**）

- **動作**：init.lisp 加 `<SPC>f` prefix 含三個子綁定（`<SPC>fs` save, `<SPC>fo` open, `<SPC>fc` close）→ hot-reload → 按 `<SPC>f` 等 1.5s → 截圖 which-key 浮窗。
- **不准**：programmatic query which-key state。
- **驗證**：
  1. 截圖底部 / 中央有 menu 出現（vs. baseline 同樣按 SPC 但無 prefix 定義的截圖 — hash 必須不同）。
  2. 截圖含 "fs"、"fo"、"fc" 三組可辨識（OCR 或 hash region 個別比對）。
- **PASS 條件**：menu 顯示且包含 3 子項。
- **變奏**：5 子項；確認 menu 自動排版。

#### Workflow 26 — add-hook 驗證

- **動作**：init.lisp 加 `(add-hook 'pdf-mode-hook (lambda () (limn:message "PDF HOOK FIRED")))` → reload → 開 PDF → 截圖 *messages*。
- **不准**：直查 hook list。
- **驗證**：*messages* buffer 截圖含 "PDF HOOK FIRED"（hash 比對或 OCR）。
- **PASS 條件**：訊息出現。
- **變奏**：text-mode-hook 同樣機制。

#### Workflow 27 — 帶語法錯誤的 init.lisp（**high risk**）

- **動作**：init.lisp 故意刪一個 `)` → `M-x reload-init-file`。
- **不准**：先用 SBCL 編譯檢查再 reload。
- **驗證**：
  1. Limn process 還活（`pgrep limn` 有結果）。
  2. *messages* / minibuffer 有可讀錯誤訊息（截圖含字 "error" 或 "READ-ERROR" 或具體 file:line）。
  3. 原有 binding（pre-reload state）仍能用：按 `j` 翻頁仍可。
- **PASS 條件**：3 項全綠。
- **變奏**：未綁定 symbol。

---

### E. M-x / minibuffer / which-key

#### Workflow 28 — M-x completion → execute

- **動作**：`M-x` → 打 "que" → 截圖 completion list → `TAB` → 看自動完成到 "query-replace" → `RET` → 走 query flow。
- **不准**：`(execute-extended-command "query-replace")`。
- **驗證**：
  1. 打 "que" 後截圖底部 completion 區應有 ≥ 2 候選（截圖底部 hash 不等於空 minibuffer hash）。
  2. TAB 後 minibuffer 文字應 == "query-replace"（截圖 chrome 區與已知 "query-replace" hash 比對）。
- **PASS 條件**：completion + 自動完成都對。
- **變奏**：打 "qrr" 含義模糊，screen 應列多候選。

#### Workflow 29 — C-g 多階段 abort

- **動作**：4 個 case，每個獨立跑：
  1. `M-x` → 立刻 `C-g`。
  2. `M-x` → 打 "que" → `C-g`。
  3. `M-x` → 打 "que" → `TAB` → `C-g`。
  4. `M-x` → 打 "query-replace" → `RET` → 進 query-replace 流程 → `C-g`。
- **不准**：bypass minibuffer。
- **驗證**：每個 case 結束截圖 == baseline 主畫面截圖 hash（minibuffer 已關、無殘留）。
- **PASS 條件**：4/4 都乾淨關閉。
- **變奏**：用 ESC 取代 C-g。

---

### F. 系統整合

#### Workflow 30 — auto-revert（**high risk**）

- **動作**：limn 開 `./tmp/notes.txt` 含 "old" → shell 跑 `echo new > ./tmp/notes.txt`（從外部 terminal）→ 等 2s → 看 limn 截圖。
- **不准**：手動 `revert-buffer`。
- **驗證**：
  1. 截圖中央區應顯示 "new"（hash 比對：與「打開含 new 的檔」的 baseline hash 一致）。
  2. *messages* 應有 "Reverted" 類訊息。
  3. Limn process 仍活、無錯誤對話框。
- **PASS 條件**：3 項全綠。
- **變奏**：改檔成大幅增量（10MB），auto-revert 仍能跟。

---

## 3. 執行順序建議

照 risk × realism 排：先打 **realism A + risk 高** 的，因為這些最會逼出真 bug：

| 優先 | Workflow | 為什麼先做 |
|------|----------|------------|
| P0 | 05 dark-mode | v0.37 已知 G'-2 reader bug，必修 |
| P0 | 13 PDF→.org copy | 跨 mode 文字傳遞，多年 painful surface |
| P0 | 21 大檔 perf | 我從沒在 macOS 真的開過大 .org |
| P0 | 25 which-key prefix | UX 品質的指標 |
| P0 | 27 init.lisp syntax error | 防呆 / error path 一定要對 |
| P0 | 30 auto-revert | file-notify 整段在 macOS 沒真跑過 |
| P1 | 01-04, 06-12 | PDF 核心日常 |
| P1 | 14-20 | 編輯日常 |
| P1 | 22-24, 26 | init.lisp 日常 |
| P2 | 28-29 | minibuffer / C-g |

跑法：每個 workflow 單獨 commit 一個 receipt（`./tmp/receipts/{NN}/`），含 screenshots + 動作 log + PASS/FAIL judgment.

---

## 4. 違規記錄（self-honest log）

每次我自己違反 R1-R8 → 寫進 `./tmp/violations.log`。例如：

```
2026-05-26T14:32 W05 R3 violation: used (limn:call "view/get") instead of screenshot
  reason: thought "just to confirm"
  remediation: re-ran W05 from clean state with R3-compliant verify
```

事後可以審查我有多少次自我放水。

---

## 5. 決策 / 未決

**已定**：
- 長 paper PDF：`/tmp/Mirror-Symmetry-[Hori-et-al].pdf` ✓
- App name：`limn`（全小寫）✓
- init.lisp 路徑：`/tmp/.limn/init.lisp` ✓
- OCR：透過 `nix shell nixpkgs#tesseract --command tesseract ...` ✓
- Receipts / fixtures 全部放 `./tmp/`（worktree 內）✓

**還要我自己 grep 確認**（不阻塞，跑到再確）：
- init.lisp 的 hot-reload 命令名（`M-x reload-init-file`？）
- limn 是否吃 `LIMN_INIT_FILE` env 或 `--init` CLI flag 指定 init.lisp 路徑（不然要先改源碼）

跑 W22 前若發現 limn 寫死讀 `~/.limn/init.lisp` 而沒有 override hook → 這本身就是 v0.38 第一個 dogfood-blocking bug，要修。
