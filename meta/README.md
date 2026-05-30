# meta/ —— limn 的「開發 meta-level」工具

這層放的是**怎麼開發 limn** 的工具,不是 limn app 本身。跟 `sioyek/` `backend/`
`docs/`（app 源碼）刻意分開,避免污染。

核心情境:用 **DeepSeek** 當廉價勞動力開發 limn（見 `docs/ROADMAP.org` 的
「limn: next steps」批次）。有**兩條路**,共用同一個地基。

## 共用地基（兩條路都靠這個）

| 元件 | 是什麼 | 在哪 |
|---|---|---|
| **OrbStack** | macOS 上的 docker engine（Linux VM）—— 跑任何容器的物理前提 | 系統層 |
| **runtime image** | `limn-openhands-runtime`（FROM nikolaik + nix + limn `flake#docker` closure） | `meta/openhands/Dockerfile.runtime` |
| **依賴鐵律** | host / 容器三方鎖同一個 `flake.lock`;`check-lock-sync.sh` 守門 | `meta/openhands/check-lock-sync.sh`（CLAUDE.md §0） |
| **clone workspace** | 給 agent 改的 git clone（**放 repo 外**,checkout 自己的分支做隔離） | 例：`/Users/jin/data/local/projects/limn-deepseek` |

## 兩條路

```
                共用：OrbStack + runtime image + 依賴鎖 + clone workspace
                                   │
        ┌──────────────────────────┴───────────────────────────┐
   路 1：OpenHands                                   路 2：thin loop
   （meta/openhands/）                               （meta/loop/）
   2 容器 + web UI :3000                             Claude + 1 沙箱容器
   → 你「直接跟 DeepSeek 互動」                       → 「Claude 當介面、你只看成果」
   開放探索 / 想中途插手時用                          well-scoped 的活、批次推進時用
```

| | 路 1 OpenHands | 路 2 thin loop |
|---|---|---|
| 介面 | web UI（:3000）,人坐旁邊 | Claude（我）—— 寫 brief、讀 status、ping |
| DeepSeek 探索 | ✅（豐富 tools + browser） | ✅（list/read/grep/edit/run,**限 repo 內、無 browser**） |
| 我讀不讀它的廢話 | （你在 web UI 看） | ❌ 只讀 `status.json` |
| 重量 | app + sandbox 兩容器 + web service | 一個沙箱容器 + 一支 host python |
| 何時用 | 開放/探索性任務、你想親自對話/插手 | 任務 well-scoped、我驅動、你只要成果 |

兩條路**不是二選一** —— 共用地基,按任務挑工具。詳見各自 README:
`meta/openhands/README.md`、`meta/loop/README.md`。

## sandbox vs 原生（一個取捨）

兩條路目前都**走沙箱容器**（DeepSeek 的指令關在 Linux 容器裡,不碰你的 mac）。
真正的取捨是「要不要隔離」:要隔離 → 需要容器 → mac 上就需要 OrbStack;不要隔離 →
可原生跑、更輕,但 DeepSeek 直接在你機器上跑指令。預設選**隔離**(安全優先)。
不管哪種,版本都由 `flake.lock` 鎖死,只是平台（Linux vs macOS）不同。
