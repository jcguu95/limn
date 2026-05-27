# ISSUES — cross-version backlog of structurally hard fixes

Long-lived backlog for things we know are broken / weak / deferred
but can't / shouldn't fix in the current sprint.  Distinct from:

  - `vNN-bugs.md` — sprint-scoped receipts of bugs **already fixed**
  - `tmp/vNN-backlog.md` — running list during a sprint (transient)
  - `CHANGELOG.org` — release notes, not a tracker
  - `TEST-COVERAGE-TODO.org` — coverage gaps specifically

Use this file for items that:

  - Survive across sprints
  - Have a known workaround shipped (so they're "passing" today)
    OR are documented gaps with no workaround
  - Need an environment / refactor / external dependency to truly close
  - Are easy to forget between sprints

## Entry format

Each entry uses this template:

```
## <ID> — <one-line symptom>

- **Status**: deferred | in progress (vNN) | closed (vNN, <commit>)
- **First noticed**: vNN sprint
- **Symptom**: what's actually broken / weak from the user's view
- **Root cause**: why it can't be fixed quickly, environmental
  constraints, design tensions
- **What shipped (workaround)**: current state — what we do instead
- **What's needed for a true fix**: concrete options + trade-offs
- **Complexity**: rough estimate (hours / days / sprint-sized)
- **Blocked by**: other ISSUES entries this depends on, if any
```

Status values:
  - `deferred` — not currently being worked, has a workaround
  - `in progress (vNN)` — being addressed this sprint
  - `closed (vNN, <commit>)` — keep the entry as receipt; explains
    why a future archaeologist sees a fix instead of the workaround

When closing, leave the entry; just flip status and add the
closing commit hash + one-line resolution note.  This file is a
history, not a todo-list-with-deletes.

## Picking up items

Recommended order is roughly by **cost / payoff ratio**, but
sprints can pull anything.  Each entry's "Complexity" line is
calibrated to help.  When you start one:

  1. Flip Status to `in progress (vNN)`
  2. Reference the entry in the sprint backlog (`tmp/vNN-backlog.md`)
  3. On close: flip Status, add commit hash, leave the rest

---

# Active entries

## I-1 — W05 / B2: GL fragment shader unverifiable in headless Xvfb

- **Status**: deferred
- **First noticed**: v0.38 (B2 in `tmp/v038-backlog.md`); honestly
  audited in v0.39
- **Symptom**: `QOpenGLWidget::grabFramebuffer()` returns null QImage
  (w=0, h=0) in this container.  The production dark-mode path
  (`set_dark_mode` → `opengl_widget->color_mode = Dark` → the
  `dark_mode.fragment` GL shader inverts on paint) cannot have its
  pixel output captured.  W05 verifies the state flips and a
  parallel mupdf+`fz_invert_pixmap` render produces the expected
  luminance — but a silently-broken shader file wouldn't surface
  in any test.
- **Root cause**: container is `Xvfb :99 -screen 0 1280x1024x24` +
  mesa-llvmpipe + `QT_XCB_GL_INTEGRATION=xcb_egl` +
  `LIBGL_ALWAYS_SOFTWARE=1`.  This config initialises QOpenGLWidget
  contexts (the old "Failed to create context" error is gone) but
  the EGL surfaceless backend doesn't materialise a framebuffer
  that `grabFramebuffer()` can read back from.
- **What shipped (workaround)**: three-path capture in
  `cmd_test_grab_window` (commit `3d54fa7`):
    1. Try `grabFramebuffer()` — null in this env, falls through
    2. `LimnMupdf::render_page_with_view_state` (mupdf +
       `fz_invert_pixmap`) — math-equivalent parallel impl
    3. `QWidget::grab()` — chrome-only fallback
  Response surfaces `capture-source` honestly ("mupdf" today).
  Independent assertion on `gl-color-mode` (the
  `PdfViewOpenGLWidget::color_mode` field — what the shader reads)
  catches `set_dark_mode` wiring regressions.
- **What's needed for a true fix**:
  - **(a) Real GLX RGB visual in Xvfb**: `Xvfb +extension GLX
    +render` with proper visual list, drop `xcb_egl`, fall back to
    `xcb_glx`.  Verify with `glxinfo`.  May need a different Xvfb
    or extra mesa GLX bits.
  - **(b) `QOpenGLFramebufferObject` offscreen render**: allocate
    an FBO, bind, re-run paint pipeline against it, `toImage()`.
    Requires a public wrapper around `paintGL` (currently private).
  - **(c) Real X11 (Xephyr or x11vnc-backed nested server)**:
    heavier CI/harness change.
- **Complexity**: (a) 2–4 hr if Xvfb cooperates / (b) 4–8 hr / (c)
  nontrivial harness work
- **Blocked by**: —

## I-2 — W16: CJK can't be delivered via X11 keystroke in Xvfb

- **Status**: deferred
- **First noticed**: v0.38 dogfood spec; honestly audited in v0.39
- **Symptom**: `xdotool type "新增中文段落"` fails with
  `xdo_enter_text_window reported an error / Invalid multi-byte
  sequence encountered`.  No path to get CJK keypress events into
  Qt via xdotool in this container.  Real users with fcitx5 / IBus
  on a proper X11 display would work; the test environment
  doesn't.
- **Root cause**: xdotool generates X11 events via XTEST +
  temporary keysym rebinds.  CJK glyphs don't have static X11
  keysyms; xdotool's dynamic bind needs an xkb keymap range that
  Xvfb's default doesn't include.  On a real display with fcitx5,
  the daemon intercepts the keystroke and substitutes a Qt
  `QInputMethodEvent` directly.
- **What shipped (workaround)**: W16 driver calls
  `test/inject-ime-commit` (test wire cmd).  As of commit
  `3d54fa7` that cmd **delegates to the production
  `handle_ime_event`** — the same C++ function `LimnInputFilter`
  calls when a real `QEvent::InputMethod` arrives from fcitx5.
  Test exercises the exact code path a real IME would hit; only
  the X11 → Qt input-method delivery layer is skipped.
  - Bonus: this audit found a real production bug — pre-v0.39,
    `handle_ime_event` didn't insert into text-engine buffers at
    all (only minibuffer).  Real users genuinely couldn't type
    CJK into a .org / .txt file even with fcitx5 working.  Now
    fixed.
- **What's needed for a true fix**:
  - **(a) `QCoreApplication::postEvent` a real `QInputMethodEvent`**:
    in `cmd_test_inject_ime_commit`, construct a `QInputMethodEvent`,
    post to `main_widget` / `text_widget`.  Qt event loop delivers
    to `inputMethodEvent`, `LimnInputFilter` intercepts, routes to
    `handle_ime_event`.  Adds the Qt input-method dispatch layer
    to the tested chain.
  - **(b) Spin up fcitx5 daemon + xdotool drives pinyin
    composition**: full end-to-end "user types pinyin → fcitx
    composes → commits".  Env is already prepped (fcitx5 in
    dockerExtras, `QT_IM_MODULE=fcitx5` in container-entry.sh)
    but no test currently drives it.
