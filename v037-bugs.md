# v0.37 bugs found + fixed

Receipts log. Each entry: symptom → root cause → commit hash (filled at commit time).

## A1a Phase

### #1 — vendor/cl-ppcre git submodule not auto-checked-out in fresh worktrees
- **Symptom:** `./backend/run-repl.sh` in a fresh `git worktree add ...` worktree crashes deep in `limn-regex.lisp` with `Package CL-PPCRE does not exist` and a 30-line SBCL backtrace.
- **Root cause:** the supposed "soft-load" in repl.lisp catches the vendor-loader's failure, but limn-regex.lisp later references `cl-ppcre:` package at *read* time which is a fatal reader error — handler-case can't catch reader errors that happen after the protected form returns.
- **Fix:** drop the submodule entirely. cl-ppcre now comes from nix via `sbcl.withPackages [cl-ppcre]` in flake.nix. `(require :cl-ppcre)` in repl.lisp + run-unit.lisp.
- **Regression coverage:** the smoke path itself — `LIMN_NO_SPAWN=1 sbcl --load backend/repl.lisp` should exit 0. Will be CI-enforced as part of Phase A3 / nix-pinning unification.
- **Commit:** TBD

### #4 — macOS `mac { }` .pro block linked vendored mupdf → fresh worktree can't link
- **Symptom:** `nix develop --command make` on a fresh worktree fails at link: `ld: warning: directory not found for option '-L.../sioyek/mupdf/build/release'` then `library not found for -lmupdf-third`.
- **Root cause:** the `mac { }` block in `pdf_viewer_build_config.pro` hardcoded `-L$$PWD/mupdf/build/release -lmupdf -lmupdf-third -lmupdf-threads`. Required the mupdf git submodule + a separate `./build_mac.sh mupdf` cold build (~10 min). Worktrees / fresh clones don't have submodules initialized.
- **Fix:** mac block now uses nix-pinned mupdf same as Linux block (single `-lmupdf` + system harfbuzz / freetype / jpeg / openjp2 / jbig2dec / gumbo). Host ≡ container library versions. Removes 10-min cold dependency on submodule init.
- **Discovery:** A1d macOS rebuild from this worktree.
- **Commit:** TBD (Phase A1d)

### #3 — `sioyek/fzf/` + `begin.png` + `end.png` + `tutorial.pdf` + `pdf_viewer/shaders/` gitignored but build-required → docker build dies in any fresh worktree
- **Symptom:** docker build from any worktree fails: first `make: *** No rule to make target 'fzf/fzf.c'`, then after fzf fix `make: *** No rule to make target 'end.png'`. Each iteration unmasks the next missing dep.
- **Root cause:** `.gitignore` excluded `sioyek/fzf/`, `sioyek/begin.png`, `sioyek/end.png`, `sioyek/tutorial.pdf`, and `sioyek/pdf_viewer/shaders/` — but the .pro file references `fzf/fzf.c` and `resources.qrc` embeds the other four into the binary. The main checkout works only because previous build sessions left these files in place untracked; every fresh clone / worktree / docker COPY context is broken out of the gate.
- **Fix:** untrack from `.gitignore`, `git add -f` all of them. Sizes: fzf 38KB + begin/end PNG 12KB each + tutorial.pdf 148KB + shaders 80KB → ~290KB total. Worth tracking.
- **Discovery:** A1b docker build from this worktree.
- **Regression coverage:** any fresh `git clone && docker build .` (without manual asset copying) now succeeds — that's the smoke test.
- **Commit:** TBD

### #2 — pre-existing test bug `LOCAL-B7-{SET,KILL}-FIRES-CHANGED-EVENT`
- **Symptom:** 2 / 2524 unit tests RED with `ERROR: The variable B is unbound.` Discovered while establishing A1a's baseline.
- **Root cause:** `with-local-ctx` macro never binds a symbol called `b`, but the two tests have `(let ((b b)) (declare (ignore b)) ...)` referencing it. Dead/wrong code that worked by accident if some prior fixture had `b` in scope, broke when the surrounding code was refactored.
- **Fix:** delete the 2 dead lines in each test. Tests now run their full assertion bodies.
- **Regression coverage:** the tests themselves now actually execute.
- **Commit:** TBD

## Phase F (bug-bash) — 79 pass / 32 fail → 111 pass / 0 fail

Final docker e2e: **111 passed, 0 failed**.  Final macOS unit tier:
**2544 passed, 0 failed** (was 2531 baseline + 13 new regression tests).

### driver-A1 — %decode-file-content fallback returned raw bytes
- **Symptom:** v024-file-io OS-tier driver crashed with `Cannot encode JSON value: #(72 101 108 108 ...)` inside the bridge JSON encoder.
- **Root cause:** when limn/coding wasn't loaded, %decode-file-content fell through with `(or raw "")` — handing the buffer-set-content vtable a raw `(vector (unsigned-byte 8))`.  The bridge encoder couldn't serialise it.
- **Fix:** defense-in-depth UTF-8 octets-to-string coercion in the bytes-without-coding branch.  Always returns a string.
- **Regression:** `file-e7-bytes-fallback-returns-string` + `file-e7-bytes-fallback-revert-returns-string` in `file-io-v024.lisp`.  Both hide the limn/coding package via `rename-package` to exercise the fallback directly.
- **Commit:** d99f3ed

