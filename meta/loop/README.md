# meta/loop/ —— 已搬到獨立 repo

thin loop 引擎（Claude 當介面、DeepSeek 做髒活）已 **decouple 到獨立 git repo**：

  ~/data/local/projects/deepseek-thinloop/

理由：這個引擎是通用的，limn 只是它磨出來的第一個 case。搬出去後，其他 project
各寫一份 profile 就能共用同一個引擎。

- **limn 的 profile**：`deepseek-thinloop/profiles/limn.json`
  （指回本 repo 的 `meta/openhands/check-lock-sync.sh` 與 nix verify 指令）。
- **用法 / 上手**：`deepseek-thinloop/QUICKSTART.md`、`README.md`、`DISCIPLINE.md`。
- **跑 limn 任務**：
  `bash ~/data/local/projects/deepseek-thinloop/drive.sh \
        ~/data/local/projects/deepseek-thinloop/profiles/limn.json <brief> <clone>`

仍留在本 repo 的 limn 專屬基礎設施（被 profile 引用，不搬）：
- `meta/openhands/`：runtime image build（Dockerfile.runtime / build-runtime.sh）
  + 依賴鎖守門（check-lock-sync.sh）+ OpenHands 互動路（run.sh）。
