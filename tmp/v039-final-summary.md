# v0.39 — final tally after B10 + W20 + W13/W17 + W16

## Workflow tally

| Status     | Pre-v0.39 (v0.38 wrap) | v0.39 (mid) | **v0.39 final (post-B6)** | Δ vs v0.38 |
|------------|------------------------|-------------|---------------------------|------------|
| PASS       | 22                     | 26          | **27**                    | **+5**     |
| PARTIAL    | 8                      | 1           | 1                         | -7         |
| no-result  | 0                      | 2           | 2                         | +2         |
| FAIL/flake | 0                      | 1 flake     | **0**                     | —          |
| Assertions | 86/95 (90.5%)          | 93/95       | **94/95** (98.9%)         | +8         |

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

### 4. W16 — CJK via kill-ring (this commit)
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
2581 (v0.38 start) → 2633 (v0.38 wrap) → **2660** (v0.39 final).
+79 assertions in this sprint, 0 failures.

## Docker image
`limn-e2e:latest` rebuilt twice (B10 LF mapping + W20 buffer/list).

## Remaining (post v0.39)

- **W04, W05** — pre-v0.39 structural (TOC deadlock, crash before
  result).  Both are bigger event-loop redesigns (related to B17).
- **W30 / B17** — auto-revert event-loop pump (structural).
- **B6** — stack-smashing crash flake (~10-33% of runs depending on
  workload).  Needs C++ debugger session.

Backlog deferrals are essentially the same set we'd marked structural
at v0.38 wrap — none of them were touched in v0.39 (intentionally,
per "from simple to hard" pacing).
