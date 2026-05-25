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
