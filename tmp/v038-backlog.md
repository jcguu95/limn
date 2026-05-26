# v0.38 Backlog — bugs / 環境問題，**先記不修**

跑 dogfood workflow 過程中浮出來的東西。每條註明「會 block 哪些
workflow」。**Sprint 結尾統一處理**，不允許中途插隊。

---

## B1 — `pdf-rotate-cw` 呼叫不存在的 wire cmd

**症狀**：`pdf-rotate-cw` 仍呼 `"bridge/engine-params"`，但這個 wire
cmd 沒註冊（跟修前的 G'-1 toggle-dark 同病）。

**位置**：`backend/limn-pdf-mode.lisp:688`

**修法**：跟 G'-1 同樣，改呼 `view/set` 帶 `:|engine-params|` nested。

**Block 哪些 workflow**：
- W30 個 workflow 裡**沒有**直接測 rotate 的（`r` 鍵不在 30 個動作裡）
- 不阻塞 v0.38 任何 workflow ✓

**處理時機**：sprint 結尾 batch-fix。

---

## B2 — docker 抓不到 paint pixel

**症狀**：`test/grab-window` 在 Xvfb headless 回傳空白 PNG
（QOpenGLWidget::grabFramebuffer() 在 swrast 下不可靠，v0.37 G'
已知）。docker 容器內又沒裝 `xwd` / `scrot` / `imagemagick`。

**修法**：兩條路擇一：
- (a) `flake.nix` dockerExtras 加 `pkgs.imagemagick` 或
  `pkgs.scrot`（`deps:` commit）→ 用 `import -window root` 從
  Xvfb root 抓（Xvfb root 有 paint，不靠 GL framebuffer grab）
- (b) 都不裝，純 wire 驗證

**Block 哪些 workflow**（**只要 strict pixel verify**才會卡）：

| W# | 需要 pixel verify？ | Block? |
|----|---|---|
| W01 j×30 | chrome bar hash 即可（chrome 不依賴 GL framebuffer）| 可能 OK |
| W02 prefix-arg | 同上 | 可能 OK |
| W03 zoom | 中央 variance 比較 → 需 paint | **YES** |
| W04 TOC | hash 差異 | 可能 OK |
| W05 dark-mode | reader bug，wire diagnostic 足以驗 | DONE |
| W06 搜尋 | highlight 黃像素數 → 需 paint | **YES** |
| W07 isearch | highlight | **YES** |
| W08-12 annotation/bookmark | highlight 黃像素 | **YES** |
| W13 PDF→.org copy | 文字 content 比對 | 部分 |
| W14-21 文字編輯 | 多數靠 file-system verify | 可能 OK |
| W22-27 init.lisp | wire verify 為主 | 可能 OK |
| W28-29 M-x/C-g | chrome region hash | 可能 OK |
| W30 auto-revert | content verify | 部分 |

**結論**：能跑的先跑，撞到 strict pixel 卡死就「降級」（記下並標
"pixel-deferred"），最後一起補強。

**處理時機**：sprint 中段（跑完不靠 pixel 的 ~15 個之後再來決定）。

---

## B3 — `limn.app/Contents/Info.plist` 空檔

**症狀**：macOS bundle metadata 完全缺失。`tell application "limn"`
失效；`count windows of process "limn"` = 0；Dock / Cmd-Tab / Spotlight
都不認 limn 是正規 app。

**修法**：寫一份基礎 Info.plist 進 `sioyek/limn.app/Contents/`，含
CFBundleName / CFBundleIdentifier / CFBundleExecutable /
CFBundleVersion / CFBundleShortVersionString / NSHighResolutionCapable。
build script 要 copy。

**Block 哪些 workflow**：
- v0.38 內**只有 macOS sanity sweep**（sprint 結尾的抽樣）會用到
- docker 內全部 workflow 都不受影響 ✓

**處理時機**：sprint 結尾、macOS sweep 之前。

---

## B6 — limn C++ stack smashing crash 中 dogfood session

**症狀**：W22 跑到 Phase B（v 按鍵或更早）limn 突然死，stderr：

    *** stack smashing detected ***: terminated

死前 view/get / engine-load 都還 OK。死後 wire 連線 broken pipe。

**位置**：未定。可能在 keypress 處理路徑、或 buffer focus 路徑、
或 wire JSON 解碼。需要 gdb-attach 才能定位。

**Block 哪些 workflow**：
- W22 (keybind+reload) 直接撞到
- 任何其他在連續操作中可能踩到的 — 不可預測，但 v0.37 OS-tier
  跑 111 個 driver 是 0/0，所以崩潰罕見。可能 W22 的特定 sequence
  (init.lisp + map! + 按 v) 才會 trigger
