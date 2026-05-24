#pragma once
//
// LimnCommand: dispatches parsed JSON command objects to specific handlers.
// Receives a QJsonObject from LimnBridge, finds the right handler by `cmd`
// field, calls it, which then uses the bridge to send a response.
//
// Each command handler is a private method named cmd_<namespace>_<name>.
//
// This file covers phases 1–3 of the implementation roadmap:
//   bridge/capabilities, bridge/engine-load, bridge/win-list
//   view/set, view/get
//   buffer/open, buffer/close
//
#include "gap_buffer.h"

#include <QObject>
#include <QJsonObject>
#include <QString>
#include <QHash>
#include <QImage>

class LimnBridge;
class LimnBufferRegistry;
class LimnWindowRegistry;
class LimnFrameRegistry;
class MainWidget;
class Document;
struct LimnOptions;

class LimnCommand : public QObject {
    Q_OBJECT
public:
    LimnCommand(LimnBridge*         bridge,
                LimnBufferRegistry* registry,
                LimnWindowRegistry* windows,
                LimnFrameRegistry*  frames,
                MainWidget*         main_widget,
                const LimnOptions&  options,
                QObject*            parent = nullptr);

    // Entry point from LimnBridge after JSON parsing.
    void dispatch(const QJsonObject& msg);

private:
    // ─── bridge/* ─────────────────────────────────────────────────────
    void cmd_bridge_capabilities    (const QString& id, const QJsonObject& msg);
    void cmd_bridge_engine_load     (const QString& id, const QJsonObject& msg);
    void cmd_bridge_win_list        (const QString& id, const QJsonObject& msg);
    void cmd_bridge_win_split       (const QString& id, const QJsonObject& msg);
    void cmd_bridge_win_close       (const QString& id, const QJsonObject& msg);
    void cmd_bridge_win_focus       (const QString& id, const QJsonObject& msg);
    void cmd_bridge_win_float_create(const QString& id, const QJsonObject& msg);
    void cmd_bridge_win_float_move  (const QString& id, const QJsonObject& msg);
    void cmd_bridge_win_float_resize(const QString& id, const QJsonObject& msg);

    // ─── display/* (v0.25 face registry) ────────────────────────────
    void cmd_display_sync_faces   (const QString& id, const QJsonObject& msg);

    // ─── view/* ───────────────────────────────────────────────────────
    void cmd_view_set             (const QString& id, const QJsonObject& msg);
    void cmd_view_get             (const QString& id, const QJsonObject& msg);
    void cmd_view_overlays        (const QString& id, const QJsonObject& msg);
    // v0.15.1 visual selection (page-relative norm coords; per-window)
    void cmd_view_selection_set   (const QString& id, const QJsonObject& msg);
    void cmd_view_selection_get   (const QString& id, const QJsonObject& msg);
    void cmd_view_selection_clear (const QString& id, const QJsonObject& msg);

    // ─── buffer/* ─────────────────────────────────────────────────────
    void cmd_buffer_open         (const QString& id, const QJsonObject& msg);
    void cmd_buffer_close        (const QString& id, const QJsonObject& msg);
    void cmd_buffer_toc          (const QString& id, const QJsonObject& msg);
    void cmd_buffer_text         (const QString& id, const QJsonObject& msg);
    void cmd_buffer_links        (const QString& id, const QJsonObject& msg);
    void cmd_buffer_metadata     (const QString& id, const QJsonObject& msg);
    void cmd_buffer_render       (const QString& id, const QJsonObject& msg);
    void cmd_buffer_render_region(const QString& id, const QJsonObject& msg);

    // ─── bookmark/* (SPEC §5.x, v0.17) ──────────────────────────────
    // Per-buffer in-memory bookmark store. Persistence (sidecar file,
    // PDF native outline rewrite, hybrid) is user-Lisp territory.
    void cmd_bookmark_list_native(const QString& id, const QJsonObject& msg);
    void cmd_bookmark_list   (const QString& id, const QJsonObject& msg);
    void cmd_bookmark_set    (const QString& id, const QJsonObject& msg);
    void cmd_bookmark_get    (const QString& id, const QJsonObject& msg);
    void cmd_bookmark_delete (const QString& id, const QJsonObject& msg);

