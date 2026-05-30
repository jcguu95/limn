# annotation-store-design.md

標記 / 筆記的**資料模型、物件系統、持久化** —— 設計與分階段計畫。
狀態:⏭ planned（2026-05-30 開檔）。

next-steps 把它列在 highlighting / note 底下:**db design? / sioyek-like highlighting? /
note + icon 顯示在哪 / annotate on highlighting? / we need a sane object system。**

注意分工:`markup-interaction-design.md` 管的是**視覺語言與互動 UX**（色塊改底線、清單
buffer、in-page focus ring、margin icon）。**本 doc 管底下那層 —— 標記到底是什麼物件、
怎麼存、schema 怎麼演進。** 兩份是同一功能的「外觀」與「骨架」，互相引用、不重疊。

## 背景 —— 現況盤點（已 ship 的物件模型）

權威在 `backend/limn-pdf-mode.lisp` §C（annotation — struct + sidecar I/O + content-hash
key + schema）。已存在:

- **`pdf-annotation` struct（schema v2）**:`id`（uuid）、`page`（int）、
  `rects`（list of `(x0 y0 x1 y1)`，頁內 0..1 正規化）、`color`、`note`、`created-at`、
  `type`（`:highlight` | `:note` | `:both`）、`tags`（list of string）。
- **持久化 = sidecar**（**不是 DB**）:每份 PDF 一個 sidecar；`pdf-annotations-sidecar-path` /
  `-content-hash-sidecar-path`（用內容雜湊當 key，檔案移動/改名也能對上）。
  `pdf-annotations-save` / `-load`、atomic write、in-memory cache
  （`*pdf-annotations-cache*`，path → `{by-page, all}`，消滅每次滑鼠事件重讀 sidecar）。
- **schema 演進機制已就緒**:`*pdf-annotations-schema-version* = 2`，
  reader 接受 v1（缺欄位 default）、writer 永遠寫 v2、有 v1→v2 migration。
- **type 已預留 note**:`:note`（point note，無文字選取）、`:both`（highlight 上加 note）
  —— 對應 next-steps 的「note + icon」「annotate on highlighting」。
- **defcustom 色**:`*pdf-annotation-color*`（預設 `#FFD700`）。

**結論:物件系統的 v2 骨架已經相當完整（id / page / rects / color / note / type / tags +
versioned schema + migration）。本批是 (a) 決定要不要從 sidecar 升到 DB、(b) 把 `:note`/
`:both`/`:tags` 這些已預留欄位真的接出 UX、(c) 把物件模型補成「sane」—— 關係、查詢、icon。**

## 目標（對齊 next-steps 大綱）

1. **db design?** —— 決策題:維持 sidecar（plist 檔）還是升 sqlite（sioyek 已有 `local.db`/
   `shared.db`）?定一條清楚的判準與遷移路徑（見決策章節）。
2. **sioyek-like highlighting** —— 對齊 sioyek 的選字→highlight 體感與資料形狀
   （多 rect 跨行、顏色分類）。現有 `rects` 已是 list，可承多行。
3. **note + icon 顯示在哪** —— `:note`/`:both` 的標記在頁邊 gutter 畫 icon（與
   markup-interaction Layer 3 / icon-overlay 同源），點 icon 開 note。
4. **annotate on highlighting** —— 在既有 highlight 上加 note（`type :highlight` → `:both`），
   不必重選字。物件層:同一個 `pdf-annotation` 升級 type + 填 `note`。
5. **a sane object system** —— 把標記物件補成有清楚 identity / 關係 / 查詢的模型:
   穩定 id、page index、tag 關係、type 多型、未來可擴張（ink / stamp / link）。

## 設計取向（待定案，先記方向）

- **大腦在後端**:標記物件、schema、持久化全在 Lisp。C++ 只負責 (a) 給選字的頁座標
  rect、(b) 照後端的 rect/color 畫 overlay、(c) 畫 margin icon。沿用現有分工。