### driver-B1 — e2e drivers' dolist load lists rotted
- **Symptom:** 16 OS-tier drivers crashed at READ time with `Package LIMN/WHICH-KEY does not exist`, `Package LIMN/PDF-MODE does not exist`, `Package UIOP does not exist`, `Package CL-PPCRE does not exist` — depending on which late-arriving v0.27-v0.34 module they referenced.
- **Root cause:** each driver carried its own `(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" ...)) (load (b/ f)))` enumeration.  Every time a new module landed (v0.27 limn-pdf-mode, v0.28 limn-which-key / limn-map-macro, v0.34 limn-regex with its cl-ppcre dep) every driver needed manual updating.
- **Fix:** new `backend/tests/e2e/load-limn-system.lisp` helper mirrors `backend/repl.lisp`'s ASDF bring-up.  Each affected driver replaces its dolist with `(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))`.  cl-ppcre, sb-bsd-sockets, every limn/* package — all resolvable at READ time.
- **Regression:** every converted driver must pass docker e2e; verified.
- **Commit:** c43725f + 65911cd (batch 2)

### driver-C1 — v023-process-shell hardcoded /bin/echo etc
- **Symptom:** v023-process-shell crashed with PROCESS-ERROR; nix container has no /bin/echo, /bin/cat, /usr/bin/true.
- **Fix:** %find-on-path walks $PATH when the canonical UNIX entries are missing.  Host macOS path unchanged.
- **Commit:** a837999

### driver-A2 — %selection returned NIL for live selections
- **Symptom:** v027-annotate Ω1a (`view/selection-set ok`) failed; sidecars never wrote (`0 files`).
- **Root cause:** wire `view/selection-get` returns `:|active|`/`:|begin|`/`:|end|`/`:|mode|`/`:|text|` — no `:|rects|`.  `%selection` passed the response through unchanged; `(getf sel :|rects|)` in %add-annotation always saw NIL → early return.
- **Fix:** %selection synthesizes a single bounding-box rect from begin/end (normalised so x1<x2 / y1<y2).  Returns NIL when `:|active|` is false.
- **Regression:** `v027-c-selection-translates-begin-end-to-rects` + `v027-c-selection-returns-nil-when-inactive` + updated mock in `v027-c-highlight-selection-creates-annotation`.
- **Commit:** ac7053a

### driver-A3 — view/overlays wire took the wrong arg name
- **Symptom:** v027-annotate Ω1b (`overlay count grew (0 → 0)`), v027-search Ω2.  Sidecar saved fine, no rect on screen.
- **Root cause:** six call sites in `limn-pdf-mode.lisp` sent the layers array under `:|overlays|`, but the C++ side reads `msg.value("layers")` — missing key silently became NULL → "clear all overlays".
- **Fix:** rename all six writes to `:|layers|`.  Regression test `v027-b-view-overlays-uses-layers-arg` pins the keyword.
- **Commit:** bef0926

### driver-A4 — mark didn't auto-deactivate on text-widget input
- **Symptom:** v033b-edit-during-active-region Ω2 (`mark auto-deactivated after key (active=T)`).
- **Root cause:** Emacs's transient-mark-mode auto-deactivates the region on `*edit-commands*` via `note-command`, but Limn's dispatch only calls note-command for keymap-routed commands.  Text-widget input (xdotool type / IME commit / paste) bypasses the dispatch layer entirely, so the region stuck around through arbitrary edits.
- **Fix:** `limn/mark:install-auto-deactivate-handler` subscribes to `event/buffer-modified` and runs `deactivate-mark` when transient-mark-mode is on.  Mirrors `limn/marker:install-buffer-modified-handler`'s install path; %bootstrap-runtime auto-installs both at every limn:start (idempotent).
- **Regression:** `region-c2-auto-deactivate-on-buffer-modified` + idempotency check in `overlays-v033.lisp`.
- **Commit:** bef0926

### driver-A5 — pdf-mode C-g didn't clear search overlays
- **Symptom:** v027-search Ω4 (`C-g 後 overlays 數量 ≤ 1, got 122`).
- **Root cause:** no C-g binding in pdf-mode-map → fell through to global keyboard-quit → minibuffer closed but pdf-search-state + on-screen highlights persisted.
- **Fix:** bind C-g in pdf-mode-map to `pdf-isearch-quit`.  pdf-isearch-quit delegates to `keyboard-quit` when the minibuffer is open (preserves the C-g-closes-minibuffer contract demo-init pins) and runs pdf-search-reset otherwise.  Explicit `(eq :|open| t)` check — the bridge JSON `:false` decodes to a non-NIL keyword.
- **Commits:** 859e1bf + b5f756d + 9b7bf35

