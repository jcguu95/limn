# leader-keys-design.md

Doom-Emacs 風 `SPC` leader 鍵位 —— 設計與分階段計畫。
狀態:⏭ planned（2026-05-29 開檔）。

這份 doc **同時是 feature 也是 policy**:

- *feature*:把 Doom 的 `SPC` leader（namespaced、which-key 可探索）做成
  limn 的**預設**鍵位方案。
- *policy*:**以後所有 feature 都以 `SPC` leader 為預設綁定路徑**;純 Emacs
  `C-x`/`C-c` 不再是新功能的預設。這條已寫進 `CLAUDE.md`,全 agent 必須 follow。

## 目標 / 決策

1. **預設 = Doom `SPC` leader。** 開箱即用:`SPC` 進一棵 namespaced 命令樹,
   配 which-key（v0.28 已有）顯示下一層。例：
   - `SPC f` 檔案（`SPC f f` find-file、`SPC f s` save…）
   - `SPC b` buffer（`SPC b b` switch-to-buffer、`SPC b i` ibuffer、`SPC b d` kill…）
   - `SPC w` window（`SPC w /` 直分、`SPC w -` 橫分、`SPC w d` close、`SPC w w` other、
     `SPC w u` win-undo…）
   - `SPC s` search（`SPC s s` isearch、`SPC s o` occur…）
   - `SPC n` narrow（`SPC n n` region、`SPC n w` widen、`SPC n d` defun）
   - `SPC h` help / describe、`SPC b m` bookmark…（namespace 表見下,待補完）
2. **純 Emacs 使用者自己 rebind。** 提供一個 config 開關**關掉** leader 安裝
   （退回經典 `C-x`/`C-c`,或自行綁）。limn 不強迫,只是把**預設**換成 SPC。
3. **全 agent follow（policy）。** 新增任何 interactive 指令時,要在 SPC 樹下
   給它一個合理 namespace 的綁定,並更新 which-key 標籤;不要只給 `C-x`/`C-c`
   就當完成。

## leader 的模態前提 —— 已定案：evil（vim 模態）是必要的

**定案（2026-05-29）:** Doom 的代表就是 evil；leader 與 evil 模態是一體的,
**必須**一起做。規則直接照 Doom：

- **normal state → `SPC` 是 leader。** 不打空白,直接進命令樹。
- **insert state → `SPC` 打空白,leader 退位給 `M-SPC`。**
- **minibuffer / chrome buffer**:leader 不介入,維持原鍵。

因此本 feature **依賴 evil 模態先到位** —— evil 本身是獨立的前置 feature,
設計見 **`docs/evil-mode-design.md`**。leader 樹建在 evil state 之上：

- **PDF buffer**:本來就 modal-ish（v0.37 pdf-mode 已有 vim 式 j/k）。等同
  evil 的 normal-ish 狀態,`SPC` 直接當 leader → **第一個落地**。
- **可編輯 text buffer**:evil normal 下 `SPC`=leader、insert 下 `SPC`=空白、
  leader=`M-SPC`。完全 Doom 體感。

> §0 的開放問題到此關閉:不再有「`SPC` vs `M-SPC` 二選一」——兩者都要,由
> evil state 決定哪個生效。實作順序上 evil 模態先行(見 sub-roadmap §0)。

## 架構落點

- **大腦在後端**:leader 樹是 Lisp keymap(`limn/keys` 的 prefix-map),住在
  後端;沿用既有 `install-default-bindings` / which-key 註冊模式。
- **與既有 keymap 的關係**:leader 是**疊加的一層 prefix map**,不刪既有
  `C-x`/`C-c`(那些仍在,給純 Emacs 肌肉記憶 / 關掉 leader 的人用)。預設兩套
  並存,leader 是「主推 + which-key 可探索」的那套。
- **config 開關**:`defcustom`(對齊 v0.25 defcustom)如
  `*enable-leader-keys*`(預設 `t`)。關掉則 `install-defaults` 跳過 leader 安裝。

## namespace 草表(待補完 + 你定案)

| 前綴 | 領域 | 範例 |
|------|------|------|
| `SPC f` | file | `ff` find-file、`fs` save、`fr` recentf |
| `SPC b` | buffer | `bb` switch、`bi` ibuffer、`bd` kill、`bm` bookmark |
| `SPC w` | window | `w/` vsplit、`w-` hsplit、`wd` close、`ww` other、`wu`/`wr` win-undo/redo |
| `SPC s` | search | `ss` isearch、`so` occur、`sr` query-replace |
| `SPC n` | narrow | `nn` region、`nw` widen、`nd` defun |
| `SPC h` | help | `hf` describe-function、`hk` describe-key、`hm` describe-mode |
| `SPC g` | goto/git | （待定:goto-line / 未來 vc） |
| `SPC p` | project | （待定） |

> 規則:namespace 字母盡量對齊 Doom（降低既有 Doom 使用者的學習成本）。

## 分階段 sub-roadmap(planned)

- [x] §0 **拍板** ✅：evil 模態必要;normal=`SPC`、insert=`M-SPC`。evil 本身
      獨立成 `docs/evil-mode-design.md`,**先行**;leader 建在其 state 之上。
- [ ] §1 leader prefix-map 基礎 + `*enable-leader-keys*` defcustom
      （**依賴 evil normal/insert state 可查詢**）
- [ ] §2 PDF buffer 先落地 `SPC` leader（最自然,無空白衝突）
- [ ] §3 補齊 namespace 表（f/b/w/s/n/h…）+ which-key 標籤
- [ ] §4 text buffer leader（依 §0 定案）
- [ ] §5 純 Emacs opt-out 驗證（關掉後 `C-x`/`C-c` 完整可用）
- [ ] §6 把現有所有 interactive 指令補進 SPC 樹（回填 policy）
- [ ] §7 walkthrough 驗證 + 文件（user-facing 鍵位表）

## policy —— 寫進 CLAUDE.md，全 agent follow

`CLAUDE.md` 已加一節：**新增 interactive 指令時，預設綁定走 `SPC` leader 的
namespaced 樹 + 更新 which-key；不要只給 `C-x`/`C-c` 當預設。** 經典 Emacs
綁定可保留為並存層,但不是新功能的預設路徑。

## 驗證

- keymap 結構（某個 `SPC x y` dispatch 到哪個 command）可 headless 斷言。
- which-key 跳出來的選單內容可斷言。
- 體感 / which-key 視覺走 walkthrough（CLAUDE.md §6）。
