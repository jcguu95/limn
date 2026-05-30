# cursor-style-design.md

文字游標外觀 —— 設計與分階段計畫。狀態:⏭ planned（2026-05-29 開檔）。

第一個具體需求:**cursor alternating size**（游標交替大小）。這份 doc 收
所有「游標長什麼樣 / 怎麼動」的工作,跟 window 系統無關（它是 text-cursor
的渲染,不是 pane）,所以**不**折進 split-frame-design.md。

## 目標

讓文字游標的外觀可由後端配置、並支援「交替大小」這種動態樣式。

- **cursor alternating size**:游標在兩種大小之間交替（例如 blink 時不是
  單純顯示/隱藏,而是 full-block ↔ thin-bar,或大 block ↔ 小 block 來回）。
  比傳統 blink 更顯眼、好定位,尤其在大頁面 / 高解析度下「游標在哪」常難找。
- 順帶把游標樣式做成**後端可配置**的一等公民(box / bar / underline、寬度、
  顏色、blink 週期),對齊 Emacs 的 `cursor-type` / `blink-cursor-mode`。

## 設計取向(待定案,先記方向)

- **大腦在後端**:游標樣式是 buffer-local / mode 可覆寫的狀態,住在 Lisp
  (對齊 Emacs `cursor-type` 是 buffer-local 變數)。C++ 端只是照後端給的
  樣式參數畫。
- **wire 介面**:後端把 cursor spec 推給前端,例如
  `view/cursor-style {:type :box|:bar|:underline, :sizes [a b], :period-ms N}`。
  「alternating size」就是 `:sizes` 給兩個值 + 一個切換週期。
- **前端渲染落點**:游標目前畫在哪要先 grep（text widget 的 paint /
  `QPlainTextEdit` cursor、或 PDF 頁上的 text-cursor overlay）。alternating
  用一個 QTimer 在兩個尺寸間切,取代/疊在現有 blink timer 上。

## 開放問題

- alternating 是取代 blink 還是與 blink 正交?(可能:blink 控顯隱、size 控
  大小,兩者獨立)
- 只作用在 text-engine buffer,還是 PDF 內的 text selection caret 也要?
- 樣式是否進 defcustom / 預設 config(對齊本批 leader-keys 的 config 落點)。

## 分階段 sub-roadmap(planned)

- [ ] §1 grep 出游標目前的渲染落點(text widget / PDF caret),寫進本 doc
- [ ] §2 後端 cursor-spec 狀態（buffer-local,對齊 `cursor-type`）+ wire 指令
- [ ] §3 前端套用 type/size/colour(靜態先動)
- [ ] §4 alternating size 的 timer 切換(本批主訴求)
- [ ] §5 defcustom / 預設 config 暴露 + walkthrough 視覺驗證(CLAUDE.md §6)

## 驗證

游標是純視覺,headless 測不到「畫對沒」。靠 walkthrough script（繁中、絕對
路徑、印「預期看到什麼」+ y/n/c/a,見 CLAUDE.md §6）逐步目視。未來若上
golden-image（ISSUES I-8）可把 alternating 兩個 frame 各快照比對。
