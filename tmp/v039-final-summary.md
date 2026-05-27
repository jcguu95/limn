# v0.39 — final tally after B10 + W20 + W13/W17 + W16 + B6 + B17 + W04 + W05

## Workflow tally

| Status     | Pre-v0.39 (v0.38 wrap) | mid-sprint   | post-B6     | **v0.39 final (post-B17/W04/W05)** | Δ vs v0.38 |
|------------|------------------------|--------------|-------------|-----|------------|
| PASS       | 22                     | 26           | 27          | **30**                              | **+8**     |
| PARTIAL    | 8                      | 1            | 1           | **0**                               | -8         |
| no-result  | 0                      | 2            | 2           | **0**                               | 0          |
| FAIL/flake | 0                      | 1 flake      | 0           | **0**                               | 0          |
| Assertions | 86 / 95 (90.5%)        | 93 / 95      | 94 / 95     | **99 / 99 (100%)**                  | +13        |

🎉 **Every dogfood workflow passes every assertion.**

\* Excluding W04/W05 (pre-existing structural — TOC deadlock + driver
crash before result line) and W10 which is B6 stack-smashing flake
(2/3 retries PASS — not a v0.39 regression; C++ bug pre-dates this
sprint).

## Per-workflow delta

| W | v0.38 wrap | v0.39 | Notes |
|---|------------|-------|-------|
| W01 | 4/4 | 4/4 | — |
| W02 | 5/5 | 5/5 | — |
| W03 | 3/3 | 3/3 | — |
| W04 | PARTIAL | no result | TOC deadlock — pre-existing, structural |
| W05 | PARTIAL | no result | crash before result line — pre-existing |
| W06 | 5/5 | 5/5 | — |
| W07 | 4/4 | 4/4 | — |
| W08 | 2/2 | 2/2 | — |
| W09 | 4/4 | 4/4 | — |
| W10 | 4/4 | flake (B6) | Stack-smashing crash, ~33% reproduction |
| W11 | 4/4 | 4/4 | — |
| W12 | 5/5 | 5/5 | — |
| **W13** | 1/3 | **3/3 PASS** | B10 + new pdf-copy-region-as-kill + C-y yank |
| **W14** | PARTIAL | **2/2 PASS** | B10 |
| **W15** | PARTIAL | **2/2 PASS** | B10 |
| **W16** | 1/2 | **2/2 PASS** | kill-ring → C-y path (xdotool can't carry CJK in X11) |
| **W17** | 1/2 | **2/2 PASS** | B10 + new set-mark/kill-region/yank + driver reorder |
| W18 | 3/3 | 3/3 | — |
| W19 | 3/3 | 3/3 | — |
| **W20** | 5/6 | **6/6 PASS** | new buffer/list C++ cmd |
| W21 | 3/3 | 3/3 | — |
| W22 | 4/4 | 4/4 | — |
| W23 | 1/1 | 1/1 | — |
| W24 | 1/1 | 1/1 | — |
| W25 | 1/1 | 1/1 | — |
| W26 | 3/3 | 3/3 | — |
| W27 | 5/5 | 5/5 | — |
| W28 | 3/3 | 3/3 | — |
| W29 | 4/4 | 4/4 | — |
| W30 | 2/3 | 2/3 | B17 auto-revert structural — unchanged |

## What landed in v0.39

### 1. B10 — text-mode self-insert (commit `d0a3701`)
Three-layer fix bridging `limn/file:find-file` to C++ text_buffers
via new `*open-text-engine-fn*` / `*fetch-wire-content-fn*` vtable
hooks; bound text-mode RET to newline; mapped LF/CR/TAB raw bytes to
named keys in C++ key_to_string.  +13 unit assertions.

### 2. W20 — buffer/list (commit `419ea35`)
Added missing `cmd_buffer_list` C++ handler.  Enumerates PDF +
text + chrome buffers as `[{buffer-id, path, engine, kind}, …]`.
+3 suite assertions.

### 3. W13 + W17 — cross-engine kill-ring (commit `4b74b09`)
- pdf-mode: `pdf-copy-region-as-kill` + bind M-w
- text-mode: `yank` + bind C-y; `set-mark-command` + bind C-SPC;
  `kill-region` + bind C-w; bind C-a/C-e (Emacs canonical — was the
  W17 root cause, only `<end>` was bound)
- W17 driver: reorder to open A → kill → open B → yank (find-file
  switches the visible widget, can't batch up-front)
- +14 unit assertions.

### 5. B6 — stack-use-after-return in PDF open (next commit)

The W10 stack-smashing flake (~30% rate, going back to v0.36 at least)
turned out to be a textbook use-after-return.  `MainWidget::open_document`
declared `bool invalid = false` on its stack and passed `&invalid`
down through `DocumentView::open_document` → `Document::open` →
`Document::load_document_caches` → `Document::load_page_dimensions`,
which captures the pointer into a DETACHED background thread.  That
thread writes `*invalid_flag_pointer = true` AFTER MainWidget's stack
frame is gone, stomping whatever now occupies that slot — eventually
a function's stack canary, abort, gdb-disappearing heisenbug.

Pass `nullptr` instead.  Both detached threads (load_page_dimensions
+ index_document) already had `if (invalid_flag_pointer)` null-guards,
so they cleanly no-op the writes.  Failure detection still works:
DocumentView sets `current_document = nullptr` on open failure, so
the `!doc` check at the call site is the sole and sufficient signal
(the `invalid ||` half was dead — it was always false at the
synchronous read since the threads hadn't run yet).

Captured with ASAN (opt-in via LIMN_ASAN=1 in pdf_viewer_build_config.pro
+ pkgs.gdb added to flake.nix `dockerExtras`).  Verified: **50 / 50
W10 runs clean post-fix**, was ~30% crash rate.  Probability of seeing
zero crashes by chance if unfixed: ~2e-8.

Also defensively bumped `label_buffer[20]` → `[256]` with `memset` +
hard-null-clamp in `load_page_dimensions_function` (not the root
cause per ASAN, but a real latent overrun if any PDF ever ships a
label > 20 chars).

### 6. B17 / W30 — file-notify readiness handshake (commit `19aebb1`)

W30's auto-revert was 2/3 PARTIAL because `file-notify-add-watch`
returned the moment the inotifywait subprocess was *spawned* — but
the helper hadn't yet executed `inotify_add_watch(2)` on the kernel.
The driver's pattern (enable auto-revert → external write → wait)
consistently lost the first event in that ~50ms gap.

Fix: drop `--quiet` so inotifywait emits its "Watches established."
banner on stderr.  Add a `:stderr` callback that signals a semaphore
when that line arrives.  Block in `%spawn-real-helper` until the
semaphore fires (or 3s timeout — fail open, never deadlock).
fswatch backend uses a marker-file round-trip instead (no banner).

W30: 2/3 → 3/3 PASS, verified across 10 stress runs.

### 7. W04 — pdf-toc was misreading the wire response shape (commit `df6ffc1`)

The W04 "TOC deadlock" diagnosis turned out to be a misread.  There
was never any deadlock; pdf-toc had a bug interpreting the response
and never opened completing-read.

C++ `cmd_buffer_toc` sends the items array DIRECTLY as `data` (via
`send_ok_array`), not wrapped as `{items: [...]}`.  pdf-toc consumed
it with `(getf d :items)`, treating the array as a plist with an
:items field.  On the actual list-of-plists response, GETF iterates
pairs looking for the key — for tutorial.pdf's 11-entry TOC that's
an odd-parity scan and signals `SIMPLE-TYPE-ERROR: malformed
property list`; for even-parity TOCs it returns NIL silently.
Either way `items` was nil, `(when (listp items) ...)` skipped,
completing-read never opened, the minibuffer never showed.

Fix: drop the GETF wrapper; consume `data` as the items list.
Same fix in the W04 driver's A.3 check (mirror bug).

W04: 0 reported (driver crashed on A.3) → 3/3 PASS.

### 8. W05 — convert diagnostic-only driver to assertion driver (this commit)

W05's "no result line" was structural — the driver was pure
diagnostic, capturing PNGs and printing diag lines but never
asserting anything programmatically.  The batch summary script
greps for "result: X / Y pass" to count workflows, so a passless
driver appeared as 0 PASS even though the toggle was working.

Promoted the existing diag function into a checks emitter:
baseline-off + three (dark-mode-after-toggle) checks against the
view/get engine-params.dark-mode nested field.  The PNG-bytes-
differ check I'd have liked is dropped because Xvfb's framebuffer
doesn't rebuild on QOpenGLWidget repaints in this container (B2
structural — same reason W01 uses offset-y rather than pixel diff
as its action-effect signal).

W05: no-result → 5/5 PASS.

### 4. W16 — CJK via kill-ring (commit `8709105`)
Driver swapped to `(limn/kill:kill-new "新增中文段落")` + xdotool
C-y.  Same wire path the new kill-ring infrastructure uses.  X11
XSendKeyEvent doesn't carry Unicode in headless Xvfb — that's an
X11 quirk, not a Limn pipeline gap.  The kill-ring + C-y route
proves buffer/insert + buffer/save survive multi-byte UTF-8.

## Code changes (cumulative)

```
backend/limn-file.lisp                +73 / -5
backend/limn-text-mode.lisp           +83 / -1
backend/limn.lisp                     +65 / -1
backend/limn-pdf-mode.lisp            +28 / -0
backend/tests/unit/file-io-v024.lisp +136 / -0
backend/tests/unit/text-mode-v022.lisp +62 / -0
backend/tests/suites/buffer.lisp      +70 / -0
sioyek/pdf_viewer/limn_input.cpp      +15 / -0
sioyek/pdf_viewer/limn_command.cpp    +45 / -0
sioyek/pdf_viewer/limn_command.h       +1 / -0
tmp/w17-driver.lisp                   driver reorder
tmp/w16-driver.lisp                   driver swap to kill-ring
```

## Unit tier
2581 (v0.38 start) → 2633 (v0.38 wrap) → **2662** (v0.39 final).
+81 assertions in this sprint, 0 failures.

## Docker image
`limn-e2e:latest` rebuilt twice (B10 LF mapping + W20 buffer/list).

## Remaining (post v0.39)

**Nothing in the dogfood batch.**  Every workflow PASSes every
assertion.  The "structural" items deferred at v0.38 wrap (W04,
W05, W30 / B17, B6) all got root-caused and fixed this sprint —
several of them turned out NOT to be the structural problems we
thought (W04 was a wire-shape misread, not a deadlock; B6 was a
straightforward stack-use-after-return once ASAN was in the
toolbox).

Latent items not in the dogfood batch but worth eventually:

- **B2** — Xvfb framebuffer doesn't refresh on QOpenGLWidget
  repaints.  `test/grab-window` returns fixed-size 6464-byte PNGs
  regardless of the actual paint.  W01, W05 work around it by
  asserting on state round-trips rather than pixel diffs.  Would
  unlock proper visual regression testing.
- **B3 / B4** — macOS host issues (Info.plist focus, accessibility
  permission).  Deferred per R1' (docker is canonical for e2e).
- **B9** — Lisp `limn/file::*bufs*` vs C++ `text_buffers` namespace
  split.  Partially closed by B10's bridge but the two registries
  are still independent; a future "buffer-list of truth" would
  unify them.
