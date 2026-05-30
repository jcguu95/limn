# completion-ui-design.md

現代補全 / 選取 UI —— minad（Daniel Mendler）整套生態的 limn 等價層。
設計與分階段計畫。狀態:⏭ planned（2026-05-29 開檔）。

**優先序（user 定）:** 整套都要,但**第一優先、其餘可先放著**的是一個
**Fuzzy Selector**（= Vertico + Orderless 等價：垂直、即時、模糊比對的
minibuffer 選單）。其他 minad libs 先記在這裡、標 deferred。

## minad 整套生態（目標全集）

| 上游 lib | 做什麼 | limn 優先序 |
|----------|--------|-------------|
| **Vertico** | 垂直、即時的 minibuffer 補全 UI | **P1（先做）** |
| **Orderless** | 補全樣式:空白分隔的詞各自任意順序比對（=模糊） | **P1（先做）** |
| **Consult** | 一堆基於 completing-read 的實用命令（consult-line / -buffer / -grep / -imenu…） | P2 |
| **Marginalia** | minibuffer 候選旁的註解（檔案大小、docstring…） | P2 |
| **Corfu** | buffer 內 completion-at-point 的彈出 popup（Vertico 的 in-buffer 版） | P3 |
| **Cape** | Corfu 的 completion-at-point 後端們 | P3 |
| **Embark** | 對候選 / point 上的東西做情境動作（act / become） | P3 |
| **Tempel** | 模板（TempEl） | P4 |

> P1 = 本批要落地的 Fuzzy Selector;P2–P4 = deferred,等 P1 站穩 + 有需要再開。

## P1 —— Fuzzy Selector（Vertico + Orderless 等價）

### 目標

把現有的 `completing-read`（v0.25 已有）從「一行式 + TAB 補全」升級成**垂直、
即時過濾、模糊比對**的選單:

- **Vertico 面**:候選垂直列出(N 行)、隨輸入即時收斂、上下選、RET 確認、
  顯示「第 i / 共 m」。
- **Orderless 面**:輸入 `foo bar` = 候選需同時含 `foo` 與 `bar`（任意順序、
  各自 substring/fuzzy）。比 prefix-only 補全好用得多。

### 既有零件（大半已存在,別重造）

- **`completing-read` / minibuffer**:v0.25 completion + `minibuffer-read` 已有
  選候選的後端骨架;Fuzzy Selector 是換**前端呈現 + 比對策略**,不是從零做。
- **which-key**（v0.28）:已能在 minibuffer 區塊即時畫一張清單 → 垂直候選的
  渲染管線可借鏡 / 共用。
- **fuzzy 比對**:repo 已 vendored **fzf**（`sioyek/fzf`,~1.4K LOC C 模糊比對,
  見 `.gitignore` 註解）。先評估「直接接 fzf 當比對引擎」vs「在 Lisp 寫
  orderless 比對」。task-A search-upgrade 也已做過 narrow/fuzzy,可複用。
- **大腦在後端**:選單狀態（候選、查詢、選中 index）住 Lisp;前端只照後端推的
  內容把 N 行畫進 minibuffer 區、回報按鍵。沿用既有 wire。

### 與其他 feature 的交集

- **leader-keys / evil**:`SPC` 樹的每個葉子幾乎都會叫出一個 completing-read
  選單（switch-buffer、find-file…）→ Fuzzy Selector 是 leader UX 的放大器。
- **ibuffer / switch-to-buffer / bookmark**:全部走 completing-read → 一次升級、
  全面受益。

### 分階段 sub-roadmap（P1）

- [ ] §1 決策：模糊比對引擎走 vendored fzf 還是純 Lisp orderless（先各跑一小段）
- [ ] §2 後端 selector 狀態：候選集 + 查詢 + 過濾（orderless 任意順序比對）+ 選中 index
- [ ] §3 前端垂直渲染：N 行候選進 minibuffer 區、選中高亮、「i/m」計數（借 which-key 管線）
- [ ] §4 鍵位：上下選 / RET / `C-g`、即時 incremental 過濾
- [ ] §5 接管既有 completing-read 呼叫點（switch-buffer、find-file、ibuffer、bookmark…）
- [ ] §6 `*enable-fuzzy-selector*` 開關 + walkthrough 視覺驗證（CLAUDE.md §6）

## P2–P4（deferred,先記不做）

- **Consult 等價**:`consult-line`（buffer 內跳行）、`consult-buffer`、
  `consult-grep/ripgrep`、`consult-imenu`。建在 P1 selector 之上。
- **Marginalia 等價**:候選旁註解（檔案大小 / docstring / buffer mode）。
- **Corfu + Cape 等價**:buffer 內 completion-at-point popup（in-buffer 版）。
- **Embark 等價**:對候選做情境動作（在選單裡對某 buffer 直接 kill/rename…）。
- **Tempel 等價**:模板補全。

> 這些不展開 sub-roadmap,等 P1 完成後各自再開（或併進本 doc 補章節）。

## 驗證

- 比對 / 過濾 / 選中邏輯可 headless 斷言（給候選集 + 查詢 → 預期排序/命中）。
- 垂直選單的視覺、incremental 體感走 walkthrough（CLAUDE.md §6）。
