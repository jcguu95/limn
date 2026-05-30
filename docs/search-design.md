# search-design.md

pdf 搜尋 UX 升級 —— 設計與分階段計畫。狀態:⏭ planned（2026-05-30 開檔）。

這份 doc 收「**怎麼搜、怎麼在結果間移動、怎麼讓結果看得清楚**」的工作。重點:
搜尋的**底層機制大半已 ship**,本批是**整合 / 收尾 / 把既有能力 surface 出來**,
不是從零造。先講清楚現況,免得重造輪子。

## 背景 —— 現況盤點（已 ship 的零件）

權威在 `LIMN-SPEC.org`（§B 搜尋 / v0.26 isearch / v0.27 多頁 buffer/search）與
`backend/limn-pdf-mode.lisp` §B。已存在的零件:

- **per-window 搜尋狀態**:`*pdf-search-states*`（`win-id → pdf-search-state`），
  每個 window 各有獨立的搜尋游標（`pdf-search-state-query` / `-hits` /
  `-current-index`）。`%search-state` / `%set-search-state` 經 `*current-win-id*`
  存取。
- **next / previous**:`pdf-search-advance` / `pdf-search-retreat`（含 wrap-around，
  `*pdf-wrapped-message*`）。
- **計數格式化**:`pdf-format-search-counter`（「第幾 / 共幾筆」的字串已經有 formatter）。
- **進階比對 helper（已寫、未必接進 UX）**:`pdf-search-narrow-by-substring`、
  `pdf-search-rank-fuzzy`、`pdf-search-filter-hits`。
- **多頁搜尋 wire**:`buffer/search`（v0.27，走 MuPDF `fz_search_page` 逐頁掃，
  回傳 page-normalized 0..1 rects）。
- **isearch（互動式 incremental search）**:`limn/search:isearch-forward`（v0.26 ✅，
  狀態機 `isearch-start → isearch-update ↔ isearch-next/prev → isearch-exit/abort`）
  —— **但目前主要在 text-engine buffer**，pdf-mode 的 `/` 是否完全走它要先確認。
- **搜尋 highlight 改底線**:`markup-interaction-design.md` (丙) 已把搜尋 overlay
  從填色色塊改成**底線**樣式（current match 加亮），與 limn highlight 的填色正交。
- **歷史**:`*search-history*`（v0.25 `add-to-history`），minibuffer 可上下取回。

**結論:`pdf-search-state` 這台機器很完整。本批是把散落的能力（advance/retreat、
counter、narrow、fuzzy、isearch）整合成一致、emacs 體感的搜尋 UX，並補上缺口。**

## 目標（對齊 next-steps 大綱）

1. **next / previous** —— 確認 `n`/`N`（或 `C-s`/`C-r`）一致地走
   `pdf-search-advance` / `pdf-search-retreat`，含跨頁 + wrap 提示。
2. **顯示「第幾 / 共幾筆」+ current** —— 把 `pdf-format-search-counter` 接到
   modeline / echo area，移動時即時更新（`[3/17]` 這種）。
3. **emacs-like search，不要 adhoc** —— 把 pdf 的 `/` 收編到 `limn-isearch`
   狀態機（incremental、逐字即時跳、`C-s`/`C-r` 繼續、`RET` 落定、`C-g` 取消回原處），
   消除「pdf 一套、text buffer 另一套」的雙搜尋路徑。
4. **確保 highlight** —— 對齊 markup-interaction (丙) 的底線樣式;current match
   要明顯（加亮 / focus）。搜尋結束（exit/abort）要可靠清除短暫 overlay。
5. **進階搜尋** —— 把既有 helper surface 成互動 UX:
   - **narrow** —— 在搜尋結果上再用子字串收斂（`pdf-search-narrow-by-substring`），
     對齊 minad orderless 的漸進式縮小（與 `completion-ui-design.md` 同精神）。
   - **fuzzy** —— `pdf-search-rank-fuzzy` 做模糊排序;與 Fuzzy Selector 共用 fzf 評分。

## 設計取向（待定案，先記方向）

- **大腦在後端**:搜尋狀態機、hit 清單、current-index、narrow/fuzzy 全在 Lisp
  （`limn-pdf-mode.lisp` §B + `limn-search.lisp`）。C++ 端只負責 (a) `buffer/search`
  逐頁掃文字、(b) 照後端給的 rect 畫底線 overlay。沿用既有分工，不加新 C 指令。