    // ─── frame/* (SPEC §3.2 §7.2, v0.18.0) ─────────────────────────
    void cmd_frame_list    (const QString& id, const QJsonObject& msg);
    void cmd_frame_create  (const QString& id, const QJsonObject& msg);
    void cmd_frame_close   (const QString& id, const QJsonObject& msg);
    void cmd_frame_focus   (const QString& id, const QJsonObject& msg);

public:
    // ─── v0.17 bookmark store (public so anon-namespace helpers in the
    //                          .cpp can serialise the struct) ─────────
    // Per-buffer (keyed by Limn buffer-id) ordered list of user
    // bookmarks. QList preserves insertion order for deterministic
    // bookmark/list responses. Cleared on buffer/close.
    struct BookmarkRecord {
        QString name;
        int     page = 0;
        double  x    = 0.0;
        double  y    = 0.0;
        QString note;
    };
private:
    QHash<QString, QList<BookmarkRecord>> bookmarks;
    // SPEC v0.5 §5.3 後段 — text engine 編輯 primitives
    void cmd_buffer_cursor_get   (const QString& id, const QJsonObject& msg);
    void cmd_buffer_cursor_set   (const QString& id, const QJsonObject& msg);
    void cmd_buffer_insert       (const QString& id, const QJsonObject& msg);
    void cmd_buffer_delete       (const QString& id, const QJsonObject& msg);

    // SPEC v0.22 §A — text-engine file I/O
    void cmd_buffer_load_file    (const QString& id, const QJsonObject& msg);
    void cmd_buffer_save         (const QString& id, const QJsonObject& msg);

    // SPEC v0.22 §C — text-engine display
    // Sync the C++ QPlainTextEdit display to text_buffers[buf]. Called
    // after every mutation (insert / delete / load-file / set-text) so
    // the widget mirrors the buffer's current content + cursor.
    void sync_text_widget        (const QString& buffer_id);
    // test/text-widget-snapshot — return PNG + stats of the text widget.
    void cmd_test_text_widget_snapshot(const QString& id, const QJsonObject& msg);

