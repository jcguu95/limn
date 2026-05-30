# meta/openhands/ —— 路 1：用 OpenHands + DeepSeek 開發 limn（直接互動）

> 這是 `meta/`（開發 meta-level 工具）底下的**路 1**。路 2（Claude 當介面的
> thin loop）在 `meta/loop/`。兩條路共用同一個 runtime image 與依賴鎖，
> 總說明見 `meta/README.md`。

這個資料夾把「DeepSeek 自主 agent 開發 limn」這套 harness 收在一起。靈感來自
`~/data/local/projects/deepseek-container/`（那邊在做別的實驗，本 repo 自帶一份
專為 limn 調過的），但**這份直接住在 limn repo 裡、用同一個 flake**,所以 agent
拿到的工具鏈跟我們 CI 的 `limn-e2e`（根目錄 `Dockerfile`）完全同源。

## 已驗證狀態（2026-05-30，runtime image build 完整跑過）

runtime image（`limn-openhands-runtime:0.57.2`）已逐項驗證可用：

- ✅ **build 通過**：FROM nikolaik + Determinate nix installer + materialize
  `flake#docker` closure（約 150s，closure 烤進 image）。
- ✅ **工具鏈齊**：`nix` 上 PATH（Determinate Nix 3.21.0）、`nix develop
  /limn#docker` 進得去、qmake/Qt 6.11.0、SBCL 2.6.3、e2e 四件套
  （Xvfb / xdotool / x11vnc / fcitx5 都是真 nix store 路徑）。
- ✅ **C++ 前端可編**：容器內 copy source → `qmake && make -j` 連結出 `limn`
  binary（56MB），`limn --version` 印得出 build banner。
- ✅ **unit 套件可跑**：掛 repo + `nix develop /limn#docker --command sbcl
  --script backend/tests/unit/run-unit.lisp`。

### 容器內 unit baseline（agent 請記住「乾淨」= 這個數字）

| 環境 | 結果 |
|---|---|
| host（macOS） | 2955 passed / **5** failed |
| **本 runtime（Linux 容器）** | 2949 passed / **10** failed |

容器多出的失敗**不是**這套 harness 的 bug，分三類：

- **4× V027 search** —— host 與容器**都** fail，是既有 known-broken，與環境無關。
- **3× PROCESS-A（signal status）+ 3× PROCESS-CODING（utf-8 子行程解碼）** ——
  **容器限定**，是 Linux vs macOS 的 signal 語意 / subprocess pipe 解碼平台差異，
  全落在 `limn/process` 子系統，**與 next-steps 要做的（search / save-view /
  annotation / text-display / folding）完全不相干** —— 那些子系統的測試在容器裡全綠。
- host 的 `INIT-LOAD-…` 在容器內反而 pass（host 有 init 檔、容器沒有）。

**給 agent 的規則**：在這容器裡，unit 套件的乾淨基準是 **2949 passed / 10 failed**，
且那 10 個就是上面列的。你的改動若讓**這 10 個以外**的任何測試變紅，那才是你引入的退化。

## 依賴單一版本鐵律（CLAUDE.md §0）

**macOS host 上的人 / Claude，與 Linux 容器裡的 DeepSeek，三方測試與跑動所用的
所有依賴，必須鎖在同一個 `flake.lock`。** platform 不同（aarch64-darwin vs
linux），但**版本**由同一個 nixpkgs pin 鎖死 —— 同 sbcl 2.6.3、同 Qt 6.11.0、
同 mupdf…。在不同依賴版本上做的驗證，結論不可信。

機制：

- **host 端永不過期** —— 人 / Claude 每次 `nix develop` 都讀 repo 現場的
  `flake.lock`，自動跟 repo 一致。
- **唯一會 drift 的是容器** —— OpenHands runtime image 把 `flake.lock` **烤進**
  `/limn/flake.lock`（build 當下的快照）。repo 的 lock 之後改了、image 沒重 build，
  就 drift 了。
- **守門員** `check-lock-sync.sh` —— 比對 repo 的 `flake.lock` sha256 vs image 內
  烤進去的那份。一致印 `✅`、不一致印**巨大警報 + exit 1**。
- **強制執行點** —— `run.sh` 啟動前先跑守門員，**不一致就拒絕啟動 DeepSeek**。
  所以你不可能在版本漂掉的情況下開工。

```bash
bash meta/openhands/check-lock-sync.sh      # 手動檢查；run.sh 會自動先跑
```

**改動 `flake.lock` 後（含 `nix flake update` / 升任何依賴）必須重 build：**

```bash
bash meta/openhands/build-runtime.sh        # 讓容器吃到新 lock，重新對齊三方
```

image 也烤了 `limn.flake_lock_sha256` / `limn.nixpkgs_rev` 兩個 label，
`docker inspect` 可一眼看出它鎖的是哪個 lock（真相仍是 image 內的檔，label 只是
給人看的快照）。

## 為什麼這樣擺（架構）

OpenHands 有兩個 container,職責分開：

| container | image | 角色 |
|---|---|---|
| **app**（web UI @ `:3000`） | `ghcr.io/all-hands-ai/openhands:0.57.2` | 編排、跟 LLM 對話、顯示介面 |
| **runtime / sandbox** | `limn-openhands-runtime:0.57.2`（本資料夾 build） | **agent 真正執行指令的地方** |

