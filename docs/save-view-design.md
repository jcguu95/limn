# save-view-design.md

save view / jump-back —— 設計與分階段計畫。狀態:⏭ planned（2026-05-30 開檔）。

next-steps 的需求一句話:**「搜尋（或跳轉）之後，能一鍵跳回原本在看的地方。」**
更廣義是 Emacs 的 **mark ring + view register**:任何「我要離開現在這個視角」的動作
之前，先把目前視角存起來，事後可回去;也可以**具名**存一個視角、之後從任何地方跳回。

這份 doc 把這條線收在一起。它跟 `split-frame-design.md` 末尾的
**Bookmark Everywhere** 是**同一個機制的兩端**:bookmark = 具名持久版、
mark-ring = 匿名暫時版。所以本 doc 與那段刻意交叉引用、不重複造。

## 背景 —— 現況盤點

- **position mark ring 已存在**:`markup-interaction-design.md` 提到「`M-N` 開清單前
  先 push 一個 position mark，所以跳轉後 `C-o` 可回原處」—— 也就是「離開前 push、
  `C-o` pop 回去」這套已經有雛形（task B「跳回 / 跳前」）。
- **視角快照機制已存在**:`bridge/win-focus` 在切 window 時會 snapshot/restore
  `(page, zoom, offset_x, offset_y)`（`LimnWindow`，v0.15）。**「一個視角」就是這四個
  欄位**（外加 buffer / 文件路徑、可選 rotation）。
- **跨-buffer 具名書籤已另行實作**:split-frame-design.md 註明「跨-buffer 命名書籤已於
  optimistic-brahmagupta 分支 v0.37 另行實作」。要先確認它落地到哪、與本 doc 怎麼合流。

**結論:擷取/還原視角的零件都在。本批是把它組成一致的「mark ring（匿名）+ view
register（具名）」UX，並把『跳轉前自動 push』接到該 push 的地方（搜尋、goto-page、
書籤跳轉、M-N…）。**

## 目標

1. **jump-back（匿名 mark ring）** —— 任何大跳轉（搜尋落定、goto-page、bookmark-jump、
   link 跳轉）前自動 push 目前視角到 ring;`C-o`（back）/ `C-i`（forward）在 ring 上走。
   對齊 Emacs `mark-ring` / evil jumplist（`C-o` / `C-i`）。
2. **save view（具名 view register）** —— `set-view <reg>` 存目前視角、
   `jump-view <reg>` 跳回（需要時先開檔）。對齊 Emacs `window-configuration-to-register`
   / `point-to-register`。這是 Bookmark Everywhere 的「register」面，持久化進 DB。
3. **與 split 的綜效** —— 有了 per-pane DV（Phase 3a 已 ship），「跳回某視角」可以是
   「還原進 focused pane」甚至「在新 split 裡開」。

## 設計取向（待定案，先記方向）

- **大腦在後端**:mark ring 與 view register 都是 Lisp 狀態。一個 view-snapshot =
  `(buffer-id / path, page, zoom, offset-x, offset-y[, rotation])` —— 跟 `LimnWindow`
  在 win-focus 做的 snapshot **同一個 struct**，本 doc 不另造，直接複用 + 取名 / 入 ring。
- **自動 push 的落點**:在「會大跳轉」的 command 進入點呼叫 `push-view-mark`。對齊 Emacs
  `push-mark` 的時機（搜尋、goto、imenu 跳轉前）。search-design §「搜尋前 push」就是叫這個。
- **持久 vs 暫時**:mark ring 是 session 內 in-memory（evil jumplist 體感）;view
  register 具名、寫進 sioyek 既有 DB（`local.db` / `shared.db`），跨 session。對齊
  Bookmark Everywhere 的儲存層。
- **跳回 = win-focus 的還原邏輯**:「需要的話先開檔 → 設 page/zoom/offset」≈ win-focus
  restore，零件已存在。

## 開放問題

- mark ring 的範圍:per-buffer、per-window、還是 global ring?（Emacs 是 per-buffer
  mark-ring + global-mark-ring;evil 是 per-window jumplist。傾向:先 global jumplist
  體感，夠用再細分。）
- 與 v0.37「跨-buffer 命名書籤」如何合流 —— 是同一個 register store 換皮，還是並存?
  動工前先盤那支實作，避免第三套平行機制（重蹈 notes-panel 技術債）。
- ring 容量 / 去重（連續同位置不重複 push）。
- 具名 register 的選單:走 Fuzzy Selector（`completion-ui-design.md`）列 register。

## 分階段 sub-roadmap（planned）

- [ ] §1 盤點 v0.37 命名書籤 + 既有 position mark ring 實作，定合流方案，寫進本 doc。
- [ ] §2 view-snapshot struct 抽共用（複用 win-focus 的 snapshot/restore）。
- [ ] §3 匿名 mark ring + `push-view-mark`，接到搜尋/goto/bookmark/link 的跳轉前。
- [ ] §4 `C-o` / `C-i`（back/forward）導航 + evil jumplist 對齊。
- [ ] §5 具名 view register `set-view` / `jump-view`，持久化進 DB（合流 Bookmark Everywhere）。
- [ ] §6 register 選單走 Fuzzy Selector。
- [ ] §7 鍵位收進 `SPC r`（register，leader）+ evil `C-o`/`C-i`。

## 驗證

- **headless 可測**:push/pop ring 的序、view-snapshot 的擷取/還原等價性、register
  set/jump 的 round-trip（存了再跳，page/zoom/offset 一致）—— 全寫 unit test。
- **真機目視**:跳回後「畫面真的回到原視角」走 walkthrough（CLAUDE.md §6）。

## 關聯

- `split-frame-design.md`「周邊功能 —— Bookmark Everywhere」—— 具名持久版的另一端，合流。
- `search-design.md` §「搜尋前 push」—— 搜尋進入時呼叫 `push-view-mark`。
- `completion-ui-design.md` —— register 選單的 Fuzzy Selector。
- `LIMN-SPEC.org` v0.15（win-focus snapshot）—— 擷取/還原視角的權威。