    // ─── test/* (enabled only when --test-mode is set) ────────────────
    void cmd_test_inject_key        (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_mouse_click(const QString& id, const QJsonObject& msg);
    void cmd_test_inject_mouse_drag (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_scroll     (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_gesture    (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_drag_drop  (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_ime_commit (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_ime_preedit(const QString& id, const QJsonObject& msg);   // v0.16
    void cmd_test_inject_audio_input(const QString& id, const QJsonObject& msg);
    void cmd_test_inject_resize     (const QString& id, const QJsonObject& msg);
    void cmd_test_emit_heartbeat    (const QString& id, const QJsonObject& msg);
    void cmd_test_snapshot          (const QString& id, const QJsonObject& msg);
    void cmd_test_flush_caches      (const QString& id, const QJsonObject& msg);
    void cmd_test_grab_window       (const QString& id, const QJsonObject& msg);
    void cmd_test_widget_tree       (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_qt_key     (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_qt_mouse_click(const QString& id, const QJsonObject& msg);

    // ─── v0.14 pixel-level test primitives ──────────────────────────
    // Tiny payloads — server-side scans, no PNG transport.
    void cmd_test_sample_pixel      (const QString& id, const QJsonObject& msg);
    void cmd_test_region_bbox       (const QString& id, const QJsonObject& msg);
    void cmd_test_region_hash       (const QString& id, const QJsonObject& msg);
    void cmd_test_page_pixel_rect   (const QString& id, const QJsonObject& msg);
    void cmd_test_last_text_render  (const QString& id, const QJsonObject& msg);


    // ─── modeline/* (SPEC §5.6) ─────────────────────────────────────
    void cmd_modeline_set           (const QString& id, const QJsonObject& msg);
    void cmd_modeline_get           (const QString& id, const QJsonObject& msg);

    // ─── message/* (SPEC §5.5) ──────────────────────────────────────
    void cmd_message_echo           (const QString& id, const QJsonObject& msg);
    void cmd_message_log            (const QString& id, const QJsonObject& msg);
    void cmd_message_clear          (const QString& id, const QJsonObject& msg);

    // ─── minibuffer/* (SPEC §5.4) ───────────────────────────────────
    void cmd_minibuffer_open        (const QString& id, const QJsonObject& msg);
    void cmd_minibuffer_close       (const QString& id, const QJsonObject& msg);
    void cmd_minibuffer_set_prompt  (const QString& id, const QJsonObject& msg);
    void cmd_minibuffer_set_text    (const QString& id, const QJsonObject& msg);
    void cmd_minibuffer_get         (const QString& id, const QJsonObject& msg);

public:
    // Called by LimnInputFilter on every KeyPress. Returns TRUE if the
    // minibuffer consumed the keystroke (so the filter should NOT push a
    // normal `key` event for it). See SPEC §6 Minibuffer 事件:
    //   printable → minibuffer-input
    //   RET       → minibuffer-submit
    //   ESC       → minibuffer-cancel
    //   anything else → not consumed, filter pushes normal `key`
    bool minibuffer_handle_key(const QString& key, const QJsonArray& mods);

    // v0.16.1: Qt-level IME hook for LimnInputFilter::eventFilter to
    // call on QEvent::InputMethod. Same server-side dispatch semantics
    // as cmd_test_inject_ime_commit / _preedit but driven by real Qt
    // input events (fcitx → Qt → here → bus event + minibuffer mutation).
    void handle_ime_event(const QString& preedit, const QString& commit);

    // Map a widget-local pixel click (relative to the OpenGL viewport)
    // to a document position. Per SPEC v0.5 §6:
    //   page : real page under cursor; -1 if outside any page / no doc
    //   x, y : 0.0–1.0 normalized to the page's bounding rect
    // Used by LimnInputFilter's MouseButtonPress branch.
    bool widget_to_page_norm(int widget_x, int widget_y,
                              int* out_page, double* out_nx, double* out_ny);

    // ─── v0.14 paintGL integration accessors (public) ───────────────
    // Called from PdfViewOpenGLWidget::paintGL each frame.
    QJsonArray         focused_window_overlays() const;
    void               record_text_render(const QJsonObject& info) {
                            last_text_render = info; }
private:

    // Helpers
    QJsonObject build_open_data(const QString& buffer_id, Document* doc);
    QJsonObject collect_view_state(const QString& win_id);
    void        emit_buffer_opened(const QString& buffer_id, Document* doc,
                                    const QString& engine);
    void        emit_buffer_closed(const QString& buffer_id);

    LimnBridge*         bridge;
    LimnBufferRegistry* registry;
    LimnWindowRegistry* windows;
    LimnFrameRegistry*  frames;  // v0.18
    MainWidget*         main_widget;
    bool                test_mode;

    // ─── text engine state (SPEC §7.6) ─────────────────────────────
    // The "text" engine's content store. Two kinds of buffer-id live
    // here:
    //   - User-allocated buffers from bridge/engine-load (engine=text):
    //     IDs like t1, t2, ... — see next_text_seq.
    //   - Reserved chrome buffers, bootstrapped in the LimnCommand
    //     constructor and never deleted:
    //         "*minibuffer*"   current minibuffer typed text
    //         "*echo-area*"    single-line "what to show in the echo
    //                          area when minibuffer is closed"
    //         "*messages*"     accumulated message log (Emacs *Messages*)
    //
    // §1.2 says all chrome text surfaces are text-engine buffers; this
    // is where that promise materialises. ChromeBar (Qt widget) just
    // reads the strings via the helpers below.
    QHash<QString, GapBuffer> text_buffers;
    QHash<QString, int>       text_cursors;   // per-buffer cursor (UTF-16 offset)
    // SPEC v0.22 §A: text-engine buffer-id → bound on-disk path.
    // Set by buffer/load-file, consumed by buffer/save. Absent = "no path".
    QHash<QString, QString>   buffer_paths;
    int                     next_text_seq = 1;

    // ─── minibuffer meta-state (SPEC §5.4) ─────────────────────────
    // The text content lives in text_buffers["*minibuffer*"]. These
    // two are the "frame around" the content: is the minibuffer
    // currently shown? what's the prompt prefix?
    bool     minibuffer_open = false;
    QString  minibuffer_prompt;

    // ─── v0.25 face registry ───────────────────────────────────────
    // Populated by display/sync-faces from the Lisp face table.
    // Overlay layers may specify "face":"name" instead of "color":"#RRGGBB";
    // rebuild_overlay_raster resolves the face to its foreground colour.
    struct LimnFaceEntry {
        QString foreground;   // "#RRGGBB" or empty
        QString background;
        bool    bold       = false;
        bool    italic     = false;
        bool    underline  = false;
    };
    QHash<QString, LimnFaceEntry> face_registry_;

    // ─── v0.14 last-text-render introspection ──────────────────────
    // Tests use test/last-text-render to verify the QFont that Qt
    // actually ended up using (catches silent font fallback). Empty /
    // NIL when no text overlay has been drawn yet (or after engine-load).
    QJsonObject last_text_render;

    // ─── v0.14 deterministic overlay raster ────────────────────────
    // Rendering overlays into a separate QImage rather than relying
    // on QOpenGLWidget::grabFramebuffer() gives us:
    //   (a) Independence from GPU/driver availability (Xvfb has none).
    //   (b) Independence from QOpenGLWidget init/show timing.
    //   (c) Byte-exact deterministic output across runs and machines.
    //
    // The raster is "overlays on an opaque white background" — tests
    // verifying overlay color/opacity/geometry sample against a known
    // white substrate, decoupling overlay correctness from whatever
    // the PDF page rendered as.
    //
    // For production display, paintGL still composes the raster onto
    // the GL framebuffer on top of the PDF — same QPainter calls,
    // same outcome, just running once into the QImage and then blitted.
    QImage overlay_raster;
public:
    // Rebuild raster from current focused window's overlays. Called
    // by cmd_view_overlays (so tests can sample right after state
    // mutates) and by paintGL (for production display blit).
    void rebuild_overlay_raster(int width, int height);
    const QImage& current_overlay_raster() const { return overlay_raster; }
};
