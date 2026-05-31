# 從零到 DeepSeek V4 Pro 在 OpenHands 裡開發 limn —— 無痛步驟手冊

> 這份是**線性、可照抄的步驟手冊**：跟著做，最後你會有一個跑起來的 OpenHands
> Server，裡面 DeepSeek V4 Pro 直接對 limn 這個 repo 工作。
>
> 想了解**為什麼這樣設計**（兩個 container 的職責、runtime image 的方向決策、
> 依賴鐵律的機制）請讀同資料夾的 [`README.md`](README.md)。這份只管「怎麼做」。

---

## 0. 全景：跑起來之後長怎樣

```
┌─────────────────────────────────────────────────────────────┐
│  你的 macOS host（Docker Desktop）                            │
│                                                              │
│  ┌──────────────────────────┐   ┌─────────────────────────┐ │
│  │ OpenHands app container   │   │ runtime / sandbox        │ │
│  │ web UI @ localhost:3000   │──▶│ limn-openhands-runtime   │ │
│  │ 跟 DeepSeek V4 Pro 對話   │   │ agent 真正執行指令的地方  │ │
│  │ 編排 agent                │   │ 內含 nix+Qt+SBCL+MuPDF…  │ │
│  └──────────────────────────┘   └─────────────────────────┘ │
│         │                                  │                 │
│         ▼                                  ▼                 │
│   DeepSeek V4 Pro API              掛載你的 worktree         │
│   (api.deepseek.com)              （agent 就地改檔的地方）    │
└─────────────────────────────────────────────────────────────┘
```

兩個 container 分工：**app** 負責對話/編排（web UI），**runtime** 是 agent 真正
`build limn / 跑測試 / 跑 headless e2e` 的地方。關鍵就是 runtime image 必須帶齊
limn 的整套工具鏈——這份手冊的 Step 2 就在做這件事。

---

## 1. 前置：你的 host 需要先有這些

| 項目 | 要求 | 怎麼確認 |
|---|---|---|
| **Docker** | Docker Desktop，能跑 `linux/amd64`（runtime image 是 amd64） | `docker run --rm --platform linux/amd64 alpine echo ok` |
| **磁碟空間** | 至少 **40 GB** 空閒（base 23.5GB + nix closure + 各 layer） | `df -h` |
| **limn repo** | 本機 clone | 你正在讀的這個 repo |
| **DeepSeek V4 Pro** | API key，且帳號可用 `deepseek-v4-pro` model | 見 Step 1 |
| **網路** | 首次 build 要下載 base image + nix closure，量大 | — |

> ⚠ **平台**：runtime image 與 `run.sh` 都指定 `--platform linux/amd64`。在
> Apple Silicon 上 Docker 會用 Rosetta 模擬，可跑但較慢；這是正常的。

---

## 2. 環境裡會有哪些 dependencies（runtime image 內含）

Step 2 build 出來的 `limn-openhands-runtime` image 會帶齊以下工具，**全部由
`flake#docker` 的 nix closure 烤進去**，所以版本跟你 host 上 `nix develop`、跟 CI
完全同源（這就是「依賴單一版本鐵律」，見 §6）：

| 類別 | 內容 | 版本（依 flake.lock 而定） |
|---|---|---|
| **nix** | Determinate Nix（single-user，root 可用） | 3.21.0 |
| **Lisp** | SBCL | 2.6.3 |
| **GUI 工具鏈** | Qt（qmake/make 編 C++ 前端）、MuPDF、zlib、harfbuzz、freetype… | Qt 6.11.0 |
| **headless e2e** | Xvfb、xdotool、x11vnc、fcitx5（真 nix store 路徑） | — |
| **OpenHands** | runtime client（內建於 base image） | 0.57.2 |

你**不需要**手動裝任何一個——`build-runtime.sh` 會把整包 closure materialize 進
image。agent 進去後 `nix develop /limn#docker --command ...` 就能用全套。

> 真實版本永遠以 repo 現場的 `flake.lock` 為準。上表的數字是寫這份文件當下的快照，
> 別把它當成權威；權威是 `flake.lock` + image 內烤進去的那份。

---

## 3. Step 1 — 準備 DeepSeek key（`~/.authinfo`）

key **永遠**從 `~/.authinfo` 讀，**絕不** bake 進 image 或環境檔。在 `~/.authinfo`
加一行（已有就跳過）：

```
machine deepseek.api login api password <你的_DEEPSEEK_API_KEY>
```

