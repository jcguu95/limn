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
