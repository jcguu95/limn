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

## I-7 — limn_command.cpp 是單體字串 dispatch 鏈，會持續肥大 + 變 merge 衝突熱點

- **Status**: deferred
- **First noticed**: v0.42（narrow/widen merge 撞衝突時觀察到）
- **Symptom**: `sioyek/pdf_viewer/limn_command.cpp` 已 4824 行（全 repo
  第 3 大 .cpp），裡面是一條 ~86 個 handler、~133 行字串比對的
  `if / else if` 長鏈。每新增一個 Lisp-facing 指令就往**同一個函式、同一個
  translation unit、同一段 dispatch 區塊**塞一條 branch。
- **Root cause**: dispatch 用線性字串相等比對寫死在一個 router 函式裡，沒有
  per-feature 的註冊邊界。形狀問題不是行數問題。後果具體三個：
    1. 動一個指令整檔重編（incremental compile 慢）。
    2. 每個 feature 都改同一段 → merge 衝突磁鐵（v0.42 merge 實際撞到）。
    3. 所有 handler 擠在一個 router，難單獨測。
- **What shipped (workaround)**: 無；目前就是手動維護 `if/else` 鏈，靠
  review 擋衝突。
- **What's needed for a true fix**:
  - **(a) 表驅動 dispatch**：`std::unordered_map<std::string, handler_fn>`，
    每個 feature 在自己的檔裡 `register("narrow-to-region", …)`。各 feature
    不再共改同一段 → 衝突熱點消失。
  - **(b) 依領域拆檔**：handler 拆成 `limn_command_text/window/pdf.cpp`，
    `limn_command.cpp` 退回只當 router + registry。
  - **(c)** 註冊表讓 handler 可被獨立單測（給 mock context 呼叫單一 handler）。
- **Complexity**: 註冊表化骨架 0.5–1 天；逐步搬 handler 可漸進、不必一次。
  建議「下次再碰 dispatch 時順手轉」，不必為它單開 sprint。
- **Blocked by**: —

## I-8 — 前端渲染驗證仍靠人眼 per-merge，缺自動回歸網

- **Status**: deferred
- **First noticed**: v0.42（每個 feature 都用人工互動 walkthrough 驗收）
- **Symptom**: unit / integration test 測不到「畫面渲染對不對」。目前每個
  碰前端的 feature 都靠使用者跑互動 walkthrough script、用眼睛逐步比對。
  沒有自動網 → merge 進來破壞了哪個視覺功能，CI 不會抓到。
- **Root cause**: 部分驗證（感知品質：anti-alias、字型 hinting、好不好看）
  本質需要人眼；但**大量「有沒有渲染對」其實可降級成可程式斷言**，只是目前
  沒把 rendered state 暴露成可查詢，也沒把 walkthrough 的可驗步驟升級進 CI。
- **What shipped (workaround)**: `scratch/<feature>-walkthrough.lisp` 互動
  腳本（注入 form + 印「預期看到什麼」+ 問 y/n/c/a）。人機介面已成形，但
  pass/fail 仍是人按出來的，非 CI。
- **What's needed for a true fix**（由便宜到貴的階梯）:
  - **(a) 加 query 指令暴露 rendered state**（modeline 文字、可見 buffer
    切片、pane 幾何、focus）。最便宜、回報最大：把多數 walkthrough 步驟從
    「看一眼」變「問一句 + assert」，搬進 headless CI。
  - **(b) 把每支 walkthrough 可機器驗的步驟升級進 integration suite**，
    每次 merge 在 CI 跑（walkthrough 是 regression test 的胚胎，非用過即丟）。
  - **(c) golden-image / 快照測試**：離屏 render → PNG → 對 commit 的黃金圖
    做容差 pixel diff，專打 overlay / face / icon 這種純像素。人只在「本來
    就要改外觀」時批准一次新黃金圖。代價：對字型/平台敏感，需釘死單一
    容器化 runner（與 I-1 的 headless GL 限制相關）。
  - **(d) 留短的 per-release 人工 checklist** 顧感知品質；該處才允許用
    Opus 視覺當*助手*（非 CI gate——非確定性、不可究責）。
  - 目標：從「每次 merge 要人眼」搬到「只有每次 release 要人眼、且只看一張
    短 checklist，平時有 golden-diff 擋非預期變化」。
- **Complexity**: (a) 每個 query 指令 1–2 hr，漸進 / (b) 隨 (a) 一起 /
  (c) 初版 offscreen-render + diff harness 數天，且卡 I-1 的 headless GL /
  (d) 純流程，低成本
- **Blocked by**: 部分卡 **I-1**（headless 環境 `grabFramebuffer()` 拿不到
  framebuffer，golden-image 路線需先解 GL 離屏 render）

---

# Closed entries (kept for receipt)

(none yet — entries flip Status to `closed (vNN, <commit>)` and
stay below this line.)