- **Complexity**: (a) 1–2 hr / (b) 4–8 hr
- **Blocked by**: —

## I-3 — W17: keystroke buffer-switching path unverified

- **Status**: deferred
- **First noticed**: v0.39 honest audit
- **Symptom**: W17 verifies cross-buffer kill/yank.  Driver opens A,
  opens B, switches back to A via `(limn/file:find-file *path-a*)`
  (programmatic), kills, switches to B, yanks.  Exercises the
  `buffer/show` wire path but NOT the keystroke-driven gesture
  (`C-x b` → completing-read → pick → switch).
- **Root cause**: None — deliberate test-design choice to avoid
  duplicating completing-read driving (which W04 / W28 / W14/15/20
  already cover).  But cumulatively, no single workflow verifies
  the keystroke-driven `switch-to-buffer` path end-to-end.
- **What shipped (workaround)**:
  - `buffer/show` wire cmd — switches `win->buffer_id` to any
    existing buffer (commit `bed874a`)
  - `*show-buffer-fn*` hook in `limn/file:find-file` (re-opening
    triggers it)
  - `switch-to-buffer` defcommand (M-x discoverable, completing-
    read over buffer/list) — exists but **not bound to a keystroke**
  - W17 driver uses programmatic `find-file` for the switch
- **What's needed for a true fix**:
  - **(a)** Bind `switch-to-buffer` to `C-x b` in
    `limn/default-config:install-defaults` — one line.
  - **(b)** W17 driver replaces `(limn/file:find-file *path-a*)`
    with `xdotool C-x b` → minibuffer → type path → RET.  Verifies
    full keystroke chain + completing-read driving + switch.