確認讀得到：

```bash
grep -i "machine deepseek.api" ~/.authinfo \
  | awk '{for(i=1;i<=NF;i++) if($i=="password") print $(i+1)}'
# 應印出你的 key
```

`run.sh` 啟動時就是用這段邏輯抓 key，抓不到會直接報錯擋下。

---

## 4. Step 2 — build runtime image（一次，較久）

```bash
cd /path/to/limn         # repo 根
bash meta/openhands/build-runtime.sh
```

- 預設 tag：`limn-openhands-runtime:0.57.2`
- 首次 build **重**：23.5GB nikolaik base + nix closure 下載 + materialize（約
  150s 烤 closure，加上下載時間，整體數分鐘到十幾分鐘）
- build 會把 `flake.lock` 的 sha256 + nixpkgs rev 烤成 image label（provenance）

完成後確認 image 在：

```bash
docker image inspect limn-openhands-runtime:0.57.2 >/dev/null && echo "✓ image ready"
```

> 想強制乾淨重 build：`bash meta/openhands/build-runtime.sh --no-cache`

---

## 5. Step 3 — 指定 DeepSeek **V4 Pro** model

依開發政策，DeepSeek dev loop **必須用最強的 model**，目前是 **`deepseek-v4-pro`**。
DeepSeek API 上可用的 id（實測）：`deepseek-v4-pro`、`deepseek-v4-flash`、
`deepseek-chat`、`deepseek-reasoner`。

OpenHands 走 litellm 介面，model 字串前綴 `deepseek/`，所以要設：

```
LLM_MODEL = deepseek/deepseek-v4-pro
```

設定位置有兩種方式：

**方式 A（推薦，改一行讓它成預設）** —— 編輯 `meta/openhands/run.sh`，把

```bash
  -e LLM_MODEL="deepseek/deepseek-chat" \
```

改成讀環境變數、預設 V4 Pro：

```bash
  -e LLM_MODEL="${LLM_MODEL:-deepseek/deepseek-v4-pro}" \
```

**方式 B（臨時）** —— 啟動時用環境變數覆蓋（需先做方式 A 把它變成 `${LLM_MODEL:-…}`，
否則 run.sh 目前是寫死的）：

```bash
LLM_MODEL=deepseek/deepseek-v4-pro WORKSPACE=... bash meta/openhands/run.sh
```

> ⚠ **目前現況**：`run.sh` 裡 `LLM_MODEL` 寫死 `deepseek/deepseek-chat`。要跑
> V4 Pro，請先照方式 A 改成 `${LLM_MODEL:-deepseek/deepseek-v4-pro}`。換更強的
> model 前一定先跟使用者確認（政策）。

---

## 6. Step 4 — 準備一個隔離的 git worktree（git 安全，重要）

agent 會在掛載的 WORKSPACE 裡**就地改檔**。**強烈建議** WORKSPACE 指向一個專用
worktree，而非 main 工作樹——這樣 agent 的改動天生落在自己的分支，永遠不會直接
動到 main，整合仍由人 review。

```bash
cd /path/to/limn
git worktree add -b deepseek/work ../limn-deepseek-work
# → ../limn-deepseek-work 就是要掛給 agent 的 WORKSPACE
```

> DeepSeek 未必像 Claude 一樣嚴守 git 規則，所以用 worktree 做**硬隔離**。

---

## 7. Step 5 — 啟動 OpenHands

```bash
WORKSPACE=/path/to/limn-deepseek-work \
LLM_MODEL=deepseek/deepseek-v4-pro \
bash meta/openhands/run.sh
```

啟動前 `run.sh` 會**自動跑依賴鎖守門**（`check-lock-sync.sh`）：比對 repo 的
`flake.lock` 跟 image 內烤進去的那份。

- 一致 → 印 `✅`，繼續啟動
- 不一致 → 印巨大警報並 **exit 1**，拒絕啟動（代表你改過 `flake.lock` 但沒重 build
  image，三方依賴版本漂掉了；解法見 §10）

看到這幾行就對了：

```
>>> Workspace : /path/to/limn-deepseek-work
>>> Runtime   : limn-openhands-runtime:0.57.2
>>> 開啟後進  : http://localhost:3000
```

---

## 8. Step 6 — 進 web UI，讓 DeepSeek 開始工作

1. 瀏覽器開 **http://localhost:3000**
2. 若 web UI 要你確認 LLM 設定：model `deepseek/deepseek-v4-pro`、base URL
   `https://api.deepseek.com/v1`、key 用你的（run.sh 已透過環境變數帶入）
