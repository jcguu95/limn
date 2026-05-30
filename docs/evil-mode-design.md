# evil-mode-design.md

evil（vim 模態編輯）—— 設計與分階段計畫。狀態:⏭ planned（2026-05-29 開檔）。

**定案（2026-05-29）:** evil 模態是**必要的**（absolutely）。它是 Doom 體感的
根基,也是 `SPC` leader（`docs/leader-keys-design.md`）的前置依賴——leader 靠
「現在是不是 normal state」來決定 `SPC` 當 leader 還是打空白。所以 evil **先行**。

## 目標

把 vim 式的 modal 編輯帶進 limn 的 text/PDF buffer:normal / insert /
visual（之後）等 state,加上 vim 的 motion / operator / text-object。

最低可用集（讓 leader 能站起來）:

- **state machine**:至少 normal ↔ insert。`i`/`a`/`o` 進 insert、`ESC`/`C-[`
  回 normal。state 是 buffer-local、可被後端與前端查詢（leader 要讀它）。
- **normal-state motion**:`h j k l`、`w b e`、`0 $`、`gg G`、`f/t`、`/`(search)。
- **operator**:`d` `c` `y` + motion（`dw`/`cc`/`yy`…）、`x` `p`。
- **PDF buffer**:已有的 vim 式 j/k 導航（v0.37 pdf-mode）視為 evil normal 的
  特化;統一到同一套 state 概念,不要再養第二套 modal。

之後（可延後）:visual state、registers 與 evil 的整合、`.` repeat、macro、
text-objects（`iw`/`ip`/`i(`…）、ex 命令（`:w` `:q`）。

## 架構落點

- **大腦在後端**:state 與 keymap 住 Lisp。evil 本質上是「一組依 state 切換的
  keymap」+「state 變數」。limn 已有 keymap / mode / minor-mode 機制（v0.19→），
  evil 就是在其上疊 state-aware 的 keymap 分層。
  - normal-state-map / insert-state-map / motion-state-map 各一張 keymap;
    當前生效的由 buffer-local 的 evil-state 選。
- **與既有 keymap 的關係**:Emacs C-core 綁定（`C-x`/`C-f`…）在 insert state
  仍可用（如同 Doom 裡 emacs-ish binding 在 insert 仍在）；normal state 則由
  vim 綁定主導。純 Emacs 使用者可用開關停掉 evil（`*enable-evil*`，預設 `t`），
  退回非模態。
- **前端**:游標形狀隨 state 變（normal=block、insert=bar）——這跟
  `docs/cursor-style-design.md` 天然交集（state → cursor type）。modeline 顯示
  當前 state（`<N>`/`<I>`）。
- **wire**:`view/evil-state` 推 state 給前端（改游標 / modeline）;按鍵照常走
  既有 keymap dispatch,只是當前 map 由 state 決定。

## 與其他 feature 的交集

- **leader-keys**:直接依賴。normal=`SPC` leader、insert=`M-SPC`。
- **cursor-style**:state → 游標形狀（block/bar），共用 cursor spec 機制。
- **pdf-mode**:現有 vim 式 j/k 收編成 evil normal 的 PDF 特化,消除雙模態。

## 分階段 sub-roadmap(planned)

- [ ] §1 evil-state（buffer-local 變數）+ normal↔insert 切換（`i/a/o`/`ESC`）+
      可被後端/前端查詢
- [ ] §2 state-aware keymap 分層（normal/insert/motion map,當前生效由 state 選）
- [ ] §3 normal motion（`hjkl w b e 0 $ gg G f t`）
- [ ] §4 operator + 基本編輯（`d c y x p` + motion 組合）
- [ ] §5 前端整合：state → 游標形狀（接 cursor-style）+ modeline state 指示
- [ ] §6 收編 pdf-mode 既有 vim 鍵到統一 evil state
- [ ] §7 `*enable-evil*` opt-out（關掉退回非模態 Emacs）
- [ ] §8 walkthrough 視覺驗證（CLAUDE.md §6）
- [ ] （延後）visual state、text-objects、`.` repeat、macro、ex 命令

## 開放問題

- 模態實作要不要對齊真正的 evil 語意細節（operator-pending、count prefix、
  register），還是先做「夠用的子集」再長?（傾向子集先行,§3/§4 為界）
- visual state 與既有 mark/region（limn 已有 mark-ring）怎麼對齊。

## 驗證

- state 切換、各 state 下某鍵 dispatch 到哪,可 headless 斷言。
- 游標形狀 / modeline state 屬視覺,走 walkthrough。
