# split-frame-design.md

Multi-`DocumentView` (per-window) refactor — design + phased plan. Started
in the v0.39.x sprint.

This document is the working contract between the C++ Qt layer (`MainWidget`,
`DocumentView`, `PdfViewOpenGLWidget`, `LimnCommand`, `LimnWindowRegistry`)
and the Lisp side (`backend/limn-pdf-mode.lisp`, `limn-runtime.lisp`) for
turning the existing single-`DocumentView` viewport into a real per-window
multi-`DocumentView` widget tree.

## Background — current state (v0.39.10)

- `MainWidget` owns exactly **one** `DocumentView* document_view_` and
  exactly one user-facing `PdfViewOpenGLWidget* opengl_widget_`. It also
  has a `viewport_splitter_` (`QSplitter`) and an `add_split_pane(orient)`
  method that adds *additional* `PdfViewOpenGLWidget`s to the splitter —
  but those panes **share** the single `DocumentView*`. So `add_split_pane`
  today gives you two viewports of the *same content*; scrolling/zooming
  one affects both.

- `LimnWindowRegistry` already tracks the *logical* multi-window model:
  `LimnWindow` (per-window page/zoom/offset/buffer_id/selection/overlays/
  modeline/frame_id/floats) and `focused_id()` (the active LimnWindow).
  v0.15 already implements **virtual** per-window state by snapshotting
  the live DV's continuous fields (`zoom`, `offset_x`, `offset_y`) into
  the previously-focused `LimnWindow` on `bridge/win-focus`, then
  restoring the target window's snapshot into the same live DV. Page/zoom/
  offset are per-window in the *registry*; but only one window is ever
  *visible at a time* in the OpenGL widget.

- `bridge/win-split` already allocates a new `LimnWindow` and (since v0.8)
  invokes `MainWidget::add_split_pane` — but again, both panes share the
  same DV, so there's no useful split UX yet.

## Audit — `document_view()` (no-arg) call sites in `limn_command.cpp`

`grep -n "document_view()" sioyek/pdf_viewer/limn_command.cpp` produced 11
hits (all in `limn_command.cpp`; the remaining hits in `_main_widget.cpp`
are `helper_document_view()`, an unrelated singleton):

| Line | Caller / context                       | Semantic intent           |
|------|----------------------------------------|---------------------------|
| 345  | `cmd_*` post-open                       | active DV (just opened)   |
| 497  | `cmd_bridge_win_focus` — save drift     | active DV (prev focused)  |
| 639  | `cmd_view_set` — gated `is_active`      | active DV                 |
| 1476 | `cmd_view_selection_get`                | active DV (focused win)   |
| 1590 | `cmd_view_scroll` — gated `is_active`   | active DV                 |
| 1699 | `buffer/open` — register doc            | singleton (load fresh)    |
| 1867 | text↔pdf switch — re-attach             | active DV                 |
| 2389 | `cmd_view_get` — gated `is_active`      | active DV                 |
| 3200 | `rebuild_overlay_raster`                | focused DV                |
| 3681 | `cmd_test_page_pixel_rect`              | focused DV                |
| 3880 | `widget_to_page_norm` (mouse coords)    | focused DV                |

Plus the public accessor in `main_widget.h:27`.

**Conclusion:** every call site in `limn_command.cpp` semantically means
"the focused window's DV". None means "all DVs" or "an arbitrary
singleton". Today they're identical because there is only one DV.

## Target data model (terminal state)

```
MainWidget
└── viewport_splitter_ : QSplitter           (root layout)
    ├── ViewportPane "w1"                    (one per LimnWindow w/ type=tiled)
    │   └── QStackedWidget                   (PDF | text)
    │       ├── PdfViewOpenGLWidget          (own DocumentView*)
    │       └── QPlainTextEdit
    ├── ViewportPane "w2"
    │   └── ...
    └── ...
```

Invariants:

- Each `LimnWindow` of `type == "tiled"` maps 1:1 to a `ViewportPane`
  (currently nameless — TBD: introduce `ViewportPane` struct that pairs
  a `DocumentView*` + `PdfViewOpenGLWidget*` + optional text widget +
  the owning `win_id`).
