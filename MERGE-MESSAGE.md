# v0.40 — buffer narrow / widen

## 一句話

把 Emacs 的 `narrow-to-region` / `widen` 概念完整搬進 Limn — **語意層**（point-min / point-max、text-nav / isearch / regex / kill / occur / mark 全部尊重 narrow），**UX 層**（`C-x n n` / `C-x n w` / `C-x n d` interactive commands、modeline 顯示 `Narrow`），**視覺層**（C++ QPlainTextEdit 真的只看到 narrow 那一段，跟 Emacs 行為一致 — 外面的字會消失，不是變暗）。

## 分支與最後 commit

- branch：`claude/hardcore-chatterjee-ba239b`
- HEAD commit：`67365e6` `v0.40 §3 fixup: wire excursion/text-nav vtables in limn:start`
- main 之後 18 個 commit

## 整體架構

分三個 Phase：

| Phase | 內容 |
|---|---|
| **1. Semantics (語意層)** | 6 個 Lisp module 各自尊重 narrow：text-nav / mark / isearch / regex / kill / occur |
| **2. UX (使用者層)** | interactive commands、keymap 綁定（`C-x n n` / `w` / `d`）、modeline 指示、`narrow-to-defun` 用 SBCL reader |
| **3. Central Gate (中央 gate)** | C++ `TextBuffer` class 把 `GapBuffer` 鎖進 `private`，所有 buffer mutation 走 method，narrow 變成 type-system 保護的 invariant；widget 只看到切片 |

## 每個 Phase 的具體 commit

### Phase 1 — 6 modules、67 個新 unit tests

- `3ffca03` §1.1 text-nav narrow-aware（24 tests）— M-< / M-> / C-a / C-e / C-n / C-p / M-f / M-b / DEL / C-k / M-d 都尊重 `[point-min, point-max)`
- `c8145a3` §1.2 mark narrow-aware（13 tests）— set-mark / push-mark / exchange-point-and-mark clamp
- `4c66221` §1.3 isearch narrow-aware（7 tests）— 只回 narrow 內的 match
- `6a59997` §1.4 regex narrow-aware（12 tests）— re-search-{forward,backward,in-buffer} / looking-{at,back}
- `320c226` §1.5 kill narrow-aware（7 tests）— kill-region / copy-region-as-kill clip
- `b590dc8` §1.6 occur narrow-aware（5 tests）— 只列 narrow 內的 lines

### Phase 2 — UX、47 個新 unit tests + 2 個 integration tests

- `77932ad` §2.1 interactive commands & keymap — `cl-user::narrow-to-region` / `widen`，綁 `C-x n n` / `C-x n w`
- `1bb1348` §2.2 modeline narrow indicator — `format-narrow-indicator`、PDF mode modeline 整合
- `0b9dd45` §2.3 dim overlay（後來被 Phase 3 取代）
- `c933630` §2.4 `narrow-to-defun` via SBCL reader（14 tests）— 用 `read-preserving-whitespace` 走頂層 form，避免吞掉 trailing whitespace 導致兩個相鄰 form 的 boundary 模糊
- `bf93d7c` §2.5 text-mode modeline integration — 補上 text-mode 沒在用的 `modeline/set`
- `3481b62` §2.6 integration tests for narrow — 在真 Limn binary 上跑 buffer-modified event → marker fixup 的 round-trip

### Phase 3 — Central Gate（這次 PR 的重點）

`c3ba2d2` v0.40 §3：central-gate narrow via C++ TextBuffer encapsulation

**動機**：Phase 1 採 Emacs 的「每個 primitive 各自 clamp」convention。Emacs 在 C 寫，沒辦法用 access control 強制；我們在 C++，可以把 narrow 變成 class invariant，由 compiler 守住。

**新檔**：`sioyek/pdf_viewer/limn_text_buffer.h`

```cpp
class TextBuffer {
private:
    GapBuffer content_;                          // ← private
    int cursor_qs_ = 0;
    std::optional<std::pair<int,int>> narrow_qs_;
public:
    void insert(int qs_at, const QString& s);   // clamp 到 [begv, zv]、cursor + narrow 自動 fixup
    void remove(int qs_from, int qs_len);       // clip 到 [begv, zv)
    void set_cursor_qs(int qs);
    void narrow_to_qs(int qs_start, int qs_end);
    void widen();
    QString text_for_widget() const;            // 給 widget 的切片
    int     cursor_for_widget_qs() const;       // 相對 BEGV 的 cursor
    QString to_qstring() const;                 // 完整內容（給 save / buffer/text wire）
    // ... etc
};
```

**改動**：

- `limn_command.h` 把 `text_buffers` 改成 `QHash<QString, TextBuffer>`、移除 `text_cursors`
- `limn_command.cpp` 71 個 direct-access 全部改走 method
- 新 wire command `buffer/narrow {start, end}` 或 `{clear: true}`
- `sync_text_widget` 改用 `text_for_widget()` — widget 只 setPlainText narrow 切片
- `cmd_buffer_load_file` 補一個 explicit cursor reset to 0（`insert` 會自動 advance cursor，但 load-file 的 contract 是「cursor 在開頭」）
- `cmd_minibuffer_close` 也補 cursor reset（順便修了一個原本 baseline 偶爾 fail 的 test ordering 問題）

**Lisp 側**：

- `limn/excursion:narrow-to-region` / `widen` / `save-restriction` 設完 markers 後 push wire `buffer/narrow`
- narrow-end marker 從 `:before` 改 `:after` insertion-type — 讓 insert at ZV 真的擴張 narrow，符合 Emacs `ZV += nchars` 語意
- `%push-narrow-wire` helper：late-bound 到 `limn:call`，wire 不在線時 graceful no-op（unit tests 仍然能跑）