- **counter 落點**:後端把 `pdf-format-search-counter` 的字串塞進 modeline 或 echo，
  經既有 wire（modeline / message）推前端，不需要新 primitive。
- **isearch 收編**:pdf-mode 的搜尋 entry（`/`、`C-s`）改成呼叫 `limn-isearch` 的
  `isearch-start`，把 pdf 的 hit 來源（`buffer/search`）接成 isearch 的 candidate
  provider。難點:pdf 是「多頁 + 非同步逐頁掃」，isearch 的即時性要能 stream 結果
  （見開放問題）。
- **narrow / fuzzy 的 UX 形狀**:兩條路 ——
  (a) 搜尋當下就 orderless（多 token 逐步縮）;
  (b) 搜出一堆 hit 後開一個 occur/清單 buffer（複用 `M-N` 那套 tablist），在清單裡
  narrow/fuzzy 篩。傾向 (b) 當逃生門、(a) 當快速路徑，跟 markup-interaction 的
  「清單為主、in-page 為輔」同構。

## 開放問題

- isearch 的**即時性** vs. pdf **逐頁非同步掃**:大文件搜尋會 stream（「Background
  search: 3 hits in page 5」那種進度），isearch 要能邊掃邊跳到目前第一個 hit、掃完
  再補。要不要設一個「先掃可見頁 + 鄰頁，其餘 background」的策略?
- narrow/fuzzy 是搜尋層的事，還是該完全交給 Fuzzy Selector（`completion-ui-design.md`）
  的 orderless?（傾向:hit 清單一旦進 completing-read，就吃 Selector 的 orderless，
  search-design 不另造一套比對器 —— 只負責「把 hit 灌進 Selector」。）
- current match 的視覺:底線加亮夠不夠?要不要 focus ring（會跟 markup 的
  current-annotation focus ring 撞 channel）?
- 搜尋的 save/jump-back:搜尋前 push 一個 position mark，`C-g`/結束後可跳回 ——
  這屬於 `save-view-design.md`，本 doc 只負責「搜尋進入時呼叫它 push」。

## 分階段 sub-roadmap（planned）

- [ ] §1 現況盤點落地:把 `pdf-search-state` 既有 API（advance/retreat/counter/
      narrow/fuzzy/isearch）逐一確認「接進 UX 沒、還是只有 helper」，列成表寫進本 doc。
- [ ] §2 counter surface —— `pdf-format-search-counter` 接 modeline/echo，移動即時更新。
- [ ] §3 next/previous 鍵位一致化（走 advance/retreat + wrap 提示）。
- [ ] §4 isearch 收編 —— pdf `/` / `C-s` 改走 `limn-isearch` 狀態機，消除雙路徑。
- [ ] §5 highlight 保證 —— 對齊 markup (丙) 底線、current 加亮、exit 可靠清除。
- [ ] §6 進階 narrow（子字串漸進縮，接 `pdf-search-narrow-by-substring`）。
- [ ] §7 進階 fuzzy（`pdf-search-rank-fuzzy` + Fuzzy Selector 共用評分）。
- [ ] §8 鍵位收進 `SPC s`（leader）/ evil `/` `n` `N`（見 leader-keys / evil doc）。

## 驗證

- **headless 可測的部分**（後端狀態機）:`buffer/search` 回傳 hit 數、`advance/retreat`
  的 current-index 推進、`format-counter` 字串、narrow/fuzzy 排序結果 —— 全部寫成
  unit test（`backend/tests/unit/`），這些是純資料、不靠眼睛。
- **headless 幾何斷言**:搜尋後 overlay rect 數 / 座標可經 wire 查（對齊 ISSUES I-8
  的 query-command 思路）。
- **真機目視**（底線樣式、current 加亮、isearch 即時跳）:走 walkthrough script
  （繁中、絕對路徑、印「預期看到什麼」+ y/n/c/a，見 CLAUDE.md §6）。

## 關聯

- `markup-interaction-design.md` —— (丙) 搜尋改底線、清單 buffer（occur）那套 tablist。
- `completion-ui-design.md` —— narrow/fuzzy 的 orderless 比對共用 Fuzzy Selector。
- `save-view-design.md` —— 搜尋前 push position mark，結束可 jump-back。
- `LIMN-SPEC.org` §B / v0.26 / v0.27 —— 搜尋 wire 與 isearch 的權威規格。