3. **交接給 agent 的入口**（在對話框請它先讀這些）：
   - **`CLAUDE.md`**（repo 根）—— 所有 policy：全程繁體中文、git 安全、驗證
     workflow、鍵位政策
   - **`docs/ROADMAP.org`** —— 全 feature 索引，特別是
     `* limn: next steps（DeepSeek 開發批次）` 那段就是要做的
   - 各 `docs/*-design.md` —— 每份開頭「現況盤點」+「headless 可測」段落

一個好的開場 prompt 範例：

```
請先讀 CLAUDE.md（全程繁體中文、git 安全、驗證 workflow）與 docs/ROADMAP.org
的「next steps」段。然後挑第一優先項，自己探索 repo、實作、並用 §9 的方式
跑測試驗證。改動只落在目前 worktree 的分支，不要動 main。
```

---

## 9. Step 7 — agent 怎麼自我驗證（不靠人眼）

runtime image 內含 Xvfb + x11vnc，所以 agent 在容器裡能跑**完整 headless 流程**：

- **unit test**：
  ```bash
  nix develop /limn#docker --command sbcl --script backend/tests/unit/run-unit.lisp
  ```
  「乾淨」= 失敗數 ≤ baseline。**baseline 以 repo 內的基準檔為準**（thinloop 用
  `limn-baseline.txt`；容器 unit 的歷史基準是 10 個 known-broken，但會隨功能演進，
  別硬記數字，以基準檔/ROADMAP 當下記載為準）。agent 的改動若讓 baseline 以外的
  測試變紅，那才是引入的退化。

- **headless 探針**（把視覺問題變成幾何斷言）：
  ```bash
  env HEADLESS=1 LIMN_BIN=... nix develop /limn#docker --command \
    bash backend/run-repl.sh --eval '(o "<pdf>")' --load /tmp/probe.lisp --eval '(q)'
  ```
  用 wire 呼叫 `(limn:call "cmd" :|key| val)` 斷言狀態。

- **GUI 目視**（真機限定的重繪 bug 才需要）：VNC 進容器看畫面（x11vnc，見 base
  Dockerfile 的 `-p 5900:5900 -e X11VNC=1` debug 用法）。絕大多數驗證 headless 就夠。

---

## 10. 卡關點 / FAQ

| 症狀 | 原因 | 解法 |
|---|---|---|
| 啟動時印「nix 依賴鎖不一致」並 exit 1 | 你改過 `flake.lock`（含 `nix flake update`）但沒重 build image，image 內烤的 lock 舊了 | `bash meta/openhands/build-runtime.sh` 重 build，讓容器吃到新 lock |
| 「找不到 runtime image」 | 還沒 build | 回 Step 2 |
| 「~/.authinfo 找不到 deepseek.api」 | key 沒設或格式不對 | 回 Step 1 |
| agent 跑的還是 deepseek-chat 不是 V4 Pro | run.sh 的 LLM_MODEL 寫死 | 回 Step 3 方式 A |
| 容器內非 root 無法 build 新 store path | OpenHands 可能降權跑 agent（risk-point B，見 README） | 讓 runtime 以 root 跑，或補可用的 nix daemon / 放寬 store 權限 |
| Apple Silicon 上很慢 | amd64 image 在 ARM 上走 Rosetta 模擬 | 正常現象；要快得用 amd64 機器 |

---

## 11. 改了依賴之後一定要做的事（鐵律）

**動了 `flake.lock`（含 `nix flake update` / 升任何依賴）→ 必須重 build runtime image：**

```bash
bash meta/openhands/build-runtime.sh
```

否則 host（你）、容器（DeepSeek）、CI 三方會跑在不同依賴版本上，驗證結論就不可信。
守門員 `check-lock-sync.sh`（run.sh 會自動先跑）就是擋這個的最後一道牆。

```bash
bash meta/openhands/check-lock-sync.sh   # 想手動先檢查
```

---

## 一句話總結

```
Step 1 authinfo 放 key
  → Step 2 build-runtime.sh（一次）
  → Step 3 LLM_MODEL=deepseek/deepseek-v4-pro
  → Step 4 開隔離 worktree
  → Step 5 run.sh（守門自動跑）
  → Step 6 :3000 交接 CLAUDE.md + ROADMAP
  → Step 7 agent 自己 headless 驗證
```