- 暫定不 block 其他 workflow，撞到再說

**處理時機**：sprint 結尾 batch（需要 debugger 才能定位，重活）。

---

## B7 — `(map! :mode 'pdf-mode KEY FN)` 從 init.lisp 設的綁定，
       reload 後按 KEY 沒觸發

**症狀**：W22 Phase B 寫 init.lisp 含
`(limn/map-macro:map! :mode 'pdf-mode "v" 'my-w22-canary)`，呼
reload-init-file 成功（log 印 `;; reload-init-file: ...`，無 ERRORED），
但隨後 xdotool key v 沒觸發 my-w22-canary（檔案 /tmp/w22-canary 不存在）。

**可能原因**：
- pdf-mode 並未啟用在 active buffer 上（engine-load 沒 auto-activate？）
- pdf-mode-map 是 reload 後重建的 keymap object，但 dispatch 仍指向
  舊的 keymap 物件
- limn/map-macro:map! :mode 路徑展開有問題（fbound 但實際沒 install）
- 或 limn 已經 crash 了（見 B6）只是 driver 不知道

**Block 哪些 workflow**：
- W22, W23 直接撞
- W26 (add-hook) 可能撞同個 path
- W24 (default zoom) 用 setf 不用 map!，可能 OK

**處理時機**：撞到 W23 / W26 後再決定。可能跟 B6 同源。

---

## B8 — `limn/file:find-file` 拒絕不存在的路徑

**症狀**：dogfood spec W20 「C-x C-f 一個還沒存在的路徑、打內容、
存」對應的 `limn/file:find-file` 卻 `(error "limn/file: file does
not exist: ~s")`。Emacs 慣例是：找不到的 path 自動開 new buffer
（modeline 顯示 "(New file)"）。

**位置**：`backend/limn-file.lisp:155`：

    (unless (funcall *file-exists-p-fn* abs)
      (error "limn/file: file does not exist: ~s" abs))

**Block 哪些 workflow**：W14 + W20 直接撞（"新檔" 場景）。其他「開
既有檔」workflow 不撞。

**處理時機**：sprint 結尾 batch；workaround：先 shell `touch` 再
find-file。已套用於 W20。

---

## B9 — `limn/file` 的 buffer registry 跟 wire `buffer/list` 互不相通

**症狀**：W20 A.2 ── `(limn/file:find-file path)` 回 `limn-file-buf-1`
buffer-id，但 wire `buffer/list` 回空 list (paths=NIL)。兩個 buffer
namespace 各自獨立。

**影響**：(a) M-x switch-to-buffer 看不到 find-file 開的檔；(b) wire
的 buffer-opened event 也不會 fire；(c) sidecar hook 不會跑。對「find-
file」這個 user-facing action 來說是嚴重 design split。

**Block 哪些 workflow**：W14, W17 (跨檔 kill/yank), 任何用到 buffer/list
看「我打開了什麼」的 workflow。

**處理時機**：是 design issue，需要規格決議才修。sprint 結尾 surface。

---

## B10 — `xdotool type STRING` 沒觸發 self-insert (text-mode)

**症狀**：W20 Phase B 用 `xdotool type "hello"` 對一個 limn/file
開的 .txt buffer 送 5 個字元 — limn C++ 應該收到 5 個 KeyPress，
text-mode 應該 self-insert "hello" 進 buffer，save-buffer 後 disk 內
容應該是 "hello"。實際 disk 內容是空 string。

**可能原因**（跟 W22 B7 同源？）：
- text-mode 沒在這個 buffer 上 activate（limn/file:find-file 不裝 mode？）
- self-insert 沒綁，或綁了但 dispatch 不上
- buffer 不是 focused window 的 buffer（xdotool 送到某個 dummy buffer）

**Block 哪些 workflow**：W14 (打 TODO), W16 (CJK 編輯), W17 (kill/yank),
W19 (query-replace 替換的字), W18 同。**很多文字編輯 workflow 都會撞**。

**處理時機**：撞到 W14 / W16 再決定。如果是 limn/file 不 activate 
mode 的問題，那可能跟 B9 同根。

---

## B11 — pdf-goto-page 沒綁任何 key（vim 12g 失效）

**症狀**：W02 試 "12g" 期望跳到 page 12 — 沒效。digits 進 prefix-arg
但隨後的 'g' 是 "g g" sequence 的開頭，不會 trigger pdf-goto-page。
找了 limn-pdf-mode.lisp：`pdf-goto-page` 有 defcmd 但**沒綁任何 key**。

