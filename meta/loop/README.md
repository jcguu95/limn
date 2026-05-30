# meta/loop/ —— 路 2：Claude 當介面的 thin agent loop

> `meta/` 底下的**路 2**。路 1（OpenHands 直接互動）在 `meta/openhands/`。
> 兩條路共用同一個 runtime image 與依賴鎖；總說明見 `meta/README.md`。

## 這是什麼

一個**薄但完整**的 agent 迴圈,讓 **DeepSeek 自主開發 limn**,但:

- **Claude（我）當介面 / 工頭** —— 我寫 brief（任務 + 驗收標準）、讀成果、偷懶就 ping。
- **DeepSeek 做髒活** —— 用 function-calling 自由探索 `/workspace`（limn 的 clone）、
  讀檔、grep、改檔、跑 build/測試,直到呼叫 `finish`。
- **我不讀它的廢話** —— 它的探索/思考全進 `transcript.jsonl`,我只讀 `status.json`。
- **死鎖在這個 repo 內** —— 工具全釘在 `/workspace`;沒有 browser、連不出去。

跟 OpenHands（路 1）的差別不是「能不能探索」(能)，是 harness 成熟度。well-scoped
的活走這條;開放探索 / 你想親自插手就走路 1。

## 組成

| 檔 | 作用 |
|---|---|
| `sandbox.sh` | 起/停持久沙箱容器（runtime image，掛 clone 到 `/workspace`）。內含鐵律守門。 |
| `loop.py` | agent 迴圈（stdlib-only）：DeepSeek function-calling、工具 dispatch、驗證、寫 status。 |
| `drive.sh` | 入口：確保沙箱起著 → 開 run 目錄 → 跑 `loop.py`。 |
| `baseline-failures.txt` | 容器內 unit「已知紅燈」清單,用來算 DeepSeek 有沒有引入**新**紅燈。 |
| `.runs/` | 每次跑的 transcript / status / messages（**gitignored**）。 |

## 架構（檔案操作走 host、指令走容器）

workspace clone 是沙箱的 **bind-mount**,所以:

- **檔案工具**（list_dir / read_file / grep / str_replace / write_file）→ `loop.py`
  直接在 **host** 的 clone 上操作（快、無 shell escaping、有路徑釘樁防逃逸）。
- **run_command + 驗證** → `docker exec` 進沙箱（拿 Linux/nix 工具鏈跑 `nix develop
  /limn#docker ... build / 測試`）。

改 host = 改容器內 `/workspace`,兩邊即時一致。

## 怎麼用

```bash
# 0)（一次）build runtime image
bash meta/openhands/build-runtime.sh

# 1)（一次）給 DeepSeek 一個 git 隔離的 workspace（clone + 分支）
git clone /Users/jin/data/local/projects/sioyek-core /Users/jin/data/local/projects/limn-deepseek
cd /Users/jin/data/local/projects/limn-deepseek && git checkout -b deepseek/<task>

# 2) 寫一份 brief（任務 + 驗收標準），存成 /tmp/brief-xxx.md

# 3) 跑（沙箱會自動起）
bash meta/loop/drive.sh /tmp/brief-xxx.md /Users/jin/data/local/projects/limn-deepseek

# 4) 它做一半停了 → 同一個 run 續跑
bash meta/loop/drive.sh /tmp/brief-xxx.md /Users/jin/data/local/projects/limn-deepseek --continue

# 收工：停沙箱
bash meta/loop/sandbox.sh down
```

## status.json（Claude 只讀這個）

```jsonc
{
  "finished_reason": "finish | stalled | max_iters | error",
  "iterations": 23,
  "deepseek_summary": "一句話它說它做了啥",
  "verify": {
    "unit_passed": 2950, "unit_failed": 10, "baseline_failed": 10,
    "new_failures": [],        // ★ 最關鍵：DeepSeek 引入的新紅燈（空=乾淨）
    "clean": true
  },
  "git_diff_stat": "...", "files_changed": ["backend/..."],
  "stalled": false,
  "transcript": ".../transcript.jsonl"
}
```

判讀規則:`finished_reason == finish` 且 `verify.new_failures == []` → 這輪成功。
`stalled` / `max_iters` → ping 一下（`--continue`）。`new_failures` 非空 → 它弄壞了東西,
brief 補一句叫它修,再 `--continue`。

## 寫 brief 的要點（決定成敗的地方）

DeepSeek 探索靠它自己,但**範圍與驗收靠你的 brief**。一份好 brief:

- 指向對的 design doc（`docs/<feature>-design.md`）與其「現況盤點 / headless 可測」段。
- 明確列**驗收標準**（哪些 unit 要綠、哪個 headless 探針要回什麼、build 要過）。
- 圈出**邊界**（不要動哪些子系統,對齊該 doc 的「不在本次範圍」）。
- 提醒它遵守 `CLAUDE.md`（繁中、不 commit、SPC leader）。
