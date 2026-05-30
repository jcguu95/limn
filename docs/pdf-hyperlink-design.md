# pdf-hyperlink-design.md

PDF 超連結 —— 設計與分階段計畫。狀態:⏭ planned（2026-05-29 開檔）。

讓 PDF 裡的連結可被偵測、顯示、點擊跳轉。分兩種:

- **internal（文件內跳轉）**:目錄、交叉引用、`#page=N` 之類的 GoTo —— 點了
  在**同一份**文件內跳到目標頁/位置。
- **external（外部）**:`http(s)://` URL、`mailto:`、或指向另一個檔案的連結
  —— 點了用 OS 預設行為開啟（瀏覽器 / mail client / 另開 PDF buffer）。

## 為什麼大半零件已存在

- **MuPDF 原生就解析 link**:`fz_load_links` 回傳每頁的 link 矩形 +
  目標（`fz_link` 的 `uri` / dest）。internal vs external 由 uri 形態判斷
  （`#...` / page dest = internal;`http`、`mailto`、外部路徑 = external）。
  所以「有哪些連結、在哪、指去哪」**不必自己算**,問 MuPDF 即可。
- **頁面座標 ↔ widget 座標**的換算已存在（`widget_to_page_norm` 等,見
  split-frame-design.md 的稽核表),命中測試可複用。
- **internal 跳轉**就是「設 focused window 的 page/offset/zoom」——跟
  bookmark-jump / win-focst 還原視角同一套機制。

## 設計取向(待定案)

- **大腦在後端**:link 的「語意」（這塊矩形點下去要做什麼）由後端決定。前端
  回報「在頁面 (x,y) 被點」,後端查 link 表、決定 internal-goto 還是
  external-open,再送回對應指令。
  - 替代案:前端自己解析 + 直接跳（沿用 sioyek 既有行為）。但那違反「大腦在
    後端」原則,且 external-open 的策略（要不要確認、開哪）該由 Lisp 管。
    傾向**後端決策**,前端只做命中回報 + 渲染 + 實際 open。
- **wire 介面草案**:
  - `view/links-get {win, page}` → 後端拿到該頁 link 矩形 + 目標,可畫提示。
  - 點擊:前端 `view/click {win, page, x, y}` → 後端比中 link → 回
    `internal`（送 page/offset 還原）或 `external`（送 `os/open uri`）。
- **顯示**:link 矩形可選擇性高亮（hover 換游標、或常駐淡框）。沿用 overlay
  raster（Phase 4 之後就是 per-DV）。
- **external open**:走一個受控的 `os/open`（macOS `open`、Linux `xdg-open`),
  對 `http`/`mailto` 白名單,避免任意檔案被亂開。

## 與其他 feature 的交集

- **internal 跳轉 ⇄ window split**:internal link 可「在本 pane 跳」或「在新
  split 開目標」——等 split（Phase 3）穩了天然組合。
- **external 開檔 ⇄ buffer 模型**:external 若指向另一個 PDF,可當「開成新
  buffer」而非交給 OS,對齊 ibuffer / find-file 的 buffer-everywhere 觀。

## 分階段 sub-roadmap(planned)

- [ ] §1 前端 `fz_load_links` 接出每頁 link 矩形 + uri/dest,回報後端
- [ ] §2 後端 link 表 + internal/external 分類邏輯
- [ ] §3 命中測試:點擊 → 比中 link（複用 widget↔page 換算）
- [ ] §4 internal goto:還原 page/offset/zoom(複用 win-focus/bookmark 機制)
- [ ] §5 external open:受控 `os/open`(URL/mailto 白名單)
- [ ] §6 link 視覺提示(hover 游標 / 淡框,走 overlay)
- [ ] §7 鍵盤可達:無滑鼠時的 link-hint（對齊 avy/link-hint 風,選配）
- [ ] §8 walkthrough 視覺驗證(CLAUDE.md §6)

## 開放問題

- internal dest 的精度:只跳頁,還是連 named-destination 的精確 y/zoom?
- external PDF:交 OS 還是開成新 buffer?(傾向新 buffer,但需確認)
- link-hint 鍵盤導航要不要納入第一版（vs 純滑鼠先上）。

## 驗證

- internal 跳轉、link 表解析可 headless 斷言（給定 PDF,某頁某矩形 → 目標頁）。
- hover 提示 / 點擊體感屬視覺,走 walkthrough。