- **sidecar vs DB —— 傾向「先補強 sidecar，DB 當可選後端」**:
  - sidecar 的好處:純文字可 diff / git 友善 / 跟著檔案走 / 零 schema migration 痛苦，
    與 limn「人類可讀的 source of truth」哲學一致。
  - DB 的好處:跨文件查詢（「所有 tag=todo 的標記」）、大量標記的索引、與 Bookmark
    Everywhere / view register 共用 store。
  - **方案**:物件模型與序列化解耦於儲存後端（`*annotations-write-fn*`/`-read-fn*` 已是
    可注入的 indirection）。預設仍 sidecar;另加一個**可選 sqlite 索引**做跨文件查詢
    （sidecar 是真相，DB 是衍生索引，可重建）。避免「DB 變成第二份真相」的分歧債。
- **page index**:cache 已有 `by-page`;物件層補一個明確的 page → annotations 索引，
  讓 in-page hit-test（markup Layer 2）與 margin gutter（Layer 3）都走它。
- **icon overlay**:note/both 的 margin icon 走 `view/overlays` 的 `text`/`image` type
  （LIMN-SPEC §12 icon-overlay / PR4），不另開 primitive。

## 開放問題

- sidecar 真相 + DB 索引的**同步策略**:何時 rebuild 索引?開檔時掃所有 sidecar 太慢?
  傾向 lazy + 標記變更時增量更新。
- `id` 的穩定性:目前 uuid = `now + counter`，跨 session 唯一但不可重現。要不要改成
  content-addressed（page+rects 雜湊）以便去重 / 合併兩台機器的 sidecar?
- type 擴張到哪:`:highlight`/`:note`/`:both` 之外要不要 `:ink`/`:stamp`/`:link`?
  物件系統要能加 type 而不破 schema（v2→v3 migration 已有範式）。
- 與 **PDF 原生 annotation** 的關係:目前只 show/hide（markup 丁），不匯入 sidecar。
  「sane object system」要不要把原生 annotation 也納為一種唯讀 type?（傾向:暫不，
  避免雙向同步地獄;維持 markup 丁的 show/hide 邊界。）
- tags 是平面字串還是有階層 / 顏色?與 face/color 管理（`text-display-design.md`）的關聯。

## 分階段 sub-roadmap（planned）

- [ ] §1 決策:sidecar vs DB —— 寫一頁判準 + 選定（傾向 sidecar 真相 + 可選 sqlite 索引）。
- [ ] §2 page index 明確化（物件層的 page → annotations，統一給 hit-test / gutter 用）。
- [ ] §3 `annotate on highlighting` —— 既有 highlight 升 `:both` + 填 note（不重選字）。
- [ ] §4 note + margin icon（`:note`/`:both` 在 gutter 畫 icon，點開 note；接 icon-overlay）。
- [ ] §5 sane object system 收尾:穩定 id 策略、type 多型擴張範式（v2→v3 migration 範本）。
- [ ] §6（可選）sqlite 衍生索引 + 跨文件查詢（「所有 tag=X」），與 Bookmark store 合流。
- [ ] §7 鍵位收進 `SPC m`（markup，leader）。

## 驗證

- **headless 可測（物件層全部）**:struct round-trip（serialize→parse 等價）、v1→v2(→v3)
  migration、page index 正確性、hit-test、tag 篩選、`:highlight`→`:both` 升級 —— 全寫
  unit test（這層完全不靠眼睛，是純資料，最該被測爆）。
- **真機目視**:highlight 視覺、margin icon 位置、點 icon 開 note —— 走 walkthrough
  （CLAUDE.md §6），與 markup-interaction 的視覺驗證合併跑。

## 關聯

- `markup-interaction-design.md` —— 同一功能的視覺/UX 層（色塊、清單、focus ring、gutter）。
- `save-view-design.md` / `split-frame-design.md`（Bookmark Everywhere）—— 可選 sqlite
  索引若落地，與書籤 / view register 共用 store。
- `text-display-design.md` —— tags / 顏色分類與 face/color 管理的關聯。
- `LIMN-SPEC.org` §12（icon-overlay / view/overlays）—— margin icon 的 primitive。
