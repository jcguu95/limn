# v0.39 — deferred honesty gaps (for future sessions)

v0.39 ended at 30/30 PASS, 106/106 assertions.  Every dogfood
workflow exercises real production code.  But there are **three
deferred honesty gaps** where the test is structurally weaker than
"a real user on a real display" would prove.  Each is documented
below with:

  - **symptom** — what the test currently can't actually verify
  - **root cause** — why it can't, in this env
  - **what shipped** — the closest-honest workaround
  - **what's needed** — concrete steps to close the gap
  - **complexity** — rough estimate of effort

When picking next-sprint items, these are the strongest candidates
for "make the test rigour match the dogfood spec rigour".

---

## Gap 1: W05 / B2 — GL fragment shader can't be exercised in Xvfb

### Symptom
`QOpenGLWidget::grabFramebuffer()` returns a null QImage (w=0,
h=0) in this container.  The production dark-mode path (`set_dark_
mode` → `opengl_widget->color_mode = Dark` → `dark_mode.fragment`
shader inverts on paint) cannot have its pixel output captured.

### Root cause
Container is `Xvfb :99 -screen 0 1280x1024x24` with mesa-llvmpipe
+ `QT_XCB_GL_INTEGRATION=xcb_egl` + `LIBGL_ALWAYS_SOFTWARE=1`.  This
configuration gets QOpenGLWidget contexts to *initialise* (the
"Failed to create context" error from earlier sprints is gone), but
the EGL surfaceless backend doesn't materialise a framebuffer that
`grabFramebuffer()` can read back from.  Confirmed by debug
fprintf: `gl_img null or too small (null=1 w=0 h=0)` on every call.

### What shipped (`bed874a` + `3d54fa7`)
Three-path capture in `cmd_test_grab_window`:

  1. Try `grabFramebuffer()` — null in this env, falls through.
  2. `LimnMupdf::render_page_with_view_state` — re-renders via
     mupdf with `fz_invert_pixmap` for dark mode.  Mathematically
     equivalent to the GL shader (`1.0 - color`) but a **parallel
     implementation** — a broken shader file wouldn't surface
     here.
  3. `QWidget::grab()` — chrome-only fallback for the no-doc case.

Response surfaces `capture-source` so the test sees which path
actually ran (`mupdf` in this env).  W05 driver also asserts on
`gl-color-mode` (the `PdfViewOpenGLWidget::color_mode` field — the
production state slot the shader reads) so a regression in
`set_dark_mode → color_mode` wiring is caught even without the
shader pixel evidence.

### What's needed for a true fix
Either:

(a) **Real GLX RGB visual in Xvfb.**  Use `Xvfb +extension GLX
    +render` with a proper RGB visual, drop `QT_XCB_GL_INTEGRATION=
    xcb_egl`, fall back to `xcb_glx`.  Mesa's swrast should then
    paint into the framebuffer and `grabFramebuffer()` works.
    Complications: GLX module in nixpkgs Xvfb may not ship the
    required visual list; need to verify with `glxinfo`.

(b) **Use `QOpenGLFramebufferObject` for an offscreen render
    pass.**  Allocate an FBO in `cmd_test_grab_window`, bind it,
    re-run the paint pipeline (`opengl_widget->paintGL()` against
    the FBO), then `toImage()` on the FBO.  Bypasses the
    framebuffer-not-materialised problem because we own the FBO.
    Complications: paintGL is private; need a public wrapper.
    Also `paintGL` reads from `main_document_view` state — should
    work but needs testing.

(c) **Run e2e against a real X11 display (`Xephyr` or x11vnc-
    backed nested server).**  Heavier, but gets real GLX.

### Complexity
- (a): 2-4 hours, depends on whether Xvfb GLX cooperates
- (b): 4-8 hours, requires Qt-internals research + paintGL refactor
- (c): nontrivial CI/test-harness changes; not in scope normally

### Test rigour today vs ideal
- Today: state setter wired correctly + parallel render math correct
- Ideal: production shader pixels match expected dark inversion

If `dark_mode.fragment` is silently changed to something incorrect
(e.g. `gl_FragColor = texColor` with no inversion), W05 still
passes.  This is the residual weakness.

---

## Gap 2: W16 — CJK can't be delivered via X11 keystroke in Xvfb

### Symptom
`xdotool type "新增中文段落"` fails with `xdo_enter_text_window
reported an error / Invalid multi-byte sequence encountered`.
There is no path to get a CJK keypress event into Qt via xdotool
in this container.

### Root cause
xdotool generates X11 events via XTEST / XSendKeyEvent + temporary
keysym rebinds.  CJK glyphs don't have static X11 keysyms; xdotool
tries to bind one dynamically.  Xvfb's default xkb keymap doesn't
include the Unicode keysym range that xdotool would temporarily
use, so the bind fails.  On a real X11 display with a proper
keymap (or fcitx5 daemon catching the keystroke and substituting
its own QInputMethodEvent) this works.

### What shipped (`3d54fa7`)
Driver uses `test/inject-ime-commit` (existing test wire cmd) with
CJK text.  As of `3d54fa7` that cmd **DELEGATES to the production
`handle_ime_event`** — the same C++ function `LimnInputFilter`
calls when a real `QEvent::InputMethod` arrives from fcitx5.  So
the test exercises the exact code path a real IME would hit, just
without going through X11 → Qt's input-method event delivery layer.

### What's needed for a true fix
Need actual `QInputMethodEvent` delivery to test the Qt input layer.
Two routes:

