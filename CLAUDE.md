# CLAUDE.md — 每個 session 開工前先讀

這是給 **agent** 的入口（會自動載入 context）。只放「打字前必須知道的
house rules」+ 指路；細節在各權威文檔裡，**別在這裡重複**。

## 0. 最高優先

- **語言**：所有 user-facing 文字（文檔、給使用者看的註解、commit / PR
  訊息）一律用**繁體中文**；程式識別符／路徑／函式／變數／env var 名稱
  維持英文。
- **在你自己的 worktree 裡工作，不要 `cd` 進主 repo（`…/sioyek-core`）改
  main。** 每個 session 有自己的 git worktree，改動留在分支上。
- **只在使用者明確要求時才 commit / push / 打 tag。** 不擅自 push、不做
  破壞性 git 操作、不刪 branch/worktree。

## 1. 版本與發布 → `docs/versioning-policy.md`

版本號是「merge 進 main 那一刻由整合者發放」的中央資源。所以在分支上：

- **分支名 / 檔名 / 測試名都不帶版本號**，用功能名（`feat/notes-panel`，
  不是 `feat/v0.42`）。
- **不要自己 `git tag`、不要自封 `v0.NN`。**
- changelog 不要去編 `CHANGELOG.org`；在 `changelog.d/<slug>.org` 丟一個
  **自己獨有檔名**的 fragment（見 `changelog.d/README.org`）。
- 版本號／CHANGELOG 收攏／tag 都在 merge 時由整合者一次做完。

## 2. 怎麼追蹤 feature → `docs/ROADMAP.org`

- **全 feature 總索引** = `docs/ROADMAP.org`（先看這裡知道全局）。
  ⚠️ 它是 **integrator-only**：只在 merge 時由整合者更新，**你在分支上
  不要動它**。
- **單一 feature 的 roadmap / 進度** = 它自己的 `docs/<slug>-design.md`
  （範本：`docs/split-frame-design.md`，含分階段 + `[x]/[ ]` checklist）。
  你的進度更新寫在這裡。
- agent 的 session task list 只是**草稿**——不跨 session、不是 keep-track
  工具，別當權威。

## 3. Git 紀律 → `CONTRIBUTING.org`

一 commit = 一 logical unit、能 build、測試綠；`--no-ff` merge 不 squash。
（注意：CONTRIBUTING.org §1.2 的「branch 名帶版本號 + 自己打 tag」範例
已被 `docs/versioning-policy.md` 取代——以政策檔為準。）

## 4. 文件地圖

| 想知道 | 看哪 |
|---|---|
| 線協議 / 指令 / 事件 / Lisp runtime 深水區 roadmap | `LIMN-SPEC.org`（§12 = roadmap） |
| 全 feature 索引 + 各自狀態 | `docs/ROADMAP.org` |
| 某 feature 的細部設計 + 進度 | `docs/<slug>-design.md` |
| 版本制度 / changelog / feature 追蹤規範 | `docs/versioning-policy.md` |
| 已 ship 的 release 紀錄 | `CHANGELOG.org` + `git tag` |
| 跨 sprint 的結構性債 / 難修項 | `ISSUES.md` |
| 測試覆蓋缺口 | `TEST-COVERAGE-TODO.org` |
| 設計哲學 | `philosophy.org` |

## 5. build / test

- Lisp unit：`ulimit -n 8192 && nix develop --command sbcl --script backend/tests/unit/run-unit.lisp`
  （目前 baseline：5 個既有 failure，別把它當成你弄壞的）。
- 每個階段做完：build + 至少啟動一次 binary。headless 測不到 GUI split。