- `windows->focused_id()` continues to mean "the LimnWindow whose pane
  currently drives keyboard/mouse + receives view/* commands".
- `MainWidget::document_view()` (no-arg) returns the **focused** pane's
  DV. All existing call sites preserve their semantics under this
  definition.
- New `MainWidget::document_view(const QString& win_id)` returns the
  pane DV for a specific window, or `nullptr` if unknown.
- Floating windows: defer. Stay as `LimnWindow` records only until tiled
  splits are stable.

## Phased plan

### Phase 1 — Audit + design doc (this file)  ✅ COMPLETE

This file. Catalog of every `document_view()` call site and the per-call
semantic intent. No code change.

### Phase 2 — Decouple DV from `MainWidget` singleton (overload only) ✅

Goal: introduce the `document_view(win_id)` overload returning the right
DV for a window, even though there's currently only one. **No visible
behaviour change** — the binary should look 100% identical to v0.39.10
after this phase.

Steps:

1. Add `DocumentView* MainWidget::document_view(const QString& win_id)`
   overload in `main_widget.h` / `main_widget.cpp`. Return `document_view_`
   for any `win_id` (only one DV exists). Document the contract.
2. Migrate the 11 call sites in `limn_command.cpp` that have a `win_id` in
   scope to the win-aware form. For sites that work on the focused
   window (3200, 3681, 3880, 497) pass the focused id; for the per-win
   handlers (639, 1476, 1590, 1867, 2389), pass the local `win_id`.
3. Leave the no-arg `document_view()` (no-arg) intact — it now means
   "focused DV" (currently equivalent to the singleton). 585+ uses
   inside `_main_widget.cpp` remain unchanged.
4. Build + smoke-launch the binary.

### Phase 3 — Multi-DV in the QSplitter (per-window viewport panes)

Goal: actually instantiate one `DocumentView*` per tiled `LimnWindow` and
mount it in `viewport_splitter_`.

Steps:

1. New `MainWidget::ViewportPane` struct (or just a `QHash<QString,
   PanelTuple>`) mapping `win_id` → `{DocumentView*, PdfViewOpenGLWidget*,
   QStackedWidget*, QPlainTextEdit*}`.
2. `MainWidget::add_pane_for(win_id, orient)` — creates a fresh
   `DocumentView` (sharing `db_manager_`/`document_manager_`/`checksummer_`),
   wraps it in `PdfViewOpenGLWidget`, inserts into splitter with the
   requested orientation. Returns the new pane.
3. `bridge/win-split` calls `add_pane_for(new_id, dir)`, copies
   page/zoom/offset/buffer from `src` to the new DV.
4. `bridge/win-focus` swaps the *active* pane indicator (CSS-frame the
   focused one) and re-targets the next view/* commands.
5. `bridge/win-close` removes the pane for `win_id` and `delete`s its
   DV/widget.
6. `MainWidget::document_view()` (no-arg) becomes:
   `return panes_.value(windows_->focused_id()).dv;`
   `MainWidget::document_view(win_id)` returns the same for any win.

Risks: `_main_widget.cpp` has 585 references to `->document_view()` and
many directly poke `document_view_` member. Phase 3 must keep
`document_view_` valid (point it at the focused pane's DV, or remove and
replace with a redirect through the win registry).

### Phase 4 — Per-DV overlay raster

Move `LimnCommand::overlay_raster` (`QImage`) into `LimnWindow` (or into a
new per-`win_id` map on `LimnCommand`). `rebuild_overlay_raster`,
`cmd_view_overlays`, `cmd_view_selection_set`, scroll handler all repaint
the right window's raster. **Touch `_main_widget.cpp` selection-rendering
block ONLY at the edges — the body that draws the overlays themselves
stays untouched per the scope contract.**

### Phase 5 — Lisp keybindings (`C-x 2 / 3 / 0 / o / 1`)

Add bindings in `backend/limn-pdf-mode.lisp` (or wherever `C-x C-f` is
registered) wired to `bridge/win-split :dir "h"` / `"v"`, `bridge/win-
close`, `bridge/win-focus :win-id <next>`. Use the existing
`limn/runtime:install-default-bindings` pattern.

## Constraints (cross-phase)

- All changes must preserve single-window behaviour.
- `MainWidget::document_view()` (no-arg) **must not be removed** — too
  many call sites inside `_main_widget.cpp`.
- Do **not** touch unrelated work: `cmd_view_selection_*` body,
  `cmd_view_scroll` win→page sync, selection-rendering block inside
  `rebuild_overlay_raster`, mouse-event handlers in `_main_widget.cpp`,
  search code.
- After each phase: build + at least launch the binary.

## Status (this branch)

- [x] Phase 1 — Audit + design doc
- [x] Phase 2 — `document_view(win_id)` overload + migrated call sites
- [ ] Phase 3 — multi-DV in splitter   (TODO; next session)
- [ ] Phase 4 — per-DV overlay raster  (TODO)
- [ ] Phase 5 — `C-x` window bindings  (TODO)

## Next-session concrete steps

1. Read `MainWidget::add_split_pane` (`sioyek/pdf_viewer/main_widget.cpp`
   ~L112). Replace shared-DV creation with a fresh `DocumentView`.
2. Add `panes_` map in `MainWidget`. Mount on `viewport_splitter_`. Wire
   focus border (`QFrame::setLineWidth` on the focused pane).
3. Re-route `document_view()` to return the focused pane's DV. Verify
   `document_view_` member can either be retired or kept as a "currently
   focused" cached pointer.
4. Wire `bridge/win-split / win-focus / win-close` to actual pane
   create/focus/remove.
5. Move `LimnCommand::overlay_raster` to per-`LimnWindow`. Audit every
   write site and forward to the right LimnWindow's raster.
6. Add `C-x` bindings in `backend/limn-default-config.lisp` (mirror the
   `C-x C-f` registration pattern; the existing `bridge/win-split` cmd
   takes `:|dir|`).