(a) **`QCoreApplication::postEvent` injecting a real
    QInputMethodEvent.**  In `cmd_test_inject_ime_commit`,
    construct a `QInputMethodEvent(text, QList<Attribute>())`,
    post it to `main_widget` (or `text_widget`).  Qt's event loop
    delivers it to `inputMethodEvent`, which `LimnInputFilter`
    intercepts and routes to `handle_ime_event`.  Exercises the
    full Qt event pipeline minus X11.

(b) **Spin up fcitx5 daemon + use xdotool to drive pinyin
    composition.**  Real end-to-end test of "user types pinyin →
    fcitx composes → commits".  Requires fcitx5-im running in the
    container, proper DBUS / socket plumbing, and a known pinyin
    sequence for the target text.  Already env-supported (Dockerfile
    has fcitx5 deps + container-entry.sh sets `QT_IM_MODULE=fcitx5`),
    but no test currently drives it.

### Complexity
- (a): 1-2 hours.  Cleanest incremental upgrade — switches from
       "call C++ handler directly" to "post Qt event, let Qt
       dispatch".
- (b): 4-8 hours.  Full IME stack test.  Closer to user reality
       but more moving parts (fcitx daemon, DBUS, pinyin tables).

### Test rigour today vs ideal
- Today: C++ handle_ime_event correctly inserts CJK into focused
  text buffer + saves UTF-8 to disk (verified end-to-end)
- Ideal (a): Above + Qt input pipeline (postEvent → dispatch →
  inputMethodEvent → LimnInputFilter → handle_ime_event)
- Ideal (b): Above + fcitx5 daemon + X11 keystroke composition

The current test catches any regression in the UTF-8 / GapBuffer
/ save chain, plus the just-fixed real production bug where
`handle_ime_event` didn't insert into text buffers.  It does NOT
catch a regression in `LimnInputFilter`'s
`QEvent::InputMethod` interception (if that filter stopped routing
to handle_ime_event, real users would lose IME but the test would
still pass).

---

## Gap 3: W17 — driver switches buffers via find-file, not via keystroke

### Symptom
W17 verifies cross-buffer kill/yank works.  The driver opens A,
opens B, switches back to A (via `(limn/file:find-file *path-a*)`),
kills, switches to B (same way), yanks.  This exercises the
buffer/show wire path but NOT the keystroke-driven user gesture
(`C-x b` → completing-read → pick → switch).

### Root cause
None — this is a deliberate test-design choice.  The keystroke-
driven completing-read path is already covered by W04 (TOC pick),
W28 (M-x command palette), W14/W15/W20 (C-x C-f file pick).
Re-driving completing-read in W17 would duplicate that coverage
without adding signal about cross-buffer kill/yank.

### What shipped (`bed874a`)
- New wire cmd `buffer/show` switches `win->buffer_id` to any
  existing buffer (text or mupdf).
- `*show-buffer-fn*` hook in `limn/file:find-file` triggers it on
  the "already-open" branch.
- `switch-to-buffer` defcommand (M-x discoverable, completing-read
  over buffer/list).  Not bound to a keystroke yet but is
  inspectable / invokable.
- W17 driver uses `find-file` (programmatic) for the switch.

### What's needed for a true fix
Two parts:

(a) **Bind `switch-to-buffer` to `C-x b` in the global keymap.**
    Trivial — one entry in `limn/default-config:install-defaults`.
    Currently we just have C-x C-f and a few others.  The defcommand
    exists; just needs the binding.

(b) **W17 driver uses keystrokes for the switch.**  Replace
    `(limn/file:find-file *path-a*)` with:
       - `xdotool C-x b` → opens minibuffer
       - `xdotool type "<path-a>"` (or partial buf-id) + RET
       - `(sleep 0.5)` for the switch to complete
    Then kill/yank as today.  Verifies the full keystroke chain
    plus completing-read driving.

### Complexity
1-2 hours, low risk.  Mostly driver work — backend already has all
the pieces.

### Test rigour today vs ideal
- Today: cross-buffer kill/yank works via wire-level switching
- Ideal: above + verified that a user typing `C-x b foo<RET>`
  actually switches them

---

## Bonus deferrals (not in v0.39 batch)

These were already noted in v0.38 wrap and remain valid:

- **B3 / B4** — macOS Info.plist / focus issues.  Deferred per R1'
  (docker is canonical for e2e).  Re-visit when there's a need to
  ship to a non-docker user.

- **B9** — Lisp `limn/file::*bufs*` vs C++ `text_buffers`
  namespace split.  Partially closed by B10's bridge (find-file
  → engine-load + show-buffer), but the two registries still live
  independently and `buffer/list` (W20 cmd) just unions them.
  A canonical "buffer is X" abstraction that both sides share
  would let `limn/file:save-buffer` etc. work uniformly across
  text and mupdf buffers without the current vtable forking.

## Picking these up

Recommended order if a future sprint addresses these:

1. **W17 keystroke** — cheapest, biggest dogfood completeness win
2. **W16 (a) postEvent** — cheap, real Qt input-pipeline coverage
3. **W05 (a) Xvfb GLX** — medium, real shader pixel coverage if
   it works
4. **B9 buffer namespace** — bigger refactor; consider when a
   third engine (epub native, image viewer?) is on the horizon

The honest assessment: v0.39 30/30 PASS is real and rigorous up to
these three gaps.  Closing them takes us from "production code
correctly wires together" to "production code AND the X11/Qt/GL
event delivery layer behave correctly".  In the current dogfood
spirit ("does this work on the user's actual machine?"), the gap
narrows to roughly Xvfb-specific environment limits.
