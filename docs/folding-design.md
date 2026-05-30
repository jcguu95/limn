# folding-design.md

emacs-like overlay + org 式 folding —— 設計與分階段計畫。
狀態:⏭ planned（2026-05-30 開檔）。

next-steps 的 **buffers basic** 底下:**emacs-like overlay? / how's org folding
achieved?** 這兩題其實是一題 —— **org folding 是用 overlay 的 `invisible` 屬性做出來
的**。所以本 doc 先講清楚 overlay 這個 primitive,再用它組出 folding。

## 背景 —— overlay 現況 + org folding 怎麼來的

- **`view/overlays` primitive 已存在**（LIMN-SPEC §12 / v0.14 paintGL）:在視埠上畫
  疊加層,支援 `rect` / `line` / `text` type、opacity、page-normalized 0..1 座標。
  但**目前是「視覺疊加」**（PDF 之上畫東西),**還不是 Emacs 那種「掛在 text buffer
  區間、能改文字行為」的 overlay**。
- **Emacs overlay 是什麼**:掛在 buffer 一段區間 `(beg . end)` 上的屬性集合 ——
  `face`（變色）、`invisible`（隱藏 → **這就是 folding**）、`before-string`/
  `after-string`（插入虛擬文字 → folding 的 `...` 省略號 / margin 標記）、`display`
  （替換顯示）。它是**非破壞性**的:不改 buffer 真實文字,只改「怎麼顯示」。
- **org folding 怎麼達成的**（next-steps 的問題）:org-mode 折一個 heading,就是在那段
  內容上加一個 `invisible` overlay（property `org`),並在 heading 行尾用
  `after-string` 顯示一個省略號 `…`/`▾`。展開 = 移除該 overlay。**完全沒動文字**,
  純 overlay 的隱藏 + 虛擬省略號。所以「做 folding」= 「先有能掛在 text buffer 區間、
  支援 `invisible` + `before/after-string` 的 overlay」。

**結論:現有 `view/overlays` 是「PDF 視覺疊加」版的 overlay;folding 需要的是「text
buffer 區間屬性」版的 overlay。本 doc 的核心工作是把 overlay 從前者擴張成後者
（尤其 `invisible` 與虛擬字串）,folding 只是它的第一個 client。**

## 目標（對齊 next-steps 大綱）

1. **emacs-like overlay（text-buffer 版）** —— 在 text-engine buffer 的字元區間上掛
   屬性:至少 `face`（變色,與 `text-display-design.md` 的 face 同表）、`invisible`
   （隱藏區間）、`before-string`/`after-string`（虛擬文字,不進真實 buffer）。
   非破壞性、buffer-local。
2. **org 式 folding** —— 用上面的 overlay 組出折疊:折 = 對區間加 `invisible` +
   heading 尾加省略號虛擬字串;展開 = 移除。支援階層（折 heading 連子樹）、
   `TAB`/`S-TAB` 循環（folded / children / subtree）。

## 設計取向（待定案，先記方向）

- **大腦在後端**:overlay 集合（區間 + 屬性）住在 Lisp,per-buffer。C++ 端的
  `QPlainTextEdit` 顯示層照後端的 overlay 算「哪些行隱藏、哪裡插虛擬字串、哪段變色」。
  對齊 LIMN-SPEC「overlays 純 frontend 渲染、後端控制」的既定哲學,但把作用域從
  「PDF 視埠座標」擴到「text buffer 字元區間」。
- **wire 形狀**:擴張既有 overlay 管線,加 text-buffer 區間型 overlay,例如
  `view/overlays {:buffer-id "b1" :overlays [{:range [beg end] :invisible t
  :after "…"} {:range [...] :face :comment}]}`。`face` 欄位與 `text-display-design.md`
  的 face 表共用 —— **一條 overlay 管線同時服務 folding、syntax 變色、margin 省略號**,
  不為 folding 另開 primitive。
- **`invisible` 的前端落點**:`QPlainTextEdit` 隱藏行 = 用 `QTextBlock::setVisible(false)`
  + document layout 重排;省略號用 block 的 `after-string` 等價（自繪或 inline widget）。
  這是本 doc 技術風險最高的一塊（Qt 的 block 隱藏 + 虛擬字串非原生,要驗證可行性）。
- **folding 純 Lisp 邏輯**:heading 偵測（org/markdown/縮排）、子樹範圍計算、循環狀態
  全在後端;前端只收「這些區間 invisible」。

## 開放問題

- `QPlainTextEdit` 對「隱藏部分 block + 插虛擬字串」支援到什麼程度?可能要換
  `QTextEdit` / 自繪,或用 `QTextBlockFormat` 的隱藏。**§1 先做可行性 spike**,
  結果決定整條路。（這是最大不確定性,先驗證再排後續。）
- folding 的範圍偵測:綁特定 major mode（org-mode / markdown-mode）還是通用縮排折疊?
  傾向:先做通用縮排 + heading regex,major mode 各自提供「怎麼算子樹」的 hook。
- overlay 與 linum（`text-display-design.md`）互動:折疊後行號顯示實際行 vs 可見行。
- overlay 與 undo:overlay 是非破壞性顯示,不該進文字 undo;但「展開/折疊」要不要可 undo?
- 效能:大 buffer 大量 overlay 的重排成本（與 cache 策略）。

## 分階段 sub-roadmap（planned）

- [ ] §1 **可行性 spike** —— 在 `QPlainTextEdit` 驗證「隱藏 block + 插虛擬省略號」可行,
      把結論（可行 / 要換 widget / 要自繪）寫進本 doc。**這步定生死,先做。**
- [ ] §2 text-buffer overlay 資料模型（Lisp,per-buffer,區間 + 屬性）+ wire 擴張。
- [ ] §3 `face` overlay 落地（與 text-display face 表共用,先讓「變色」能動）。
- [ ] §4 `invisible` + `before/after-string`（隱藏區間 + 虛擬省略號）。
- [ ] §5 org 式 folding:heading/子樹偵測 + 折/展 + `TAB`/`S-TAB` 循環。
- [ ] §6 階層折疊 + 與 linum 互動 + 鍵位收進 leader / evil `za`/`zo`/`zc`。

## 驗證

- **headless 可測**:overlay 資料模型（加/移/查區間）、folding 的子樹範圍計算、循環狀態、
  「哪些行該 invisible」的純邏輯 —— 全寫 unit test。
- **真機目視**:折疊真的把內容收起來、省略號顯示、`TAB` 循環 —— 走 walkthrough
  （CLAUDE.md §6）。folding 的「看起來收好了沒」headless 測不到,必目視。

## 關聯

- `text-display-design.md` —— face 表共用同一條 overlay `:face` 管線。
- `evil-mode-design.md` —— folding 鍵位 `za`/`zo`/`zc`/`zR`/`zM`。
- `LIMN-SPEC.org` §12 / v0.14（`view/overlays` paintGL）—— overlay primitive 的權威現況
  （PDF 視覺版,本 doc 把它擴到 text-buffer 區間版）。
