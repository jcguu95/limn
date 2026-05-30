# 版本編號規範（草案 — 待審）

> 狀態：**已採行（pending jcguu95 最終追認）**。2026-05-29 決議：採
> **SemVer 風 + merge 時發號**（§3.5 CalVer 為未採用之備案）。地基
> （`VERSION` / `changelog.d/` / 收攏腳本 / 第一個權威 tag）依本檔建立。
> 本檔說明「為什麼舊做法會壞」與「新制怎麼運作」。

## 1. 問題：整數版本號被平行分支各自分配

這個 repo 同時有數十個 Claude agent 在各自的 git worktree 工作，
每條分支都從相近的 `main` base 長出來。舊做法是**每條分支自己猜一個
全域遞增版本號 `v0.NN`**。結果必然崩潰：

- **撞號**：掃過所有 branch tip 的 subject —— **8 條分支同時自稱
  `v0.37`**、3 條 `v0.39`、3 條 `v0.28`…。一個「全域唯一的計數器」被
  「幾十個互不通訊的分支」各自分配，撞號是數學上的必然。
- **時序倒掛**：`v0.38 / v0.39` 衝刺（commit `caf40e9`）在 **2026-05-26**
  就 merge 進 main；但 bookmark / logging 兩批是 **2026-05-29** 才 ship，
  卻標 `v0.37`。號碼比實際 ship 時間早、看起來最舊，其實最新。
- **CHANGELOG 衝突**：兩條分支都去編輯共用的 `* v0.37.0` 段落 →
  merge 時硬衝突，要人工手解（2026-05-29 就發生過一次）。
- **改名苦工**：版本號被塞進**檔名／符號／測試名**（`bookmark-v037.lisp`、
  `logging-v037`…）。一旦版本標錯，要改名就得連動 `.asd`／`run-unit.lisp`
  等所有引用，否則 build 直接壞。

根因一句話：**版本號是中央資源，卻被去中央化地分配。**

## 2. 原則

1. **單一真相來源**：已發佈版本只有一個權威紀錄。
2. **版本號在「整合（merge 進 main）」那一刻才分配**，由單一權威蓋章，
   永不在 feature 分支上自封。
3. **分支與程式碼產物與版本無關**：用功能名，不用版本號命名。
4. **CHANGELOG 貢獻零衝突**：每條分支丟自己的 fragment，不碰共用段落。

關鍵洞見：在 agent 群裡，「單一權威」就是 **merge-into-main 這個動作本身**
—— 它天生序列化（一次只落一個 merge）。**那個序列化點，正是發號的地方。**

## 3. 機制

### 3.1 真相來源：git annotated tag（+ 選配 `VERSION` 檔）

- 已發佈版本的權威紀錄 = **annotated git tag** `vX.Y.Z`（不可變、帶日期、
  可簽章）。
- 「目前 / 下一版」用 `git describe --tags` 推算，**不靠人腦記**。
- 選配：release 時把號碼同步寫進 repo 根的 `VERSION` 檔，給人類與 build
  讀（`limn_build_info` 可選擇 bake 進 binary）。

### 3.2 發號在 merge 時

整合一條 feature 進 main 的步驟：

1. 從最新 tag（或 `VERSION`）算出下一號。
2. 收攏該批的 changelog fragment 成一個 `* vX.Y.Z` 段落。
3. 在 merge commit 上打 annotated tag `vX.Y.Z`。

因為只有這一個整合步驟在發號，號碼**必定單調遞增 = 依 merge 順序 =
依時間**。兩條 feature 不可能拿到同一號。

### 3.3 分支與檔名與版本脫鉤

- 分支名：`feat/bookmark-everywhere`、`fix/mo-macos-keys` —— 描述工作，
  **不寫 `v0.NN`**。
- 原始碼／測試檔名：`limn-bookmark.lisp`、`bookmark-tests.lisp`
  （拿掉 `-v037`）。版本是 metadata，不是 identifier。
- 測試套件名／符號：用功能名。
- 內文的 `v0.37 §X` 工作標籤：改用穩定的功能名或 issue 編號。