**為什麼 widget 不用改**：survey 發現 QPlainTextEdit 在這個 codebase 是 `read-only + NoFocus`，所有鍵盤輸入走 `LimnInputFilter → cmd_buffer_*`。widget 從來不會主動改 buffer 內容，所以中央 gate 不用處理 widget input path。

### Walkthrough & 修兩個 latent bug

- `112be42` REPL walkthrough for narrow/widen — 八步驟互動腳本
- `76480be` 繁中、comment-on-fail、summary
- `70d2c26` 顯式 `(narrow-walkthrough)` 入口（auto-load 不穩定）
- `d93c648` walkthrough 更新「真隱藏」版預期
- `67365e6` **v0.40 §3 fixup**：跑 walkthrough 時抓到兩個自 v0.30 / v0.28 就潛伏的 production bug：

  1. `limn/excursion:install-wire-vtable` **從來沒被 `limn:start` 呼叫過**。後果：`limn/marker:*buffer-text-len-fn*` 一直是 defvar 預設的 `(lambda (bid) 0)`，所以任何 `set-marker` 的 clamp 都把 position 推到 0。`narrow-to-region 5 15` 的兩個 markers 都被 clamp 到 0、widget slice 變空字串。修法：加 `#:limn/excursion` 進 `limn:start` 的 install-wire-vtable dolist。
  2. `%install-cursor-vtables` 沒包含 `limn/text-nav`。後果：`text-nav:end-of-buffer` / `beginning-of-buffer` 都是 no-op against 預設 vtable。修法：加 `#:limn/text-nav`、同時 wire 完整 vtable surface（text / insert / delete 也接上去）。

  這兩個 bug Phase 1 unit test 沒抓到，因為 unit test 自己 wire 自己的 mock vtable，繞過 production install 路徑。

## 測試狀態

- **Unit tests**：2787 pass / 5 fail
  - 5 個 failure 全部是 pre-existing baseline，跟這個 PR 無關
  - 這個 PR 加了 **~114 個新 unit tests**（67 + 47），全綠
- **Integration tests**：1605 pass / 23 fail
  - 比原 baseline（1604 / 24）多 1 個 pass，因為 minibuffer-close 順手修了一個 test-ordering 問題
  - 新增 2 個 V040 narrow integration tests，跑在真 Limn binary 上全綠
- **手動 walkthrough**（[scratch/narrow-walkthrough.lisp](scratch/narrow-walkthrough.lisp)）：8 步驟全綠，user 在實際 Qt 視窗上確認過視覺行為跟 Emacs 一致

## 動到的檔案大致清單

新檔：
- `sioyek/pdf_viewer/limn_text_buffer.h` — TextBuffer class
- `scratch/narrow-walkthrough.lisp` — 手動驗證腳本
- `backend/tests/unit/*-narrow.lisp` — 9 個新 narrow unit test files
- `backend/tests/unit/narrow-cmd.lisp`、`narrow-modeline.lisp`、`narrow-dim.lisp`、`narrow-defun.lisp`、`narrow-text-modeline.lisp`

主要改動：
- `backend/limn-excursion.lisp` — narrow-to-region / widen / save-restriction 加 wire push、`narrow-end` marker 改 `:after`
- `backend/limn-text-nav.lisp` / `limn-mark.lisp` / `limn-isearch.lisp` / `limn-regex.lisp` / `limn-kill.lisp` / `limn-occur.lisp` — 各自加 `*point-min-fn*` / `*point-max-fn*` vtable + 命令 narrow-aware 改寫
- `backend/limn-default-config.lisp` — `narrow-to-region` / `widen` / `narrow-to-defun` interactive commands + keymap
- `backend/limn-text-mode.lisp` — modeline label push、`%buffer-text` helper
- `backend/limn-pdf-mode.lisp` — `pdf-format-modeline` 加 narrow 參數
- `backend/limn.lisp` — fix excursion / text-nav vtable install
- `sioyek/pdf_viewer/limn_command.{h,cpp}` — 71 個 access site 走 TextBuffer、新 `cmd_buffer_narrow` handler、`sync_text_widget` 用 `text_for_widget()`
- `sioyek/pdf_viewer_build_config.pro` — 加 `limn_text_buffer.h`

## 沒做的事

- **PDF mode 的 narrow**：PDF mode 用 page-words 抽象，沒有 text-stream，narrow 無法直接套用。`format-narrow-indicator` utility 已準備好，將來 PDF mode 真的要支援 narrow 時 wire-in 即可。
- **Phase 2.3 dim overlay 名義上還在**：Phase 3 把 widget 切片直接做隱藏後，dim overlay 邏輯上 redundant。函式還留著（model 層 API），但 interactive commands 不需要再用。可以下一輪清掉。

## Reviewer 注意事項

1. **C++ refactor 的 audit 是 compiler-enforced**。`GapBuffer` 是 TextBuffer 的 private 成員，外面沒辦法拿到 `GapBuffer&` reference。如果有人想繞過 narrow，會 compile error。這是 Phase 3 比 Emacs convention 強的地方。

2. **`buffer/text` wire 仍然回完整內容**（不是 narrow 切片）。這是刻意的：跟 Emacs 的 `buffer-string`（只回 narrow 內）不同，但符合我們目前 wire contract。如果以後要對齊 Emacs，加一個 `:visible t` flag 就行。

3. **Markers 存絕對座標**，narrow 完全不影響它們。跟 Emacs 一致。

4. **save-restriction 用 markers 存 narrow 邊界**（不是 raw int），所以 body 內的編輯會 fixup。

5. **跨 Phase 的 layering**：Phase 1 的 per-module vtable 在 Phase 3 之後是第二道防線（純 Lisp 不走 wire 的路徑仍受限）。留著，不衝突。
