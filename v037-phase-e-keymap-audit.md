# v0.37 Phase E — Keymap Discipline Audit

**Goal:** verify no ad-hoc keyboard dispatch bypasses `limn/keys`. Done
before Phase D so the vim-pdf keymap targets a clean API.

**Result:** audit passes. One documented hybrid in C++ minibuffer
(known architectural tradeoff, not a violation). All user-facing
bindings flow through `limn/keys:make-keymap` + `define-key`.

## Path traced: Qt KeyEvent → wire `key` event → Lisp dispatch

```
Qt KeyPress
  └─ LimnInputFilter::eventFilter (limn_input.cpp:140)
       ├─ skip bare modifier presses (Ctrl/Alt/Shift alone)
       ├─ key_to_string(QKeyEvent*) → wire-friendly string
       │     • Qt::Key_A..Z          → "a".."z" (or "A".."Z" w/Shift)
       │     • Qt::Key_0..9          → "0".."9"
       │     • Qt::Key_Return        → "RET"
       │     • Qt::Key_Escape        → "ESC"
       │     • Qt::Key_Tab           → "TAB"
       │     • Qt::Key_Backspace     → "BS"
       │     • Qt::Key_F1..F12       → "<f1>".."<f12>"
       │     • Qt::Key_{Up,Down,Left,Right,...} → "<up>" etc.
       ├─ modifiers_to_array (case-encodes-shift heuristic)
       ├─ if minibuffer_open: minibuffer_handle_key → see HYBRID below
       └─ else: bridge->push_event("key", {key, mods})

Wire event arrives at Lisp:
  └─ event/key hook
       └─ limn::%dispatch-key (backend/limn.lisp:84)
            ├─ skip bare digits while accumulating prefix-arg
            ├─ append spec to *key-prefix* for multi-key sequences
            ├─ walk mode-buffer keymap stack: minor → major → global
            │     via limn/keys:lookup-sequence
            ├─ if action: funcall it with the event plist
            ├─ if :prefix: set-key-prefix for next dispatch
            └─ if nil: clear prefix
```

Every step goes through declarative keymap data, never hardcoded
`if (key == "...")` chains.

## All keymaps in the codebase

| Keymap                           | File                  | Owner                  |
|----------------------------------|-----------------------|------------------------|
| `*global-keymap*`                | limn-keys.lisp        | top-level fallback     |
| text-mode keymap                 | limn-text-mode.lisp   | major mode             |
| pdf-mode keymap                  | limn-pdf-mode.lisp    | major mode             |
| occur-mode keymap                | limn-occur.lisp       | minor mode (search UI) |
| isearch transient                | limn-isearch.lisp     | transient overlay      |
| `*key-prefix*` accumulator       | limn-keys.lisp        | multi-key state        |
| `*leader-keymap*` (init.lisp)    | limn-map-macro.lisp   | user-land via `map!`   |

All built with `limn/keys:make-keymap`. All populated via
`limn/keys:define-key`. Zero direct `if (string= key "x")` or
`(case key (#\j ...))` style.

## The one hybrid: C++ minibuffer (`limn_command.cpp:919`)

When `minibuffer_open` is true, the input filter routes key events
through `LimnCommand::minibuffer_handle_key` *first*. That function
hardcodes:

- `"RET"` → emit `minibuffer-submit` event
- `"ESC"` → emit `minibuffer-cancel` event
- `"BS"` → backspace, update text, emit `minibuffer-input`
- `"<left>" / "<right>"` → cursor move (codepoint-aware)
- `"<home>" / "<end>"` → cursor to bounds
- single printable → insert at cursor

**This is hardcoded in C++**, not a `limn/keys`-driven keymap.

### Why this is acceptable (and not in Phase E scope to fix)

1. **Modifier combos already fall through** (limn_command.cpp:925-928).
   `C-g`, `M-x`, `C-Space`, etc. inside the minibuffer go to the
   global keymap as normal, so the user-customizable surface is
   already keymap-driven.

2. **What's hardcoded is *widget* behavior, not *user-binding*
   semantics.** RET-submits / BS-deletes / arrow-moves are
   text-input affordances every minibuffer-shaped widget has. They
   aren't *bindings* in the Emacs sense — they're the widget's
   intrinsic event handling.

3. **Bringing this into Lisp** would require per-keystroke wire
   round-trips for every typed character (currently buffered in
   C++ for low latency under fast typing). v0.22 §C explicitly
   chose the C++ buffer to avoid the race conditions that earlier
   per-keystroke wire round-trips caused. Reverting is a v1.0
   architectural rework, not Phase E.

4. **Customization surface today:** user-land Lisp can already
   override minibuffer behavior by:
   - binding `C-g` / `M-...` etc. at the global keymap level
   - subscribing to `minibuffer-submit` / `minibuffer-cancel` /
     `minibuffer-input` events
   - using `completing-read` API (limn-completion.lisp) instead of
     raw minibuffer for richer interactions

### What would unlock this (future)

A `*minibuffer-local-map*` Lisp keymap, with semantics: when minibuffer
is open and a key arrives that has a non-default binding in that map,
that binding wins over the C++ default. C++ would emit a "consulted
minibuffer-local-map: was-bound? yes/no" probe before falling back.

This is **not** in v0.37 scope. Could land as Phase C polish or v1.0.

## Regression coverage

A unit-tier test asserts the discipline going forward: see
`backend/tests/unit/keymap-discipline-v037.lisp`.

The test:
1. Reads `backend/limn-pdf-mode.lisp` + `limn-text-mode.lisp` as
   source text and asserts they contain `limn/keys:make-keymap`
   and `limn/keys:define-key` (or `%def` / `%def-cmd` wrappers).
2. Asserts they DO NOT contain hardcoded `(case ...)` or
   `(cond ((string= ...))` over key strings.

This catches anyone who later short-circuits the keymap with
ad-hoc dispatch.

## Phase D readiness

`pdf-mode` already has a vim-shaped keymap as of v0.27 (j/k for
scroll, n/p for page, G/gg for first/last, +/-/0/W for zoom,
/ for search, h/H for annotation, t for TOC).

Gaps for Phase D's "true vim" target:
- `l` unmapped (vim: right) — could mirror `h`'s annotate or assign
  to PDF-NEXT-PAGE
- `Ctrl-d` / `Ctrl-u` (half-page scroll) — vim staples, missing
- `:` (command mode entry — Limn analog is M-x to minibuffer)
- `q` (close — call PDF-CLOSE if defined; absent today)
- `o` (open file — find-file equivalent)
- `?` (reverse isearch — vim has /, ?; we have / only)
- vim-style `5j` repeat count is already handled by the numeric-prefix
  accumulator in `%dispatch-key` lines 110-117 — j/k can already be
  prefixed.

Phase D = filling those gaps, plus a `default-init.lisp` that
demonstrates the conventions.