這樣**根本沒有「改名 + 同步引用」的苦工** —— 名字裡從來不帶版本。

### 3.4 CHANGELOG fragment（towncrier-lite）

- 每條分支新增 `changelog.d/<slug>.org`（例：`changelog.d/bookmark-everywhere.org`），
  寫自己那段的內文。
- release 時一支小腳本把所有 fragment 收攏到新的 `* vX.Y.Z` 標題下
  （排序）、刪掉 fragment。
- 每條分支只碰**自己獨有檔名**的檔 → **永遠不會有共用段落的 merge 衝突**
  （正是 2026-05-29 手解的那種衝突的根治）。

### 3.5 選配：CalVer

dogfood 衝刺本來就日期驅動。若連 merge-時發號都嫌煩，可改 `vYYYY.MM.DD`
或 `vYYYY.N` —— merge 日期天生唯一、天生單調，連發號都免。代價：失去
「改動多大」的語意訊號。預設仍建議 SemVer 風 `v0.Y`（merge 時發號），
CalVer 當備案。

### 3.6 roadmap 怎麼寫（前瞻計劃 vs 版本號）

寫「未來要做什麼」的路線圖時，**不要用版本號當標題／計劃標籤**。理由與
§1 一模一樣：提前把 `v0.NN` 釘在「還沒做、還沒 merge」的工作上，就是
撞號／時序倒掛的根源——多條分支平行推進時，那個號碼必然對不上實際
merge 順序。

分清楚兩條軸：

| | roadmap（計劃） | version（版本號） |
|---|---|---|
| 回答 | 要做什麼、為什麼、先後 | 哪一次 merge ship 的 |
| 方向 | 前瞻 | 回溯 |
| 標籤 | **功能名 / 里程碑名 / Phase / epic** | `vX.Y.Z`，**merge 時才發** |

規則：

1. **未來（未 merge）項目**用功能名當標題，不帶號碼。例：
   `*** notes-panel 收編（Phase 3c） ⏭ planned`。
2. **已 ship 項目**保留它實際被分配到的號碼（歷史事實、有用）。例：
   `*** v0.7 Mode + Chrome primitives ✅ shipped`。
3. 一個項目 ship 的**那一刻**，整合者把標題從「功能名 ⏭ planned」改成
   「`vX.Y.Z` 功能名 ✅ shipped」——號碼在此時、而非提前落定。
4. 要表達先後／分組又不想用號碼，用 **Phase / epic 名**（如 Phase
   3a/3b/3c）；它穩定、跟版本號脫鉤。

> 既有 roadmap（`LIMN-SPEC.org` §12）裡那些 `v0.NN ⏭ planned` 標題，是
> 制度生效前的產物。它們的號碼被內文大量交叉引用，硬拔會製造數百個斷裂
> 引用，故**不回頭翻修**（對齊 §4「不改寫歷史」）；只在 §12 開頭聲明
> 「未 ship 項目的號碼是非權威佔位標籤」。**新項目一律照本節寫。**

## 4. 既有狀態怎麼遷移

- **不回頭改寫歷史版本標號**（既 revisionist 又巨大 churn）。已 ship 的
  歷史原樣保留。
- **新制從下一次 merge 開始套用**。
- 已 merge 的 bookmark / logging 兩批：
  - 它們的 `v0.37` 標號屬於「制度生效前」的產物，**不視為權威**。
  - 最小修正：把 main 的 CHANGELOG 頂端更正成符合事實（它們其實是
    v0.39 之後最新的工作），並在當前 main 狀態打第一個權威 tag，作為
    新制的起點。是否連檔名一起正規化，另案決定（churn 大、非必要）。

## 5. 待辦（本草案通過後）

- [ ] 在 repo 根建立 `VERSION` 與 `changelog.d/`（含 README + 收攏腳本）。
- [ ] 對「制度生效起點」的 main commit 打第一個 annotated tag。
- [ ] 更新 agent 工作指引：分支不自帶版本號、改丟 changelog fragment。
- [ ] （另案）既有 `*-v037.*` 檔名是否正規化。