**修法**：在 pdf-mode-map 加一個能 take 數字 prefix 然後跳頁的 binding。
vim 慣例是 N + 'G' 跳第 N 頁；目前 G 是 last-page。可改 'g g' 帶
prefix → goto, 或專屬 ':p' / 'gg' 邏輯。需要規格決議。

**Block 哪些 workflow**：W02 直接撞。

**處理時機**：sprint 結尾。

---

## B12 — `xdotool key G`（Shift+g）不觸發 pdf-last-page

**症狀**：W02 試 `G` 期望跳 last page (page-count - 1 = 5)，page 仍
是 0。limn log 顯示 `key=G mods=0x2000000 obj=MainWidget`（Qt::Shift
+ G 正確抵達 C++ 端），但 dispatch 不到 "G" binding。

**可能原因**：keymap dispatch 在 mods=Shift 時 key string 變 "S-G"
或 "S-g"，而 binding 是 "G"（缺 S- 前綴）。需查 keymap normalize。

**Block 哪些 workflow**：W02 / 任何需要 Shift+letter 的 binding。
注意 v0.37 W05 的 'd' (lowercase, 無 shift) 是 OK 的。

**處理時機**：sprint 結尾；可能也牽涉 B5（M-r 是 Alt+r 同類）。

---

## B13 — 數字 prefix-arg 沒倍乘 pdf-scroll-down (5j ≠ 5×j)

**症狀**：W02 試 `5j`：digit 5 accumulate 後 j 應 scroll 5×，但實際
只 scroll 1× (offset-y += 0.1 而非 0.5)。

**可能原因**：(a) prefix accumulator 已被前一個 sequence 清空、(b)
pdf-scroll-down 不讀 prefix、(c) %dispatch-key 在 mode-buffer lookup
時把 prefix-arg 吞掉。v0.37 G' A10 fix 明確改成「mode-binding lookup
先，數字才當 prefix」— 可能那個 fix 有 side-effect。

**Block 哪些 workflow**：W02 + 任何用 prefix 的 vim 動作。

**處理時機**：sprint 結尾；跟 B11 同源（prefix-arg 流程）。

---

## B5 — `xdotool key alt+r` 沒觸發 M-r → reload-init-file

**症狀**：W27 走測試發現，從 docker xdotool 送 `alt+r`，limn C++ 端
看到 `KeyPress key=r mods=0x8000000 obj=MainWidget`（Qt::AltModifier
正確），但 driver SBCL 端的 `*global-keymap*` "M-r" binding 沒被呼。
init.lisp 沒被 reload。

**位置**：dispatch chain from C++ keypress event → wire → driver
keymap lookup。可能是 mods 轉成 "M-r" 字串的步驟有 mismatch。

**證據**：
- W27 第一次跑 `xdotool key alt+r` → canary 檔沒寫入
- 改成 `(limn/cmd:call-interactively ...)` 直接呼 → 5/5 PASS

**修法**：要 trace 從 wire keypress 到 keymap lookup string。或許
"alt"+"r" 的 keysym 字串組起來不是 "M-r"。可能在 limn-input.lisp /
limn-keys.lisp。

**Block 哪些 workflow**：
- W22 (keybind hot-reload) — 要按 n 翻頁，n 是 pdf-mode 內 binding
  （不是 M-r），可能 OK
- W23 (defun + bind <SPC>m) — SPC + m，無 modifier，可能 OK
- W28 (M-x completion) — 需要 M-x dispatch 到 execute-command，**很可能 block**
- W29 (C-g abort) — C-g 是 control，跟 M- 不同 modifier path，**待測**

**處理時機**：撞到 W28 / W29 真 block 時再修。沒就 sprint 結尾 batch。

---

## B4 — macOS host osascript 不適合並行使用者

**症狀**：user 同時在 macOS 上工作，會搶 focus，鍵打到別處。

**修法**：本身不是 bug，是工作習慣 vs. 自動化的衝突。解法：
- v0.38 多數 workflow 跑 docker（R1'）
- macOS sanity sweep 排在 user 不用機器的時段（晚上 / 提前說一聲）

**Block 哪些 workflow**：W30 + macOS sweep。

**處理時機**：跑 W30 / sanity sweep 之前安排時間。

---

## 處理規矩

1. **新發現的 bug**：寫進這個檔，**不要動手修**。
2. **若 bug 真的 block 當下 workflow**：明確標 "blocks Wxx"，標 PRIORITY 0，等該 workflow 跑到再決定要不要破例修。
3. **Sprint 結尾**：把 backlog 一次處理完，再做 verification sweep。
