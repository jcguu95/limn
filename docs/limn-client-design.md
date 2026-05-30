# limn-client-design.md

`limn-client`（socket based，emacsclient 風格的外部介面）—— 設計與分階段計畫。
狀態:⏭ planned（2026-05-30 開檔）。**使用者定的總優先序第一位**
（`limn-client > minad > doom > windows/frames`）。

一句話:**讓外部（終端機 / script / 其他程式）連到一個「正在跑的」limn，把
Lisp form 送進去 evaluate、拿回結果，外加幾個基本操作。** 對齊 Emacs 的
`emacsclient`：server 已在跑，client 連上去注入。

## 為什麼排第一（meta-level dev 地基）

它不是 app feature，是**開發 / 驗證 / 自動化的地基**：

- 我（Claude）的 headless 探針、DeepSeek loop 驗證前端、使用者從外部 script 操作
  limn —— **全都靠「能對 running limn eval form 查狀態 / 驅動」**。
- 目前這件事是用 `run-repl.sh` **每次起一個全新 stack** 達成的（慢、重、不是連到
  你正在用的那個實例）。正式化成 emacsclient 風格的輕量 client，整個 meta-level
  開發迴圈都受益。這跟「先把 deepseek meta-level dev 弄紮實」同一個方向。

## 背景 —— 現況盤點

limn 的 socket 拓樸（讀 `backend/repl.lisp` / `backend/limn-client.lisp` / `limn.lisp`）：

- **SBCL backend 是 spawner + 大腦**：`spawn-limn` 起一個 limn binary 子程序，傳
  `--socket /tmp/limn-repl-<pid>`。
- **limn binary（Qt frontend）bind 並 listen 那個 socket**（是 socket server）；
  SBCL 透過 `backend/limn-client.lisp` **連上去當 client**，送 `view/*` 指令、收
  key/mouse events。方向是 **SBCL（client）→ frontend（server）**。
- **`run-repl.sh`** = 載入所有 backend 模組 → spawn 一個 limn → drop 進互動 SBCL
  prompt；`--eval` 可在載入後跑 form（我做 headless 探針就是用這個 + `(limn:call …)`
  / `repl-helpers.lisp` 的 `(o)`/`(wf)`/`(vg)`…）。
- 已有零件：`sb-bsd-sockets`、`sb-thread`、`limn-client.lisp` 的 socket I/O、
  `repl.lisp` 的 spawn/wait-for-socket、`limn:call` wire 呼叫。

**缺口**：沒有「連到一個**已經在跑的** SBCL backend、從外部注入 form」的介面。
現在每次都是 `run-repl.sh` 起一個新的 SBCL+frontend stack，不是 attach 到既有實例。

> ⚠ **命名張力**：既有的 `backend/limn-client.lisp` 指的是「SBCL → frontend」那個
> client。本 feature 的「limn-client」方向相反（外部 → SBCL backend）。實作時要
> 避免撞名 —— 暫定 backend 端叫 **eval-server**（`limn-eval-server.lisp`），對外
> CLI 叫 **`limn-client`**（或 `limnclient`）。命名最終定案見 §1。

## 目標

1. **eval**：`limn-client --eval '(some-form)'` → 連到 running limn 的 SBCL backend、
   eval 該 form、印回結果（多值 + 標準輸出 + condition）。
2. **基本操作**（使用者要的「其他基本操作」）：open file、呼叫命令、查狀態 ——
   全部都是「eval 一個 form」的便利包裝（例如 `--open <pdf>` ≈ eval `(o "<pdf>")`）。
3. **attach 既有實例**：連到一個**正在跑**的 limn，而不是每次起新 stack。

## 設計取向（待定案，先記方向）

- **連到 SBCL backend，不是 frontend**：使用者要 eval **Lisp form**，那是大腦的事。
  所以要在 SBCL backend 端**另起一個 eval-server socket**（獨立於 frontend wire
  socket），listen 外部連線。eval 在 backend 跑 → 能 access 所有 limn 狀態
  （buffer/window/keymap/mode…）並透過既有 frontend wire 連動畫面。
- **eval-server 落點**：backend 起一個 listener thread（`sb-thread` + `sb-bsd-sockets`）
  listen 一個 unix socket。accept → read form 字串 → eval → 把 result / output /
  error 寫回。