- **Complexity**: 1–2 hr total, low risk.  Cheapest item in this
  list.
- **Blocked by**: —

## I-4 — B3: macOS Info.plist focus / accessibility

- **Status**: deferred (per R1' — docker is canonical for e2e)
- **First noticed**: v0.37; reaffirmed at v0.38 wrap
- **Symptom**: macOS host-side e2e tests need manual Accessibility
  + Screen Recording permission grants, and Limn doesn't reliably
  steal focus on launch.  v0.38 hit this on first attempt, pivoted
  to docker (per R1').
- **Root cause**: macOS Info.plist needs proper bundle setup;
  focus-stealing on macOS requires `NSAppTransportSecurity` /
  `LSUIElement` work; Accessibility permissions are per-binary-
  hash so a rebuild blanks them.
- **What shipped (workaround)**: R1' — every dogfood / e2e test
  runs in docker.  macOS is build target only, not test target.
- **What's needed for a true fix**: proper Info.plist + macOS-
  specific launch glue.  Only matters when shipping to non-docker
  users.
- **Complexity**: probably 1–2 days, blocking on macOS-specific
  knowledge
- **Blocked by**: —

## I-5 — B4: macOS focus-steal on launch

- **Status**: deferred (rolled into I-4)
- See I-4.  Same fix surface.

## I-6 — B9: Lisp `*bufs*` and C++ `text_buffers` are independent registries

- **Status**: deferred — partially closed by B10 bridge in v0.39
- **First noticed**: v0.38 dogfood
- **Symptom**: `limn/file:*bufs*` (Lisp hash, fbuf-id → fbuf
  struct) and C++ `text_buffers` (`QHash<QString, GapBuffer>`,
  tid → buffer) are two separate registries that share IDs
  loosely.  `buffer/list` (W20) just unions them.  Operations like
  `save-buffer`, `revert-buffer`, `kill-buffer` fork between text
  and PDF paths through vtables.  Names exist in two
  places that can drift.
- **Root cause**: organic growth — `limn/file` was the original
  Lisp file-buffer abstraction (v0.22); `text_buffers` came from
  the C++ text-engine work (v0.22 §C).  They were never unified
  because the two languages have different ownership models and
  unifying needs a careful boundary contract.
- **What shipped (workaround)**: B10 wire bridge (commit `d0a3701`)
  — `find-file` now triggers `bridge/engine-load engine=text` and
  the two registries stay in sync for the lifetime of an fbuf.
  But they're still independent storage; a buffer killed on one
  side doesn't automatically kill on the other; chrome buffers
  (`*minibuffer*` etc.) exist only in C++.
- **What's needed for a true fix**: a "buffer is X" canonical
  abstraction that both sides share.  Likely: Lisp owns the
  metadata (path, modified-p, mode); C++ owns the byte storage
  (GapBuffer); explicit bridge ops for every lifecycle event.
- **Complexity**: sprint-sized refactor.  Consider when a third
  engine (epub native, image viewer?) is on the horizon — at that
  point the cost of NOT unifying jumps.
- **Blocked by**: —

---

# Closed entries (kept for receipt)

(none yet — entries flip Status to `closed (vNN, <commit>)` and
stay below this line.)
