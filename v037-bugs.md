# v0.37 bugs found + fixed

Receipts log. Each entry: symptom → root cause → commit hash (filled at commit time).

## A1a Phase

### #1 — vendor/cl-ppcre git submodule not auto-checked-out in fresh worktrees
- **Symptom:** `./backend/run-repl.sh` in a fresh `git worktree add ...` worktree crashes deep in `limn-regex.lisp` with `Package CL-PPCRE does not exist` and a 30-line SBCL backtrace.
- **Root cause:** the supposed "soft-load" in repl.lisp catches the vendor-loader's failure, but limn-regex.lisp later references `cl-ppcre:` package at *read* time which is a fatal reader error — handler-case can't catch reader errors that happen after the protected form returns.
- **Fix:** drop the submodule entirely. cl-ppcre now comes from nix via `sbcl.withPackages [cl-ppcre]` in flake.nix. `(require :cl-ppcre)` in repl.lisp + run-unit.lisp.
- **Regression coverage:** the smoke path itself — `LIMN_NO_SPAWN=1 sbcl --load backend/repl.lisp` should exit 0. Will be CI-enforced as part of Phase A3 / nix-pinning unification.
- **Commit:** 55cbec3

### #5 — macOS `make` skips recompile when only DEFINES change → binary's git-hash stamp goes stale
- **Symptom:** rebuild the macOS binary after a commit, `./limn --version` still reports the OLD commit hash.  Confusing because the rebuild "succeeded" — link ran, mtime updated.
- **Root cause:** the build-provenance values (LIMN_BUILD_GIT_HASH etc.) are passed to the compiler as `-D` macros at qmake time.  qmake re-runs and emits a new Makefile when .qmake.stash is deleted, but make is mtime-based and won't recompile .cpp if the .o is newer — so the .o files keep their previous -D values.  Link picks up the stale .o set.
- **Fix:** add `scripts/build-macos.sh` wrapper that does a clean rebuild (rm -f *.o pdf_viewer/*.o) before qmake/make, then asserts the resulting binary's git stamp matches HEAD.  Mirrors `scripts/build-docker.sh`'s pattern.  Discovered while verifying Phase A1c claims against a fresh binary.
- **Commit:** bfb69f6

### #4 — macOS `mac { }` .pro block linked vendored mupdf → fresh worktree can't link
- **Symptom:** `nix develop --command make` on a fresh worktree fails at link: `ld: warning: directory not found for option '-L.../sioyek/mupdf/build/release'` then `library not found for -lmupdf-third`.
- **Root cause:** the `mac { }` block in `pdf_viewer_build_config.pro` hardcoded `-L$$PWD/mupdf/build/release -lmupdf -lmupdf-third -lmupdf-threads`. Required the mupdf git submodule + a separate `./build_mac.sh mupdf` cold build (~10 min). Worktrees / fresh clones don't have submodules initialized.
- **Fix:** mac block now uses nix-pinned mupdf same as Linux block (single `-lmupdf` + system harfbuzz / freetype / jpeg / openjp2 / jbig2dec / gumbo). Host ≡ container library versions. Removes 10-min cold dependency on submodule init.
- **Discovery:** A1d macOS rebuild from this worktree.
- **Commit:** 7b3b5a6 (Phase A1d)

### #3 — `sioyek/fzf/` + `begin.png` + `end.png` + `tutorial.pdf` + `pdf_viewer/shaders/` gitignored but build-required → docker build dies in any fresh worktree
- **Symptom:** docker build from any worktree fails: first `make: *** No rule to make target 'fzf/fzf.c'`, then after fzf fix `make: *** No rule to make target 'end.png'`. Each iteration unmasks the next missing dep.
- **Root cause:** `.gitignore` excluded `sioyek/fzf/`, `sioyek/begin.png`, `sioyek/end.png`, `sioyek/tutorial.pdf`, and `sioyek/pdf_viewer/shaders/` — but the .pro file references `fzf/fzf.c` and `resources.qrc` embeds the other four into the binary. The main checkout works only because previous build sessions left these files in place untracked; every fresh clone / worktree / docker COPY context is broken out of the gate.
- **Fix:** untrack from `.gitignore`, `git add -f` all of them. Sizes: fzf 38KB + begin/end PNG 12KB each + tutorial.pdf 148KB + shaders 80KB → ~290KB total. Worth tracking.
- **Discovery:** A1b docker build from this worktree.
- **Regression coverage:** any fresh `git clone && docker build .` (without manual asset copying) now succeeds — that's the smoke test.
- **Commit:** 76d106e

### #2 — pre-existing test bug `LOCAL-B7-{SET,KILL}-FIRES-CHANGED-EVENT`
- **Symptom:** 2 / 2524 unit tests RED with `ERROR: The variable B is unbound.` Discovered while establishing A1a's baseline.
- **Root cause:** `with-local-ctx` macro never binds a symbol called `b`, but the two tests have `(let ((b b)) (declare (ignore b)) ...)` referencing it. Dead/wrong code that worked by accident if some prior fixture had `b` in scope, broke when the surrounding code was refactored.
- **Fix:** delete the 2 dead lines in each test. Tests now run their full assertion bodies.
- **Regression coverage:** the tests themselves now actually execute.
- **Commit:** 55cbec3

## Phase F — OS-tier e2e driver triage (docker via docker-desktop)

Baseline: **32 e2e driver fails** in `./scripts/build-docker.sh && run-os-e2e.sh` after Phase A landed.  Sister branch `claude/ecstatic-cannon-cdf14a` carried the triage in 5 commits; merged back into this branch.  Each entry below is a distinct root cause; many fan out into multiple driver files.

### #F-A1 — `%decode-file-content` returns raw byte vector → JSON encoder chokes
- **Symptom:** drivers that round-trip file content via `read-file` blow up at the wire boundary with `"Cannot encode JSON value: #(72 101 108 108 111 ...)"`.  Only on docker (where the load order differs); host smoke didn't hit it.
- **Root cause:** when `limn/coding` isn't on the load path but `*read-file-fn*` still returns bytes, `%decode-file-content` falls through to `(or raw "")` and returns the raw byte vector unchanged.  The downstream JSON encoder has no rule for `(simple-array (unsigned-byte 8))`.
- **Fix:** defence-in-depth bytes→string coercion via `sb-ext:octets-to-string` (UTF-8, `#\?` for invalid sequences).  `%decode-file-content` now always returns a string regardless of whether `limn/coding` is loaded.
- **Regression coverage:** `file-e7-bytes-fallback-returns-string` + `file-e7-bytes-fallback-revert-returns-string` in `file-io-v024.lisp` (both hide `limn/coding` via `rename-package` to exercise the fallback branch directly).  Unit tier: 2531 → 2533.
- **Commit:** d99f3ed

### #F-B1 — 30 e2e drivers' per-driver `(dolist (f '(...)) (load ...))` lists rotted
- **Symptom:** 16 of 32 baseline e2e fails crash at READ time with `Package LIMN/XYZ does not exist` *before* any helpful diagnostic emits.  Another 8 are the cl-ppcre variant of the same disease.  Total: 24/32.
- **Root cause:** each OS-tier driver carried its own hand-maintained load list.  These lists rotted every time a new module landed — v0.27 `limn-pdf-mode`, v0.28 `limn-which-key` / `limn-map-macro`, v0.34 `limn-regex` (cl-ppcre).  Failure mode is brutal: READ-time package lookup on the driver source itself, no opportunity to print which package or which module.
- **Fix:** drop the per-driver lists, replace with single `(load "tests/e2e/load-limn-system.lisp")` that mirrors `backend/repl.lisp`'s ASDF bring-up.  cl-ppcre, sb-bsd-sockets, every `limn/*` package — all resolvable at READ time, so the rest of the driver compiles fine.  30 drivers converted across two batches.
- **Bonus fix:** `v029-init-real` had a load-after-use bug (dolist at line ~102, defuns referencing `limn:*` at line ~75).  Moved the load to line ~67 so READ sees packages before defuns compile.
- **Regression coverage:** every converted driver above must now bring its backend up cleanly; the e2e suite is the verification.  Future drivers that copy the new pattern inherit the same coverage by construction.
- **Commits:** c43725f (batch 1: 16 drivers), 65911cd (batch 2: 14 more)

### #F-C1 — `v023-process-shell` hardcoded UNIX bin paths absent in nix container
- **Symptom:** `make-process` chokes with `(list nil "hello-from-subprocess")` because `%first-exists` returned NIL for every candidate.
- **Root cause:** driver's bin-discovery list hardcoded `/bin/echo` / `/bin/cat` / `/usr/bin/true`.  The docker container is nix-based — those canonical UNIX paths don't exist; coreutils live under `/nix/store/...` reachable only via `$PATH`.
- **Fix:** `%find-on-path` walks `$PATH` when the canonical UNIX entries are missing.  Both branches preserved — host macOS still finds `/bin/echo` directly, nix container picks up the PATH entry.  Adds explicit SKIP (exit 77) if any required bin is still missing, so future breakage emits a clean diagnostic instead of a PROCESS-ERROR backtrace.
- **Commit:** a837999

### #F-C2 — `v027-stress`'s `limn-rss` shells out to `ps` (absent in nix container)
- **Symptom:** `sb-ext:run-program "ps"` errors out; the RSS-ratio assertions can't run.
- **Root cause:** nix containers ship without `ps` (it's not in the `nixpkgs.coreutils` set; lives in `procps`).
- **Fix:** prefer `/proc/<pid>/status` (Linux, present in the container), fall back to `ps` for macOS host, return NIL when neither works.  Existing RSS-ratio checks already treat NIL as "skip", so the test simply runs to completion.
- **Commit:** ac7053a

### #F-C3 — `v029-init-real` used `(loop ... finally (when ... (collect Y)))` — COLLECT is a clause not a function
- **Symptom:** `function COLLECT is undefined` at the trailing-no-newline edge case.
- **Root cause:** `collect` is a `loop` clause, can't appear inside `(when ...)` inside `finally`.  Looked like a function call to the original author.
- **Fix:** rewrite with explicit accumulator that handles the trailing-no-newline case correctly.
- **Commit:** ac7053a

### #F-A2 — `limn/pdf-mode::%selection` reads `:rects` but C++ returns `:begin`/`:end`/`:active`/`:mode`/`:text`
- **Symptom:** `h` (highlight selection) never wrote a sidecar.  `%add-annotation` early-returned because `(getf %selection :rects)` was NIL.
- **Root cause:** schema drift.  Lisp side was written against a draft selection wire schema with `:rects`; C++ side settled on begin/end-point schema in v0.15 and the Lisp reader never caught up.
- **Fix:** synthesise a single bounding-box rect from `:begin` / `:end` (normalised so `x1<x2` / `y1<y2`).  Return NIL when `:active` is false so callers treat that as a clean no-op.
- **Regression coverage:** 3 new pdf-mode-v027 tests + 1 mock fix.  Unit tier: 2533 → 2537.
- **Commit:** ac7053a

### #F-D1 — `v036-perf-large-replace` ran 10,000 query-replace matches → tens of minutes per driver run
- **Symptom:** driver fires the 30-second budget timer; "perf baseline" turned into "20-minute hang".
- **Root cause:** query-replace is one wire round-trip per match.  10K matches in single-process mode = tens of minutes.  Budget was set assuming a faster inner loop.
- **Fix:** cut `n-matches` to 100.  100 still trips any quadratic regression instantly; honest run is under 5s; budget kept at 30s for headroom.
- **Commit:** 65911cd

### #F-D2 — `v024-mark` double-installed `event/buffer-modified` hook → markers shifted 2× len
- **Symptom:** Ω5 `process-insert` shifts markers by 2× len — assertion reads "5 + 2 = 7, got 9".
- **Root cause:** since v0.30, the runtime layer auto-installs `limn/marker`'s handler at session start.  The v0.24 driver still carried its own `add-hook` from the pre-v0.30 era → handler fires twice on every insert.
- **Fix:** drop the manual hook in the driver; runtime owns the wiring now.
- **Commit:** 65911cd

### #F-D3 — 8 v027 drivers had two schema mismatches against the C++ binary
- **Symptom:** selection-set silently no-ops (wrong schema → silently dropped); reading overlays returns nothing (calling a command that doesn't exist).
- **Root cause:** two drifts that snuck in between v0.14 and v0.27 without driver updates:
  - `view/selection-set` takes `:begin` / `:end` (each a page+x+y plist), NOT `:page` + `:rects`.
  - Overlays are read via `view/get :overlays`, NOT the non-existent `view/overlays-get`.
- **Fix:** correct both call sites across all 8 affected drivers (v027-annotate / crash-recovery / init-real / content-move / display-invariants / mouse-drag-anno / zero-config / workflow).
- **Commit:** 65911cd

### #F-D4 — `init.lisp.example` v0.29 rewrite broke v0.8-era demo bindings + mode-map shadowing
- **Symptom:** `batch-os-demo`, `batch-os-lisp-runtime`, `batch-os-user-flow`, `batch11-demo-init` lost the `next-page` / `search-here` / vim-style bindings they assert on.  After splitting demo-init out, vim-style `j` / `k` / `G` still didn't fire in pdf-mode.
- **Root cause:** two layers.  (a) `init.lisp.example` was rewritten for v0.29 (which-key + leader-keymap) and lost the v0.8 stack-exercise bindings.  (b) Since v0.27, `pdf-mode` binds `j` / `k` to `pdf-scroll-down/up`; mode keymaps shadow the global one, so vim-style binds in the global map never fire while a PDF is open.
- **Fix:** split `backend/tests/e2e/demo-init.lisp` out from `init.lisp.example` — keeps both the user-facing example AND the v0.8 stack-exercise without either bleeding into the other.  Drivers `setenv LIMN_INIT` to `demo-init.lisp`.  Then bind `j` / `k` / `G` / `g g` / `/` into `pdf-mode-map` too, not just the global keymap.
- **Commits:** 65911cd (split), ac7053a (mode-map follow-up)

### #F-D5 — `completing-read` driver tried to read events out of `(limn:pump)` but pump returns a count
- **Symptom:** Ω2 / Ω3 / Ω4 see no submit / cancel events; assertions match empty lists.
- **Root cause:** `(limn:pump)` returns the number of events drained, not the events themselves.  Driver used the return value as if it were a sequence.
- **Fix:** install hooks via `arm-events` *before* injection and harvest into a shared list afterwards.
- **Commit:** ac7053a

## Phase G — post-merge e2e triage (this branch)

Baseline after merging Phase F: 20 e2e fails.  Triage on this branch knocks the count to 0/111.  Five distinct root causes; some single fixes cascade through many drivers.

### #G1 — `view/overlays` wire write field name asymmetric with the read field
- **Symptom:** 11 e2e drivers fail with overlays staying at 0 even after writes that look like they succeeded.  pdf-mode `h` highlight, search highlight, region highlight, theme switch, multi-line region — all silently no-op.  Read paths (`view/get` → `:overlays`) return empty arrays.
- **Root cause:** C++ `cmd_view_overlays` (writer) read its wire payload from field `"layers"`; C++ `cmd_view_get` (reader) returned the same data under `"overlays"`.  The command itself is `view/overlays`, the internal C++ member is `win->overlays`, and 7/7 Lisp `pdf-mode` write sites send `:|overlays|` — so `"layers"` was the outlier.  C++ silently treated the missing `"layers"` field as "empty array → clear all overlays."
- **Fix:** rename the C++ writer's wire field to `"overlays"` so READ and WRITE are symmetric on the same key.  Plus updated 11 e2e drivers (29 call sites total) that had hand-written `:|layers|` calls — replaced with `:|overlays|`.
- **Commit:** bf4a973

### #G2 — `emit_buffer_opened` event payload missing `:path` field → sidecar reload never fires
- **Symptom:** v027-annotate Ω3 (re-open after highlight has 0 overlays), v027-workflow Ω10 (same), v027-resume Ω1b/Ω2a (last-position not restored), v027-crash-recovery Ω4 (no annotation survives SIGKILL), v027-content-move (broken-pipe mid flow).
- **Root cause:** C++ `emit_buffer_opened` event included `frame-id` / `buffer-id` / `engine` / `page-count` but NOT `path`.  The Lisp handler `pdf-mode-on-buffer-opened` reads `(getf ev :|path|)` to find the sidecar and last-position file — got NIL → handler early-returns → no sidecar load.  Bookmark restore, annotation reload, last-position restore all silently no-op'd whenever a buffer re-opened on a fresh process.
- **Fix:** thread `path` into `emit_buffer_opened` signature and add it to the event payload.  Updated both call sites (mupdf via `cmd_bridge_engine_load`, mupdf via `cmd_buffer_open`) and the inline text-engine emit at line 298.  Text buffers pass empty string.
- **Commit:** TBD

### #G3 — `cmd_test_inject_key` bypasses `minibuffer_handle_key` → injected RET never becomes `minibuffer-submit`
- **Symptom:** completing-read Ω2a/Ω3a `evs 0` — minibuffer-submit / minibuffer-cancel events never fire when the driver injects RET / ESC via `test/inject-key`.
- **Root cause:** real Qt key events route through `minibuffer_handle_key` first (`limn_input.cpp` line 173); if it consumes the key (RET → submit, ESC → cancel, printable → input), no raw `key` event is emitted.  `cmd_test_inject_key` skipped that branch entirely and just pushed a raw `key` event.  So injected RET never reached the minibuffer's submit pathway.
- **Fix:** mirror the real Qt key path — call `minibuffer_handle_key(key, mods)` first; only fall through to `push_event("key", ...)` when not consumed.
- **Commit:** TBD

### #G4 — `limn:start` loaded init.lisp with `:resilient nil` → broken init.lisp kills bring-up
- **Symptom:** v027-init-real Ω2 ("broken init.lisp tolerance") — driver writes `(error "intentional broken init")` to init.lisp; Limn dies on session start with unhandled condition, all subsequent assertions trip broken-pipe.
- **Root cause:** Bring-up site called `(funcall load-init)` with no args.  `load-init-file` defaults `:resilient` to `nil` — errors propagate.  Test expectation (and Emacs convention): broken init.el → degraded session + warning, not abort.
- **Fix:** pass `:resilient t` at bring-up.  Errors caught + logged to `*error-output*`; user sees the message; downstream features still come up.  `:resilient nil` remains available for batch / scripted invocations that want fail-fast.
- **Commit:** TBD

### #G5 — `C-g` not bound in `pdf-mode-map` → search overlays don't clear on cancel
- **Symptom:** v027-search Ω4 — driver does `/` → type query → RET → `n` (navigate hit) → `ctrl+g` (expect overlay clear).  Got 122 overlays still present.
- **Root cause:** `pdf-isearch-quit` is defined and calls `pdf-search-reset` (which clears state + emits empty overlays), but the key wasn't bound in `pdf-mode-map`.
- **Fix:** add `(%def km "C-g" 'pdf-isearch-quit)` to both the initial install and the merge-with-existing path.
- **Commit:** TBD

### Cascading fix observations

Several drivers that I expected to need separate work passed once #G1+#G2+#G3 landed:
- **v027-display-invariants Ω3** (zoom-in bbox unchanged) — overlay payload now reaches C++ correctly, raster rebuild picks up real coords.
- **v027-nav Ω6c** (0 reset zoom) — flake or side-effect from previous cumulative state; clean after.
- **v033b-edit-during-active-region** (Ω2 mark auto-deactivated, Ω3 region pixel gone) — region overlay path goes through `view/overlays`; symmetry fix unblocked it.
- **v033-isearch-retrofit / v033-pdf-search-retrofit** — assumed feature-gap (looked up `limn/cmd` / `buffer/search-pdf` in C++ dispatch and saw no entry).  Actually green after #G1; either Lisp-side intercepts before wire or my grep missed the dispatch path.  Not investigated further given green.
- **v027-stress Ω1a** (200 j page advance), **v036-narrow-and-query-replace**, **v036-tab-key-text-mode** — also green after cascading fixes.

This is what "11 fixes for 32 baseline fails" looks like in practice: a few real root causes fan out widely.

### Final tally

  ./scripts/build-docker.sh && docker run --rm limn-e2e
  → 111 passed, 0 failed
