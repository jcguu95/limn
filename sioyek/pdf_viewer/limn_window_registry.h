#pragma once
//
// LimnWindowRegistry — tracks Limn-protocol windows (w1, w2, ...) and
// their per-window state (page/zoom/offset/buffer/dark-mode/etc).
//
// In the current Qt layer there is still only ONE physical PdfViewOpenGLWidget
// rendering to the screen, but the protocol exposes a multi-window model:
//   - bridge/win-split creates new logical windows (no Qt split yet).
//   - bridge/win-float-create makes a logical floating window.
//   - Each window has its own state; only the focused tiled window
//     actually drives the visible widget.
//
// This lets us pass phase 10/11 protocol tests now and add real Qt widget
// splitting / floating later without changing the protocol surface.
//
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QString>

struct LimnWindow {
    QString  win_id;
    QString  type      = "tiled";   // "tiled" or "float"
    QString  buffer_id;              // empty if none loaded
    bool     focused   = false;
    // v0.18: which frame (OS-level window) this LimnWindow belongs to.
    // Defaults to "f1" (the bootstrap frame); reassigned via win-split
    // :frame-id or by being created inside an explicit frame.
    QString  frame_id  = "f1";

    // Floating-window placement (only meaningful when type == "float")
    int      x         = 0;
    int      y         = 0;
    int      width     = 0;
    int      height    = 0;

    // Per-window engine state (was static g_state_w1 in limn_command.cpp).
    int      page          = 0;
    float    zoom          = 1.0f;
    float    offset_x      = 0.0f;
    float    offset_y      = 0.0f;
    bool     dark_mode     = false;
    int      rotation      = 0;          // 0/90/180/270
    int      overlay_count = 0;

    // v0.14: full overlay layer specs (the JSON `layers` array as sent
    // by view/overlays). Persisted here so paintGL can read them, so
    // view/get can round-trip them back to Lisp, and so test harness
    // can introspect overlay state. overlay_count must remain in sync
    // (it's just overlays.size(), but we keep both for back-compat
    // with v0.7 test/snapshot which still reports the scalar).
    QJsonArray overlays;

    // Modeline content (SPEC §5.6). Three text segments displayed at the
    // window's bottom status line. v0.7 stores only — no widget yet.
    QString  modeline_left;
    QString  modeline_middle;
    QString  modeline_right;

    // v0.15.1 visual selection state. Per-window, page-relative norm
    // coords (matches the view/overlays wire contract — easy to set
    // from Lisp without knowing sioyek's AbsoluteDocumentPos space).
    // selection_text caches what wire view/selection-get returns; we
    // recompute it on every -set rather than chasing every doc-state
    // change.
    bool        selection_active = false;
    QJsonObject selection_begin;   // {:|page| n :|x| f :|y| f}
    QJsonObject selection_end;
    QString     selection_mode = "char";
    QString     selection_text;
    // v0.39.12 — actual per-character/per-line rects from MuPDF's
    // text-selection algorithm, in page-norm coords (each entry is
    // [x0 y0 x1 y1]).  Populated by cmd_view_selection_set when the
    // window is focused, returned via view/selection-get so the Lisp
    // annotation path can persist the real glyph rects instead of a
    // thin bounding box synthesised from begin/end points (which
    // dramatically underbooks the vertical extent on large-font
    // titles).
    QJsonArray  selection_rects;

    // v0.39.18 A (search-hit selection fix): explicit-geometry selection.
    // When a caller (e.g. %select-current-hit) already knows the EXACT
    // rects + text of a selection — as search does, from MuPDF's match
    // quads — it passes them straight through instead of round-tripping
    // begin/end through get_text_selection (which rounds to char bounds
    // and over-selected by a char).  When selection_explicit is true,
    // selection_rects holds the exact page-norm rects to paint and
    // selection_text holds the exact copy text; the begin/end +
    // get_text_selection path is skipped for both paint and copy.
    // In the explicit path each element of selection_rects is an object:
    //   {"page": int, "x0": double, "y0": double, "x1": double, "y1": double}
    // all page-norm [0,1] (vs the mouse/extraction path above, which fills
    // selection_rects with [x0 y0 x1 y1] arrays for annotation save).  Mouse
    // selection leaves selection_explicit false and uses the begin/end path
    // unchanged.  selection_rects is declared once above and shared by both.
    bool        selection_explicit = false;

    QJsonObject to_json() const;
};

class LimnWindowRegistry {
public:
    LimnWindowRegistry();              // creates default w1 (tiled, focused)

    // Existence & lookup
    bool         has(const QString& win_id) const;
    LimnWindow*  get(const QString& win_id);                    // nullptr if absent
    QStringList  all_ids() const;
    int          count() const { return windows.size(); }
    int          tiled_count() const;

    // Creation
    QString      allocate_id();        // returns fresh "wN"
    LimnWindow*  add_tiled(const QString& win_id);
    LimnWindow*  add_float(const QString& win_id,
                            int x, int y, int width, int height);

    // Removal
    bool         remove(const QString& win_id);

    // Focus (at most one focused at a time)
    void         set_focused(const QString& win_id);
    QString      focused_id() const;

    // Serialize for bridge/win-list
    QJsonArray   to_json() const;

private:
    QList<LimnWindow> windows;
    int               next_seq = 2;    // w1 is allocated in ctor
};

// ─── LimnFrame / LimnFrameRegistry (v0.18) ─────────────────────────────
//
// A "frame" is an OS-level top window. v0.18.0 implements the registry,
// wire commands, and events; v0.18.1 will actually instantiate a second
// Qt MainWindow per frame. For now every frame is registered abstractly
// but only f1 has an actual visible MainWidget.

class MainWidget;

struct LimnFrame {
    QString     frame_id;
    bool        focused = false;
    // v0.18.1: real Qt MainWindow this frame owns. f1 points to the
    // bootstrap MainWidget created in main.cpp (and which the registry
    // does NOT own — it survives across the registry's lifetime).
    // Frames created at runtime (f2, f3, ...) own their MainWidget;
    // remove() deletes it. nullptr in headless contexts or if the
    // frame was abstractly created (v0.18.0 back-compat path).
    MainWidget* widget = nullptr;
    bool        owns_widget = false;
};

class LimnFrameRegistry {
public:
    LimnFrameRegistry();              // creates default f1 (focused)

    bool        has(const QString& fid) const;
    LimnFrame*  get(const QString& fid);
    int         count() const { return frames.size(); }

    QString     allocate_id();        // returns fresh "fN"
    LimnFrame*  add(const QString& fid);
    bool        remove(const QString& fid);

    void        set_focused(const QString& fid);
    QString     focused_id() const;

    QStringList all_ids() const;

private:
    QList<LimnFrame> frames;
    int              next_seq = 2;
};
