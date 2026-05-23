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