- **thread-safety（關鍵風險）**：backend 主迴圈在處理 frontend events；外部 eval 若
  在 listener thread 直接 eval，可能跟主迴圈競爭狀態。兩條路：
  - (a) **直接 eval**（listener thread 自己跑）—— 簡單，dev 工具可接受，先這樣。
  - (b) **safe-point queue** —— eval 請求進 queue，主迴圈在安全點 drain 執行、回結果。
    正確但複雜。**先 (a)，撞到競爭再升 (b)**。
- **協議**：既然送的是 Lisp form，最自然是 **sexp/字串 in、sexp 結果 out**
  （length-prefixed 或以換行/EOF 分界），不必套 JSON wire。錯誤回一個帶 condition
  訊息的結構。
- **socket path 慣例**：固定可發現的 path（emacsclient 的 server-name 模型），例如
  `/tmp/limn-eval-<session>.sock` 或環境變數 `LIMN_EVAL_SOCK`，讓 client 不用猜 pid。
- **CLI 形態**：輕量 —— 可以是一個小 SBCL script、或純 `socat`/`nc` 包裝、或 python。
  傾向極小依賴（emacsclient 本身是 C，但我們要的只是「連 unix socket、送字串、印回應」，
  `socat` 一行就能 PoC，正式版做成 `limn-client` script）。
- **安全**：eval = 任意程式碼執行；socket 是本機 unix domain + 檔案權限管控。定位是
  dev 工具，可接受；正式 limn 啟動是否預設開 server 設成可關（§5）。

## 開放問題

- eval-server 要不要在**正常啟動的 limn**（非 test-mode）也預設開？要 attach「你正在
  用的」limn 就得開；但那等於常開一個 eval 後門 → 做成 opt-in（defcustom / 旗標）。
- 多實例：同時跑多個 limn 時 client 怎麼選（server-name / socket path 參數）。
- thread-safety 先 (a) 還是直接做 (b)？取決於 backend 主迴圈對「他 thread 改狀態」
  的敏感度 —— §2 先 spike 測競爭。
- 結果序列化：form 的回值可能不可 `read`（含 #<…> 物件）→ 回 `princ` 字串還是
  嘗試可讀化？傾向回 `prin1` 字串 + 不可讀時 fallback `princ`。
- 跟既有 `run-repl.sh` 的關係：limn-client 是否乾脆內建「若沒有 running 實例就起一個」
  （像 `emacsclient -a`）？先不做，保持單純 attach。

## 分階段 sub-roadmap（planned）

- [ ] §1 命名定案（backend `limn-eval-server` vs 對外 `limn-client`）+ socket path 慣例。
- [ ] §2 backend eval-server：listener thread、accept、read form、`eval`、回
      result/output/condition（先走「直接 eval」(a)，並 spike thread-safety）。
- [ ] §3 CLI `limn-client --eval '(form)'`：連 socket、送、印回應（先 socat PoC → script）。
- [ ] §4 基本操作包裝：`--open <pdf>`、`--call <cmd>`、`--query <expr>`（皆 eval 特例）。
- [ ] §5 在正常啟動的 limn opt-in 開 server（defcustom / 旗標），讓 client 能 attach
      「你正在用的」實例。
- [ ] §6 驗證 + 收編既有探針：把 headless 探針 / loop 的前端驗證改走 limn-client。

## 驗證

這個 feature **本身就是驗證工具**，所以很好 self-test、且 headless 可測：

- 起一個 headless limn（開了 eval-server）→ 用 `limn-client --eval '(+ 1 2)'` 斷言回
  `3`；eval `(buffer-count)` 之類斷言狀態；eval 一個會 error 的 form 斷言錯誤回傳格式。
- 全部寫成 unit / e2e 斷言（給定 form → 預期回應），不靠人眼。
- 收編後，DeepSeek loop 與 headless 探針改用 limn-client，等於用它自己驗它自己。

## 關聯

- `backend/repl.lisp` / `backend/limn-client.lisp` / `backend/limn.lisp` —— 現有 socket
  拓樸與 spawn/連線機制（本 feature 的地基；注意命名張力）。
- `meta/loop/`（thin loop）—— loop 驗證前端的探針未來改走 limn-client（meta-level 受益）。
- `LIMN-SPEC.org` —— wire 協議權威；eval-server 是它之外、給「開發 / 自動化」用的
  旁路 socket（不是給 frontend 的 wire）。