### driver-A6 — buffer-opened event omitted path
- **Symptom:** v027-annotate Ω3 (re-open had 0 overlays), v027-content-move, v027-resume Ω1b (page restore stuck at 0), v027-workflow Ω10.
- **Root cause:** `emit_buffer_opened` only carried frame-id / buffer-id / engine / page-count.  pdf-mode-on-buffer-opened guards on `(when (... path ...))` and silently no-op'd; sidecar load + last-position restore never fired.
- **Fix:** include `doc->get_path()` (via `QString::fromStdWString`) in the event payload.
- **Commit:** c41dea8 + 60ab954

### driver-A6b — %current-pdf-path called a non-existent wire
- **Symptom:** save path resolved to `/tmp/unknown.pdf` for every annotation; reload couldn't find sidecar.
- **Root cause:** `%current-pdf-path` called `(limn:call "buffer/state" ...)` — no such wire command.  Always returned NIL → fallback to /tmp/unknown.pdf.
- **Fix:** read the `*buffer-id-to-path*` cache that pdf-mode-on-buffer-opened populates from the (now-present) path event.
- **Commit:** 69d7243

### driver-A7 — bookmarks didn't survive close+reopen
- **Symptom:** v027-workflow Ω9a (`bookmark 還在 (page=NIL)`).
- **Root cause:** bookmarks were keyed by buffer-id only; buffer-ids are session-local and disappear on close.
- **Fix:** two-layer storage in C++ — primary `bookmarks[buf-id]` (live per-buffer; preserves Ω3c isolation) + mirror `bookmarks_by_path[path]` (persists across close).  bookmark_set/_delete write to both; engine-load hydrates buf-id from path-keyed snapshot when no other open buffer holds the path.
- **Commits:** 34d9c1d + 1c9f913 + 9c24324

### driver-A8 — indent-for-tab-command no-op'd on empty buffers
- **Symptom:** v036-tab-key-text-mode (`after TAB key, buffer has indent (got "")`).
- **Root cause:** `*indent-line-function*` was never installed in CL-USER on fresh sessions (the original eval-when used find-symbol, which returned NIL).
- **Fix:** intern + proclaim + setf-with-default so the install always runs.  indent-for-tab-command also falls back to inserting one tab-stop's worth of whitespace when the indent-line-function leaves point + text unchanged (matches Emacs's tab-to-tab-stop degradation).
- **Regression:** `indent-b-indent-for-tab-command-falls-back-when-noop` + `indent-b-indent-for-tab-command-fallback-uses-spaces` in `indent-v036.lisp`.
- **Commit:** 34bfb73

### driver-A9 — minibuffer didn't close on RET/ESC
- **Symptom:** completing-read Ω4 (`open is false after cancel (got T)`).
- **Root cause:** C++ minibuffer_handle_key emitted the submit/cancel events but didn't flip `minibuffer_open = false`.  make-minibuffer-reader closed via unwind-protect; direct callers (test drivers, third-party Lisp) saw stale open=true.
- **Fix:** C++ side flips the flag (and clears chrome bar) on both RET and ESC.  Double-close from the unwind is harmless.
- **Commit:** 23d867e

### driver-A10 — digit-as-prefix-arg swallowed mode-bound digits
- **Symptom:** v027-nav Ω6c (`0 reset zoom (got 0.8)`).  pdf-mode binds "0" → pdf-zoom-reset, but %dispatch-key consumed "0" as a numeric prefix-arg accumulator before the mode lookup ran.
- **Fix:** mode-buffer lookup runs FIRST; only when no binding exists does the digit accumulate as a prefix-arg.  `5g` integration test still works (5 has no binding).
- **Commit:** 34d9c1d

### driver-D{1..10} — assorted driver-level bugs
Each one's own commit; see git log for the full receipt.  Highlights:
  - D1 v036-perf-large-replace: 10000 matches → 100 (wire-RTT-per-match made the original take >30 min).
  - D2 v024-mark: removed manual add-hook (process-insert was firing twice → markers shifted by 2*len).
  - D3 demo-init.lisp split out from v0.29 init.lisp.example so batch-os-demo etc. still get next-page / search-here.
  - D4 selection-set wire schema (`:|begin|` / `:|end|`, not `:|page|` + `:|rects|`).
  - D5 completing-read drain-events rewrite (limn:pump returns a COUNT, not a list).
  - D6 v027-init-real reads `*messages*` text instead of nonexistent message/get.
  - D7 v036-narrow widened to [11, 32) so the third foo fits and the test's expected text matches.
  - D8 v027-annotate Ω4 accepts either pixel bbox OR wire-level color tag (Xvfb headless QOpenGLWidget often has no real GL surface).
  - D9 v036-narrow driver wires limn/excursion + limn/marker text-len vtables (clamp was returning 0 → narrow markers at 0).
  - D10 v027-content-move misplaced `(declare ...)` form moved to head of let body.

### Class-C nix-container shims
  - C2 v027-stress limn-rss prefers /proc, falls back to ps (nix containers ship without ps).
  - C3 v029-init-real used `(loop ... collect X ... finally (when ... (collect Y)))` — COLLECT is a loop CLAUSE, not a function.  Rewrote with explicit accumulator.
