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
- **新 interactive 指令的預設綁定走 Doom =SPC= leader 樹**（不是只給
  =C-x=/=C-c=）。詳見 §7。
- **【依賴單一版本鐵律】** macOS host 上的**人 / Claude**，與 Linux 容器裡的
  **DeepSeek**，三方測試與跑動所用的**所有依賴**，一律經 `nix develop` 鎖在
  **同一個 `flake.lock`**（單一真相，platform 不同但版本相同）。host 每次
  `nix develop` 讀現場 lock、永不過期；唯一會 drift 的是 OpenHands runtime
  image 烤進去的那份 lock。**一旦 image 的 lock ≠ repo 的 lock，就是鐵律被
  打破** → `bash openhands/check-lock-sync.sh` 會印巨大警報、`meta/openhands/run.sh`
  會**拒絕啟動 DeepSeek**。改動 `flake.lock`（含 `nix flake update` / 升任何
  依賴）後，**必須**重跑 `bash openhands/build-runtime.sh` 讓容器吃到新 lock，
  否則 DeepSeek 的測試結論不可信。細節見 `meta/openhands/README.md`。

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

## 6. 前端互動驗證 → walkthrough script（**做完一個 feature 一定要給**）

unit/integration test 測不到「畫面有沒有渲染對」。那一段靠使用者的眼睛，
但**使用者的眼睛要被你領著走**。所以每個碰到前端的 feature，收尾時要附一支
**互動 walkthrough script**，讓使用者一步一步跑、一眼一眼比對。

範本：`scratch/narrow-walkthrough.lisp`、`scratch/bookmark-walkthrough.lisp`。
鐵則：

- 放在 `scratch/<feature>-walkthrough.lisp`，**繁體中文**寫。
- **所有路徑寫絕對路徑**（`/Users/jin/data/local/projects/sioyek-core/…` 或
  `/tmp/…`），讓使用者複製貼上就能跑，不用猜 cwd。
- 開頭註解就寫清楚**怎麼啟動**：`export LIMN_BIN=…`、`HEADLESS=0
  backend/run-repl.sh`、然後 `(load "<絕對路徑>/scratch/<feature>-walkthrough.lisp")`。
- 每一步三件事：①注入 form ②印出「**預期看到什麼**」③問 `y/n/c/a`
  （y=一致 n=不一致 c=不一致+留一行 comment a=中止）。
- 結束印出每步摘要（通過/失敗、comment、原始 form），失敗的那步 form 要能
  直接複製回去重跑。

這是目前**人機之間驗證前端最省力的介面**——agent 出腳本與「預期」，人只出眼睛。

## 7. 鍵位慣例：預設 Doom =SPC= leader → `docs/leader-keys-design.md`

limn 的**預設**鍵位是 Doom-Emacs 風：**evil 模態 + namespaced =SPC= leader**
（配 which-key 可探索）。normal state 下 =SPC= 是 leader、insert state 下
=SPC= 打空白、leader 退到 =M-SPC=。純 Emacs 使用者用 config 開關退回經典
非模態 =C-x=/=C-c= 自綁。對 agent 這是**強制慣例**：

- **新增任何 interactive 指令時，要在 =SPC= leader 樹下給它一個合理 namespace
  的綁定**（例：window→=SPC w=、buffer→=SPC b=、search→=SPC s=、narrow→
  =SPC n=…），並更新 which-key 標籤。
- **不要只給 =C-x=/=C-c= 就當做完。** 經典 Emacs 綁定可以保留為並存層（給肌肉
  記憶 / 關掉 leader 的人），但**不是新功能的預設路徑**。
- namespace 字母盡量對齊 Doom，降低既有 Doom 使用者的學習成本。
- 完整 namespace 表、模態張力（可編輯 buffer 的 =SPC= vs =M-SPC=）、opt-out
  設計都在 `docs/leader-keys-design.md`。