關鍵:agent 的 build / 跑測試 **都在 runtime image 裡**。所以要讓 DeepSeek 能編
limn（Qt6 + MuPDF + SBCL）並跑 headless e2e,runtime image 就得有 limn 的整套工具。

### runtime image 的方向（決策記錄）

`Dockerfile.runtime` 走 **FROM nikolaik + 裝 nix**（順向）:

- **FROM `ghcr.io/all-hands-ai/runtime:0.57.2-nikolaik`** —— OpenHands 的 runtime
  client 已內建,保證 OpenHands 那一側可用。
- **裝 single-user nix + materialize `flake#docker`** —— 把 limn 的依賴 closure
  （Qt/MuPDF/SBCL/xvfb/xdotool/x11vnc…）烤進去。agent 之後 `nix develop /limn#docker
  --command ...` 就能 build + 跑 e2e。

**為什麼不是 FROM limn-e2e + 裝 OpenHands client（反向）**:limn-e2e 的 base 是
`nixos/nix`,沒有 apt / system python3,跟 OpenHands runtime client 的安裝流程
（預設 Debian + apt + pip）正面衝突。順向（FROM nikolaik）避開這道牆,結果對 agent
完全等價 —— 它照樣有完整 `nix develop /limn#docker`。

## 怎麼用

```bash
# 1. build runtime image（一次；首次重，含 23.5GB base + nix closure）
bash meta/openhands/build-runtime.sh

# 2. 啟動（建議掛專用 worktree，見下方 git 安全）
WORKSPACE=/path/to/limn-worktree bash meta/openhands/run.sh
# 然後瀏覽器開 http://localhost:3000
```

前置:`~/.authinfo` 要有 `machine deepseek.api ... password <KEY>`（key 永遠從這裡
讀,不 bake 進 image）。

## agent 該讀什麼（交接給 DeepSeek 的入口）

- **`CLAUDE.md`**（repo 根）—— 所有 policy:**全程繁體中文**、git 安全、驗證 workflow
  （§6 walkthrough）、Doom evil+SPC leader 鍵位政策（§7）。
- **`docs/ROADMAP.org`** —— 全 feature 總索引,尤其 `* limn: next steps（DeepSeek
  開發批次）` 那段就是這次要做的。
- 各 design doc（`docs/*-design.md`）—— 每份開頭「現況盤點」列了已 ship 的零件,
  每份都有「headless 可測」段落,讓 agent 不靠人眼也能程式化驗證。

## 驗證:agent 怎麼自己確認改對了

runtime image 內含 xvfb + x11vnc,所以 agent 在容器裡能跑**完整 headless 流程**:

- **unit test**：`nix develop /limn#docker --command sbcl --script backend/tests/unit/run-unit.lisp`
- **headless 探針**：`env HEADLESS=1 LIMN_BIN=... nix develop /limn#docker --command
  bash backend/run-repl.sh --eval '(o "<pdf>")' --load /tmp/probe.lisp --eval '(q)'`
  —— wire 呼叫 `(limn:call "cmd" :|key| val)`,把視覺問題變成幾何斷言（見 ISSUES I-8）。
- **GUI 目視**：人要看畫面就 VNC 進去（`run-os-e2e.sh` 那套 `x11vnc`,base Dockerfile
  註解有 `-p 5900:5900 -e X11VNC=1` 的 debug 用法）。真機限定的重繪 bug（如 3c /
  ISSUES I-11）仍需人眼,但絕大多數驗證 headless 就夠。

## ⚠ git 安全（重要）

agent 會在 WORKSPACE 裡**就地改檔**。**強烈建議 WORKSPACE 指向一個專用 git
worktree**,而非 main 工作樹 —— 這樣 agent 的改動天生落在自己分支,永遠不會直接
動到 main。`CLAUDE.md` 已有 git 安全規則,但 DeepSeek 未必像 Claude 嚴守,所以用
worktree 做**硬隔離**,整合仍由人 review。

## 風險點現況（2026-05-30 更新）

`Dockerfile.runtime` 裡標了 A/B/C，目前狀態：

- **A（nix 安裝）✅ 已解**：官方 single-user 安裝器拒絕 root（需 nixbld group），
  已換成 Determinate installer（`install linux --no-confirm --init none`，專為
  容器/root 設計），驗證安裝成功。
- **B（runtime user）🟡 部分**：以 **root** 跑（`--entrypoint bash` 抽查）一切正常 ——
  nix / build / 測試都過。但 **OpenHands 實際用哪個 user 跑 agent 指令尚未確認**：
  若它降權到非 root，且容器內沒跑 nix daemon（`--init none`），非 root 可能無法
  build 新的 store path。要等 `run.sh` 真正啟動 OpenHands session 才驗得到；屆時若
  撞到，解法是讓 runtime 以 root 跑、或補一個可用的 nix daemon / 放寬 store 權限。
- **C（closure 下載）✅ 已解**：materialize 約 150s（含下載），closure 已烤進 image，
  agent 第一個 `nix develop` 秒開。flake 改動時要重 build 該層。

唯一還沒驗到的是 **B 的 OpenHands-managed user** 與**整個 web session 端到端** ——
那要 `run.sh` 跑起來、瀏覽器進 :3000 才測得到，是留給人手動的最後一步。
