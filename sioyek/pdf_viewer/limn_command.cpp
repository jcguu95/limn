#include "limn_command.h"

#include "limn_build_info.h"
#include "limn_bridge.h"
#include "limn_buffer_registry.h"
#include "limn_chrome_bar.h"
#include "limn_engine_mupdf.h"
#include "limn_options.h"
#include "limn_window_registry.h"
#include "main_widget.h"
#include "document.h"
#include "document_view.h"
#include "pdf_view_opengl_widget.h"

#include <QJsonArray>
#include <QJsonValue>
#include <QBuffer>
#include <QByteArray>
#include <QPixmap>
#include <QImage>
#include <QRgb>
#include <QWidget>
#include <QMetaObject>
#include <QCoreApplication>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPointF>
#include <QApplication>
#include <QCryptographicHash>
#include <QPainter>
#include <QPen>
#include <QFont>
#include <QFontInfo>
#include <QFontMetricsF>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QTextStream>
#include <QPlainTextEdit>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextBlock>
#include <QTextLayout>
#include <QTextLine>
#include <QAbstractTextDocumentLayout>
#include <QScrollBar>
#include <QStackedWidget>
#include <climits>
#include <cmath>
#include <stdexcept>

namespace {

static double safe_double(float v) {
    if (std::isnan(v) || std::isinf(v)) return 0.0;
    return static_cast<double>(v);
}

std::wstring q_to_w(const QString& q) {
    return q.toStdWString();
}

}  // anonymous namespace

LimnCommand::LimnCommand(LimnBridge*         bridge,
                         LimnBufferRegistry* registry,
                         LimnWindowRegistry* windows,
                         LimnFrameRegistry*  frames,
                         MainWidget*         main_widget,
                         const LimnOptions&  options,
                         QObject*            parent)
    : QObject(parent),
      bridge(bridge),
      registry(registry),
      windows(windows),
      frames(frames),
      main_widget(main_widget),
      test_mode(options.test_mode) {
    // SPEC §1.2: bootstrap the three reserved text-engine buffers that
    // back the chrome text surfaces. These IDs are intentionally
    // bracketed with asterisks so they never collide with the auto-
    // allocated t1 / t2 / ... ids for user-opened text buffers.
    text_buffers.insert("*minibuffer*", GapBuffer());
    text_buffers.insert("*echo-area*",  GapBuffer());
    text_buffers.insert("*messages*",   GapBuffer());
    text_cursors.insert("*minibuffer*", 0);
    text_cursors.insert("*echo-area*",  0);
    text_cursors.insert("*messages*",   0);
}

// ─── Dispatch ──────────────────────────────────────────────────────────

void LimnCommand::dispatch(const QJsonObject& msg) {
    const QString id  = msg.value("id").toString();
    const QString cmd = msg.value("cmd").toString();

    if (cmd.isEmpty()) {
        bridge->send_fail(id, "missing or empty 'cmd' field");
        return;
    }

    // version/* — binary build provenance (v0.37 A1c)
    if (cmd == "version/info")            { cmd_version_info           (id, msg); return; }

    // bridge/*
    if (cmd == "bridge/capabilities")     { cmd_bridge_capabilities    (id, msg); return; }
    if (cmd == "bridge/engine-load")      { cmd_bridge_engine_load     (id, msg); return; }
    if (cmd == "bridge/win-list")         { cmd_bridge_win_list        (id, msg); return; }
    if (cmd == "bridge/win-split")        { cmd_bridge_win_split       (id, msg); return; }
    if (cmd == "bridge/win-close")        { cmd_bridge_win_close       (id, msg); return; }
    if (cmd == "bridge/win-focus")        { cmd_bridge_win_focus       (id, msg); return; }
    if (cmd == "bridge/win-float-create") { cmd_bridge_win_float_create(id, msg); return; }
    if (cmd == "bridge/win-float-move")   { cmd_bridge_win_float_move  (id, msg); return; }
    if (cmd == "bridge/win-float-resize") { cmd_bridge_win_float_resize(id, msg); return; }

    // display/* (v0.25 face registry)
    if (cmd == "display/sync-faces")    { cmd_display_sync_faces   (id, msg); return; }

    // view/*
    if (cmd == "view/set")              { cmd_view_set             (id, msg); return; }
    if (cmd == "view/get")              { cmd_view_get             (id, msg); return; }
    if (cmd == "view/overlays")         { cmd_view_overlays        (id, msg); return; }
    if (cmd == "view/selection-set")    { cmd_view_selection_set   (id, msg); return; }
    if (cmd == "view/selection-get")    { cmd_view_selection_get   (id, msg); return; }
    if (cmd == "view/selection-clear")  { cmd_view_selection_clear (id, msg); return; }

    // modeline/* (SPEC §5.6)
    if (cmd == "modeline/set")  { cmd_modeline_set (id, msg); return; }
    if (cmd == "modeline/get")  { cmd_modeline_get (id, msg); return; }

    // message/* (SPEC §5.5)
    if (cmd == "message/echo")  { cmd_message_echo (id, msg); return; }
    if (cmd == "message/log")   { cmd_message_log  (id, msg); return; }
    if (cmd == "message/clear") { cmd_message_clear(id, msg); return; }

    // minibuffer/* (SPEC §5.4)
    if (cmd == "minibuffer/open")       { cmd_minibuffer_open       (id, msg); return; }
    if (cmd == "minibuffer/close")      { cmd_minibuffer_close      (id, msg); return; }
    if (cmd == "minibuffer/set-prompt") { cmd_minibuffer_set_prompt (id, msg); return; }
    if (cmd == "minibuffer/set-text")   { cmd_minibuffer_set_text   (id, msg); return; }
    if (cmd == "minibuffer/get")        { cmd_minibuffer_get        (id, msg); return; }

    // buffer/*
    if (cmd == "buffer/open")          { cmd_buffer_open         (id, msg); return; }
    if (cmd == "buffer/close")         { cmd_buffer_close        (id, msg); return; }
    if (cmd == "buffer/toc")           { cmd_buffer_toc          (id, msg); return; }
    if (cmd == "buffer/text")          { cmd_buffer_text         (id, msg); return; }
    if (cmd == "buffer/search")        { cmd_buffer_search       (id, msg); return; }
    if (cmd == "buffer/links")         { cmd_buffer_links        (id, msg); return; }
    if (cmd == "buffer/metadata")      { cmd_buffer_metadata     (id, msg); return; }
    if (cmd == "buffer/render")        { cmd_buffer_render       (id, msg); return; }
    if (cmd == "buffer/render-region") { cmd_buffer_render_region(id, msg); return; }
    if (cmd == "buffer/cursor-get")    { cmd_buffer_cursor_get   (id, msg); return; }
    if (cmd == "buffer/cursor-set")    { cmd_buffer_cursor_set   (id, msg); return; }
    if (cmd == "buffer/insert")        { cmd_buffer_insert       (id, msg); return; }
    if (cmd == "buffer/delete")        { cmd_buffer_delete       (id, msg); return; }
    if (cmd == "buffer/load-file")     { cmd_buffer_load_file    (id, msg); return; }
    if (cmd == "buffer/save")          { cmd_buffer_save         (id, msg); return; }
    if (cmd == "buffer/codepoint-rects"){ cmd_buffer_codepoint_rects(id, msg); return; }

    // bookmark/* (SPEC §5.x, v0.17)
    if (cmd == "bookmark/list-native") { cmd_bookmark_list_native(id, msg); return; }
    if (cmd == "bookmark/list")        { cmd_bookmark_list       (id, msg); return; }
    if (cmd == "bookmark/set")         { cmd_bookmark_set        (id, msg); return; }
    if (cmd == "bookmark/get")         { cmd_bookmark_get        (id, msg); return; }
    if (cmd == "bookmark/delete")      { cmd_bookmark_delete     (id, msg); return; }

    // frame/* (SPEC §3.2 §7.2, v0.18.0)
    if (cmd == "frame/list")           { cmd_frame_list   (id, msg); return; }
    if (cmd == "frame/create")         { cmd_frame_create (id, msg); return; }
    if (cmd == "frame/close")          { cmd_frame_close  (id, msg); return; }
    if (cmd == "frame/focus")          { cmd_frame_focus  (id, msg); return; }

    // test/* — only available when --test-mode was set on startup
    if (cmd.startsWith("test/")) {
        if (!test_mode) {
            bridge->send_fail(id, "test mode disabled");
            return;
        }
        if (cmd == "test/inject-key")         { cmd_test_inject_key        (id, msg); return; }
        if (cmd == "test/inject-mouse-click") { cmd_test_inject_mouse_click(id, msg); return; }
        if (cmd == "test/inject-mouse-drag")  { cmd_test_inject_mouse_drag (id, msg); return; }
        if (cmd == "test/inject-scroll")      { cmd_test_inject_scroll     (id, msg); return; }
        if (cmd == "test/inject-gesture")     { cmd_test_inject_gesture    (id, msg); return; }
        if (cmd == "test/inject-drag-drop")   { cmd_test_inject_drag_drop  (id, msg); return; }
        // v0.16: canonical names are test/inject-ime/{commit,preedit}.
        // Old test/inject-ime-commit kept as alias (existing tests in
        // i18n.lisp / test-mode.lisp / events.lisp still use the flat name).
        if (cmd == "test/inject-ime/commit")  { cmd_test_inject_ime_commit (id, msg); return; }
        if (cmd == "test/inject-ime/preedit") { cmd_test_inject_ime_preedit(id, msg); return; }
        if (cmd == "test/inject-ime-commit")  { cmd_test_inject_ime_commit (id, msg); return; }
        if (cmd == "test/inject-audio-input") { cmd_test_inject_audio_input(id, msg); return; }
        if (cmd == "test/inject-resize")      { cmd_test_inject_resize     (id, msg); return; }
        if (cmd == "test/emit-heartbeat")     { cmd_test_emit_heartbeat    (id, msg); return; }
        if (cmd == "test/snapshot")           { cmd_test_snapshot          (id, msg); return; }
        if (cmd == "test/flush-caches")       { cmd_test_flush_caches      (id, msg); return; }
        if (cmd == "test/grab-window")        { cmd_test_grab_window       (id, msg); return; }
        if (cmd == "test/widget-tree")        { cmd_test_widget_tree       (id, msg); return; }
        if (cmd == "test/inject-qt-key")      { cmd_test_inject_qt_key     (id, msg); return; }
        if (cmd == "test/inject-qt-mouse-click") { cmd_test_inject_qt_mouse_click(id, msg); return; }
        // v0.14 pixel-level test primitives
        if (cmd == "test/sample-pixel")       { cmd_test_sample_pixel      (id, msg); return; }
        if (cmd == "test/region-bbox")        { cmd_test_region_bbox       (id, msg); return; }
        if (cmd == "test/region-hash")        { cmd_test_region_hash       (id, msg); return; }
        if (cmd == "test/page-pixel-rect")    { cmd_test_page_pixel_rect   (id, msg); return; }
        if (cmd == "test/last-text-render")   { cmd_test_last_text_render  (id, msg); return; }
        if (cmd == "test/text-widget-snapshot") { cmd_test_text_widget_snapshot(id, msg); return; }
        bridge->send_fail(id, QString("unknown test command: %1").arg(cmd));
        return;
    }

    bridge->send_fail(id, QString("unknown command: %1").arg(cmd));
}

// ─── bridge/capabilities ──────────────────────────────────────────────

void LimnCommand::cmd_bridge_capabilities(const QString& id, const QJsonObject&) {
    QJsonObject data;
    QJsonArray engines;
    engines.append("text");    // §7.6 bundled — chrome primitives' backend
    engines.append("mupdf");   // §7.6 bundled — PDF / EPUB
    data.insert("engines",  engines);
    data.insert("frontend", "qt");
    data.insert("version",  "0.4");
    bridge->send_ok(id, data);
}

// ─── version/info (v0.37 A1c) ─────────────────────────────────────────
// Returns the same build provenance the binary prints to stderr at
// startup, but as a structured plist so Lisp / scripts can introspect.
// Strings come from -D macros set by pdf_viewer_build_config.pro; see
// limn_build_info.h for the contract.

void LimnCommand::cmd_version_info(const QString& id, const QJsonObject&) {
    QJsonObject data;
    data.insert("git-hash",   LIMN_BUILD_GIT_HASH);
    data.insert("git-dirty",  LIMN_BUILD_GIT_DIRTY);
    data.insert("build-time", LIMN_BUILD_TIME);
    data.insert("build-host", LIMN_BUILD_HOST);
    data.insert("build-qt",   LIMN_BUILD_QT);
    bridge->send_ok(id, data);
}

// ─── bridge/engine-load ───────────────────────────────────────────────

void LimnCommand::cmd_bridge_engine_load(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    const QString engine = msg.value("engine").toString();
    const QString path   = msg.value("path").toString();   // optional for text

    if (win_id.isEmpty() || engine.isEmpty()) {
        bridge->send_fail(id, "missing required field: win-id and engine are required");
        return;
    }
    LimnWindow* win = windows->get(win_id);
    if (!win) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }

    // ─── text engine (SPEC §7.6) ───────────────────────────────────────
    // path optional; empty → empty text buffer. Used by all chrome
    // primitives (minibuffer / echo area / *Messages* / modeline).
    if (engine == "text") {
        const QString tid = QString("t%1").arg(next_text_seq++);
        text_buffers.insert(tid, GapBuffer());
        text_cursors.insert(tid, 0);
        win->buffer_id     = tid;
        win->page          = 0;
        win->zoom          = 1.0f;
        win->offset_x      = 0.0f;
        win->offset_y      = 0.0f;
        win->dark_mode     = false;
        win->rotation      = 0;
        win->overlay_count = 0;
        win->overlays      = QJsonArray();   /* v0.14 */ rebuild_overlay_raster(overlay_raster.width(), overlay_raster.height());

        QJsonObject data;
        data.insert("buffer-id", tid);
        QJsonArray supports;
        supports.append("buffer/text");
        data.insert("supports", supports);
        bridge->send_ok(id, data);

        // v0.22 §C — if this window is focused (or first ever), show the
        // text widget. Same focus rule cmd_view_set uses.
        const bool is_active = (windows->focused_id() == win_id);
        if (is_active && main_widget) {
            sync_text_widget(tid);
            main_widget->show_text_view();
        }

        QJsonObject ev;
        ev.insert("frame-id",   "f1");
        ev.insert("buffer-id",  tid);
        ev.insert("engine",     "text");
        ev.insert("page-count", 0);
        bridge->push_event("buffer-opened", ev);
        return;
    }

    // ─── mupdf engine ─────────────────────────────────────────────────
    if (engine != "mupdf") {
        bridge->send_fail(id, QString("unknown engine: %1").arg(engine));
        return;
    }
    if (path.isEmpty()) {
        bridge->send_fail(id, "mupdf engine requires a path");
        return;
    }

    // v0.15.1: engine-load on a NON-focused window must NOT touch the
    // live widget. Pre-v0.15.1 this code unconditionally called
    // main_widget->open_document(), set_dark_mode(false), and
    // rebuild_overlay_raster() — all of which mutate the visible
    // widget regardless of which window the load targets. That broke
    // per-window isolation: loading a doc into w2 while w1 was focused
    // would steal w1's display, flip its dark-mode off, and clear its
    // overlays from the raster.
    //
    // Split into two paths:
    //   - focused load: same as before — drive live DV via main_widget
    //   - non-focused load: use DocumentManager directly to materialise
    //     the Document* without touching DV; live widget untouched.
    const QString focused_id = windows->focused_id();
    const bool    is_focused_load = (win_id == focused_id);

    Document* doc = nullptr;
    if (is_focused_load) {
        const bool ok = main_widget->open_document(q_to_w(path));
        if (!ok) {
            const QString err = QString("failed to open: %1").arg(path);
            bridge->send_fail(id, err);
            QJsonObject ev;
            ev.insert("cmd",     QStringLiteral("bridge/engine-load"));
            ev.insert("message", err);
            bridge->push_event("error", ev);
            return;
        }
        doc = main_widget->document_view()->get_document();
    } else {
        // Non-focused: just ask DocumentManager. It returns a cached
        // Document* or constructs a new one. We validate by checking
        // num_pages > 0 (sioyek's get_document is happy to construct
        // a placeholder even for nonexistent files).
        doc = main_widget->document_manager()->get_document(q_to_w(path));
        if (!doc || doc->num_pages() <= 0) {
            const QString err = QString("failed to open: %1").arg(path);
            bridge->send_fail(id, err);
            QJsonObject ev;
            ev.insert("cmd",     QStringLiteral("bridge/engine-load"));
            ev.insert("message", err);
            bridge->push_event("error", ev);
            return;
        }
    }
    if (!doc) {
        bridge->send_fail(id, "document loaded but not attached to view");
        return;
    }

    const QString buffer_id = registry->register_buffer(doc);

    // Reset per-window state for this window (always, regardless of focus).
    win->buffer_id     = buffer_id;
    win->page          = 0;
    win->zoom          = 1.0f;
    win->offset_x      = 0.0f;
    win->offset_y      = 0.0f;
    win->dark_mode     = false;
    win->rotation      = 0;
    win->overlay_count = 0;
    win->overlays      = QJsonArray();      // v0.14: state reset on engine-load
    // v0.15.1: selection state also resets on engine-load
    win->selection_active = false;
    win->selection_begin  = QJsonObject();
    win->selection_end    = QJsonObject();
    win->selection_text   = QString();

    // Live-widget side effects: only when this load drives the focused
    // window (otherwise we'd violate the isolation invariant above).
    if (is_focused_load) {
        main_widget->opengl_widget()->set_dark_mode(false);
        rebuild_overlay_raster(overlay_raster.width(), overlay_raster.height());
        // v0.22 §C — coming from a text buffer? switch the stacked widget
        // back to the PDF view. Idempotent if already on PDF view.
        main_widget->show_pdf_view();
    }

    QJsonObject data;
    data.insert("buffer-id", buffer_id);
    QJsonArray supports;
    supports.append("buffer/text");
    supports.append("buffer/toc");
    supports.append("buffer/links");
    supports.append("buffer/render");
    supports.append("buffer/render-region");
    supports.append("buffer/metadata");
    data.insert("supports", supports);
    bridge->send_ok(id, data);

    emit_buffer_opened(buffer_id, doc, "mupdf");
}

// ─── bridge/win-list ──────────────────────────────────────────────────

void LimnCommand::cmd_bridge_win_list(const QString& id, const QJsonObject&) {
    bridge->send_ok_array(id, windows->to_json());
}

// ─── bridge/win-split ──────────────────────────────────────────────────

void LimnCommand::cmd_bridge_win_split(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    const QString dir    = msg.value("dir").toString();
    LimnWindow* src = windows->get(win_id);
    if (!src) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    if (dir != "h" && dir != "v") {
        bridge->send_fail(id, QString("invalid 'dir' (expected 'h' or 'v'): %1").arg(dir));
        return;
    }
    // v0.18: :frame-id optional. Defaults to the source window's frame
    // (which itself defaults to "f1"). Explicit :frame-id puts the new
    // window in a different frame — useful for "move pane to other
    // monitor" style workflows once v0.18.1 lands real second windows.
    QString target_frame = msg.value("frame-id").toString();
    if (target_frame.isEmpty()) target_frame = src->frame_id;
    if (frames && !frames->has(target_frame)) {
        bridge->send_fail(id, QString("unknown frame-id: %1").arg(target_frame));
        return;
    }
    const QString new_id = windows->allocate_id();
    LimnWindow* w = windows->add_tiled(new_id);
    if (w) w->frame_id = target_frame;
    // SPEC v0.5 §5.1 — visible split only when new window is in the
    // current frame (other-frame splits don't show on the focused widget).
    if (main_widget && target_frame == src->frame_id) {
        main_widget->add_split_pane(dir);
    }
    QJsonObject data;
    data.insert("win-a", win_id);
    data.insert("win-b", new_id);
    bridge->send_ok(id, data);
}

// ─── bridge/win-close ──────────────────────────────────────────────────

void LimnCommand::cmd_bridge_win_close(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    LimnWindow* w = windows->get(win_id);
    if (!w) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    // Refuse to close the last tiled window — otherwise Limn would have
    // nowhere to display content.
    if (w->type == "tiled" && windows->tiled_count() <= 1) {
        bridge->send_fail(id, "cannot close the last tiled window");
        return;
    }
    windows->remove(win_id);
    bridge->send_ok(id);
}

// ─── bridge/win-focus ──────────────────────────────────────────────────

void LimnCommand::cmd_bridge_win_focus(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    if (!windows->has(win_id)) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }

    // v0.15 per-window independent DocumentView.
    //
    // The physical Qt widget is shared; focus switching swaps the live
    // DV's state between LimnWindow snapshots. Three steps:
    //
    //   1. Save the live DV's drift (continuous fields — zoom/offset —
    //      that the user may have scrolled/zoomed inline) back into
    //      the previously-focused LimnWindow. `page` is intent-level
    //      and already lives in win->page from view/set, so we don't
    //      sync it from the (offscreen-unreliable) center-page heuristic.
    //   2. Flip the focused flag.
    //   3. If target window has a buffer, restore its snapshot into
    //      the live DV (re-open the document if it differs from live,
    //      then apply page/zoom/offset/dark-mode). Rebuild the overlay
    //      raster so the new focused window's overlays paint.
    DocumentView* dv = main_widget ? main_widget->document_view() : nullptr;
    LimnWindow* prev = windows->get(windows->focused_id());
    if (prev && dv && !prev->buffer_id.isEmpty()) {
        Document* live = dv->get_document();
        if (live && registry->find_id(live) == prev->buffer_id) {
            prev->zoom     = dv->get_zoom_level();
            prev->offset_x = dv->get_offset_x();
            prev->offset_y = dv->get_offset_y();
        }
    }

    windows->set_focused(win_id);

    LimnWindow* target = windows->get(win_id);
    if (target && dv && !target->buffer_id.isEmpty()) {
        Document* target_doc = registry->lookup(target->buffer_id);
        Document* live_doc   = dv->get_document();
        if (target_doc && target_doc != live_doc) {
            // Re-attach the target buffer's document to the live DV.
            // DocumentManager caches by canonical path, so this is a
            // cheap lookup, not a re-parse.
            main_widget->open_document(target_doc->get_path());
        }
        if (target_doc) {
            dv->set_zoom_level(target->zoom, true, true);
            dv->goto_page(target->page);
            dv->set_offsets(target->offset_x, target->offset_y, true);
            main_widget->opengl_widget()->set_dark_mode(target->dark_mode);
            // v0.15.1: rotation apply. Sioyek only exposes `rotate()`
            // as a +90° delta — no absolute setter. The live widget's
            // current rotation == prev->rotation (since prev was the
            // window driving it). Diff is target absolute minus prev
            // absolute, in 90° steps.
            //
            // If prev has no buffer (live wasn't really reflecting any
            // window's rotation) we fall back to assuming 0 — same
            // assumption cmd_view_set's rotation handler uses on first
            // engine-load.
            const int live_rot = (prev && !prev->buffer_id.isEmpty())
                                  ? prev->rotation : 0;
            int rot_diff = (target->rotation - live_rot + 360) % 360;
            int steps = rot_diff / 90;
            for (int i = 0; i < steps; ++i) dv->rotate();
        }
    }

    rebuild_overlay_raster(overlay_raster.width(), overlay_raster.height());
    if (main_widget && main_widget->opengl_widget()) {
        main_widget->opengl_widget()->update();
    }

    bridge->send_ok(id);
}

// ─── bridge/win-float-create ───────────────────────────────────────────

void LimnCommand::cmd_bridge_win_float_create(const QString& id, const QJsonObject& msg) {
    const QString buffer_id = msg.value("buffer-id").toString();
    if (!buffer_id.isEmpty() && !registry->lookup(buffer_id)) {
        bridge->send_fail(id, QString("unknown buffer-id: %1").arg(buffer_id));
        return;
    }
    const int x = msg.value("x").toInt(50);
    const int y = msg.value("y").toInt(50);
    const int w = msg.value("width").toInt(400);
    const int h = msg.value("height").toInt(300);

    const QString new_id = windows->allocate_id();
    LimnWindow* fw = windows->add_float(new_id, x, y, w, h);
    fw->buffer_id = buffer_id;

    QJsonObject data;
    data.insert("win-id", new_id);
    bridge->send_ok(id, data);
}

// ─── bridge/win-float-move ─────────────────────────────────────────────

void LimnCommand::cmd_bridge_win_float_move(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    LimnWindow* w = windows->get(win_id);
    if (!w) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    if (w->type != "float") {
        bridge->send_fail(id, QString("win-id %1 is not a floating window").arg(win_id));
        return;
    }
    if (msg.contains("x")) w->x = msg.value("x").toInt();
    if (msg.contains("y")) w->y = msg.value("y").toInt();
    bridge->send_ok(id);
}

// ─── bridge/win-float-resize ───────────────────────────────────────────

void LimnCommand::cmd_bridge_win_float_resize(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    LimnWindow* w = windows->get(win_id);
    if (!w) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    if (w->type != "float") {
        bridge->send_fail(id, QString("win-id %1 is not a floating window").arg(win_id));
        return;
    }
    if (msg.contains("width"))  w->width  = msg.value("width").toInt();
    if (msg.contains("height")) w->height = msg.value("height").toInt();
    bridge->send_ok(id);
}

// ─── view/set ─────────────────────────────────────────────────────────

void LimnCommand::cmd_view_set(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    LimnWindow* win = windows->get(win_id);
    if (!win) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }

    // SPEC v0.22 §C — text-engine window short-circuit.
    // If this window's buffer is text-engine, the mupdf-specific path
    // (val_doc, page-count validation, opengl widget) doesn't apply.
    // page/zoom/offset are no-ops for text buffers (we accept and
    // ignore them gracefully). Active text-engine windows switch the
    // stacked widget to the text view.
    if (text_buffers.contains(win->buffer_id)) {
        const bool is_active = (windows->focused_id() == win_id);
        if (is_active && main_widget) {
            sync_text_widget(win->buffer_id);
            main_widget->show_text_view();
        }
        bridge->send_ok(id);
        return;
    }

    // The active document_view is the Qt widget; it currently holds whichever
    // doc was last loaded. For multi-window state independence, we track each
    // window's page/zoom in LimnWindow, and only forward to the live widget
    // if this window is the focused/active one.
    DocumentView* dv = main_widget->document_view();
    Document* doc = dv->get_document();
    // v0.15: "is_active" = this window owns the live widget. Use the
    // explicit focused-id (single source of truth, set by bridge/win-
    // focus), not a buffer-id match. The old buffer-id heuristic was
    // ambiguous when two windows happened to point at the same cached
    // Document* (same PDF path), and let non-focused view/set leak into
    // the visible DV — violating per-window isolation.
    const bool    is_active = (windows->focused_id() == win_id);
    const QString live_buf  = registry->find_id(doc);
    (void)live_buf;

    // Sync continuous fields (offset, zoom) before applying partial
    // updates. Without this, a request that only sets :|offset-y| would
    // write the stale win->offset_x into dv->set_offsets, wiping any
    // user-side horizontal scroll. Same rationale as collect_view_state,
    // and same reason for NOT touching `page` (it's discrete, intent-level,
    // and dv->get_center_page_number is unreliable in offscreen tests).
    if (is_active) {
        win->zoom     = dv->get_zoom_level();
        win->offset_x = dv->get_offset_x();
        win->offset_y = dv->get_offset_y();
    }

    // For validation we need num_pages — use the window's buffer doc if set.
    Document* val_doc = (!win->buffer_id.isEmpty())
                         ? registry->lookup(win->buffer_id)
                         : doc;
    if (!val_doc) {
        bridge->send_fail(id, "no buffer loaded in this window");
        return;
    }

    if (msg.contains("page")) {
        const QJsonValue v = msg.value("page");
        if (!v.isDouble()) { bridge->send_fail(id, "'page' must be integer"); return; }
        const int p = v.toInt();
        if (p < 0)              { bridge->send_fail(id, "page must be >= 0"); return; }
        if (p >= val_doc->num_pages()) {
            bridge->send_fail(id, QString("page %1 out of range (num-pages=%2)")
                                    .arg(p).arg(val_doc->num_pages()));
            return;
        }
    }
    if (msg.contains("zoom")) {
        if (!msg.value("zoom").isDouble()) { bridge->send_fail(id, "'zoom' must be numeric"); return; }
        if (msg.value("zoom").toDouble() <= 0) { bridge->send_fail(id, "zoom must be > 0"); return; }
    }
    if (msg.contains("offset-y") && !msg.value("offset-y").isDouble()) {
        bridge->send_fail(id, "'offset-y' must be numeric"); return;
    }
    if (msg.contains("offset-x") && !msg.value("offset-x").isDouble()) {
        bridge->send_fail(id, "'offset-x' must be numeric"); return;
    }
    if (msg.contains("engine-params") && !msg.value("engine-params").isObject()) {
        bridge->send_fail(id, "'engine-params' must be an object"); return;
    }

    // Apply to per-window state.
    if (msg.contains("zoom")) {
        win->zoom = static_cast<float>(msg.value("zoom").toDouble());
        if (is_active) dv->set_zoom_level(win->zoom, true, true);
    }
    if (msg.contains("page")) {
        win->page = msg.value("page").toInt();
        if (is_active) dv->goto_page(win->page);
    }
    if (msg.contains("offset-y")) {
        win->offset_y = static_cast<float>(msg.value("offset-y").toDouble());
        if (is_active) dv->set_offsets(win->offset_x, win->offset_y, true);
    }
    if (msg.contains("offset-x")) {
        win->offset_x = static_cast<float>(msg.value("offset-x").toDouble());
        if (is_active) dv->set_offsets(win->offset_x, win->offset_y, true);
    }
    if (msg.contains("engine-params")) {
        const QJsonObject ep = msg.value("engine-params").toObject();
        if (ep.contains("dark-mode")) {
            const bool dm = ep.value("dark-mode").toBool();
            win->dark_mode = dm;
            if (is_active) main_widget->opengl_widget()->set_dark_mode(dm);
        }
        if (ep.contains("rotation")) {
            const int target = ep.value("rotation").toInt();
            if (target % 90 == 0 && target >= 0 && target < 360) {
                if (is_active) {
                    int diff = (target - win->rotation + 360) % 360;
                    const int steps = diff / 90;
                    for (int i = 0; i < steps; ++i) dv->rotate();
                }
                win->rotation = target;
            }
        }
    }

    // v0.36-dogfood: rebuild overlay raster after any view-state change.
    // The overlay paint code maps page-norm / absolute coords to window
    // pixels via the DocumentView, so when scroll / zoom / rotation
    // shift, the selection rect + overlay layers need re-painting at
    // the new pixel positions. Without this, raster stays stale and
    // selection appears to detach from the PDF when the user scrolls.
    if (is_active && (msg.contains("page") || msg.contains("zoom") ||
                       msg.contains("offset-x") || msg.contains("offset-y") ||
                       msg.contains("engine-params"))) {
        int rw = 1200, rh = 900;
        if (auto* gl = main_widget->opengl_widget()) {
            if (gl->width()  > 0) rw = gl->width();
            if (gl->height() > 0) rh = gl->height();
        }
        rebuild_overlay_raster(rw, rh);
    }

    if (is_active) main_widget->opengl_widget()->update();
    bridge->send_ok(id);
}

// ─── minibuffer/* (SPEC §5.4) ─────────────────────────────────────────
//
// Single-instance widget state in LimnCommand. The actual visible
// widget lands in a later batch; here we just track open/prompt/text
// and route keystrokes via minibuffer_handle_key.

// Mirror minibuffer state to the chrome widget (if MainWidget has one).
// Called after every minibuffer state mutation. Safe in headless / unit-
// test mode where chrome_bar() may be null.
namespace {
inline LimnChromeBar* chrome_of(MainWidget* mw) {
    return mw ? mw->chrome_bar() : nullptr;
}

// v0.16: codepoint ↔ UTF-16 index helpers. Live here (rather than next
// to the buffer/* handlers further down) so cmd_minibuffer_get can use
// them too. See the comment block at the second declaration site for
// rationale; THIS block is the canonical definition.
int cp_count(const QString& s) {
    int n = 0;
    for (int i = 0; i < s.size(); ++i)
        if (!s.at(i).isLowSurrogate()) ++n;
    return n;
}

int cp_to_qsidx(const QString& s, int cp_idx) {
    if (cp_idx < 0) return -1;
    int cp = 0, i = 0;
    while (i < s.size() && cp < cp_idx) {
        if (i + 1 < s.size()
            && s.at(i).isHighSurrogate()
            && s.at(i + 1).isLowSurrogate()) i += 2;
        else                                 i += 1;
        ++cp;
    }
    if (cp != cp_idx) return -1;
    return i;
}

int qsidx_to_cp(const QString& s, int qs_idx) {
    if (qs_idx < 0 || qs_idx > s.size()) return -1;
    int cp = 0, i = 0;
    while (i < qs_idx) {
        if (i + 1 < s.size()
            && s.at(i).isHighSurrogate()
            && s.at(i + 1).isLowSurrogate()) {
            if (i + 1 == qs_idx) return -1;
            i += 2;
        } else {
            i += 1;
        }
        ++cp;
    }
    return cp;
}
}

void LimnCommand::cmd_minibuffer_open(const QString& id, const QJsonObject& msg) {
    minibuffer_open   = true;
    minibuffer_prompt = msg.value("prompt").toString();   // empty = no prompt
    text_buffers["*minibuffer*"].clear();                 // fresh each open
    if (auto* c = chrome_of(main_widget))
        c->set_minibuffer(true, minibuffer_prompt, text_buffers["*minibuffer*"].to_qstring());
    bridge->send_ok(id);
}

void LimnCommand::cmd_minibuffer_close(const QString& id, const QJsonObject&) {
    minibuffer_open = false;
    if (auto* c = chrome_of(main_widget))
        c->set_minibuffer(false, QString(), QString());
    bridge->send_ok(id);
}

void LimnCommand::cmd_minibuffer_set_prompt(const QString& id, const QJsonObject& msg) {
    if (!minibuffer_open) {
        bridge->send_fail(id, "minibuffer/set-prompt: minibuffer is not open");
        return;
    }
    minibuffer_prompt = msg.value("prompt").toString();
    if (auto* c = chrome_of(main_widget))
        c->set_minibuffer(true, minibuffer_prompt, text_buffers["*minibuffer*"].to_qstring());
    bridge->send_ok(id);
}

void LimnCommand::cmd_minibuffer_set_text(const QString& id, const QJsonObject& msg) {
    if (!minibuffer_open) {
        bridge->send_fail(id, "minibuffer/set-text: minibuffer is not open");
        return;
    }
    {
        GapBuffer& mb = text_buffers["*minibuffer*"];
        mb.clear();
        mb.insert(0, msg.value("text").toString());
        // After set-text, cursor goes to end — Emacs convention, lets the
        // user keep typing to extend. v0.12 batch 20 added cursor-aware
        // insertion in minibuffer_handle_key; this keeps set-text+typing
        // composable.
        text_cursors["*minibuffer*"] = mb.length();
        if (auto* c = chrome_of(main_widget))
            c->set_minibuffer(true, minibuffer_prompt, mb.to_qstring());
    }
    bridge->send_ok(id);
}

void LimnCommand::cmd_minibuffer_get(const QString& id, const QJsonObject&) {
    QJsonObject data;
    data.insert("open",   minibuffer_open);
    data.insert("prompt", minibuffer_prompt);
    const QString mb_text = text_buffers["*minibuffer*"].to_qstring();
    data.insert("text",   mb_text);
    // v0.16: :cursor is codepoint count from start of buffer (matches
    // buffer/cursor-get :offset). Internally text_cursors holds UTF-16
    // index; convert at the wire boundary so non-BMP characters (emoji,
    // CJK Ext-B) don't double-count.
    {
        // mb_text already materialised above — reuse it for cp conversion.
        int qs_idx = text_cursors["*minibuffer*"];
        int cp = qsidx_to_cp(mb_text, qs_idx);
        if (cp < 0 && qs_idx > 0) cp = qsidx_to_cp(mb_text, qs_idx - 1);
        if (cp < 0) cp = 0;
        data.insert("cursor", cp);
    }
    bridge->send_ok(id, data);
}

// Called by LimnInputFilter on every KeyPress. Returns TRUE iff this
// keystroke was consumed by the minibuffer (so the filter should not
// also push a normal `key` event). See SPEC §6 Minibuffer 事件.
// v0.16.1: route a real Qt QInputMethodEvent through the same server-
// side dispatch as cmd_test_inject_ime_*. Called by LimnInputFilter
// when QEvent::InputMethod arrives (fcitx → Qt → here).
//
// preedit non-empty → push ime-preedit event (display-only)
// commit  non-empty → push ime-commit  event AND, if minibuffer is
//                     open, insert text + push minibuffer-input
//                     (vanilla-Emacs C-core commit_text semantics)
void LimnCommand::handle_ime_event(const QString& preedit, const QString& commit) {
    if (!preedit.isEmpty() || preedit.length() == 0) {
        // Always fire preedit when called — even with empty string,
        // which is the SPEC §6 "cancel composition" signal. Skip only
        // when both fields are empty AND we have no good signal to fire.
        if (!preedit.isEmpty()) {
            QJsonObject ev;
            ev.insert("frame-id", "f1");
            ev.insert("text", preedit);
            bridge->push_event("ime-preedit", ev);
        }
    }
    if (!commit.isEmpty()) {
        if (minibuffer_open) {
            GapBuffer& buf = text_buffers["*minibuffer*"];
            int&       cur = text_cursors["*minibuffer*"];
            buf.insert(cur, commit);
            cur += commit.length();
            const QString updated = buf.to_qstring();
            if (auto* c = chrome_of(main_widget))
                c->set_minibuffer(true, minibuffer_prompt, updated);
            QJsonObject input_ev;
            input_ev.insert("frame-id", "f1");
            input_ev.insert("text", updated);
            bridge->push_event("minibuffer-input", input_ev);
        }
        QJsonObject ev;
        ev.insert("frame-id", "f1");
        ev.insert("text", commit);
        bridge->push_event("ime-commit", ev);
    }
}

bool LimnCommand::minibuffer_handle_key(const QString& key, const QJsonArray& mods) {
    if (!minibuffer_open) return false;

    // Modifier combos other than Shift fall through to a normal key
    // event — keeps C-g / M-x / Up / Down / etc reachable through
    // global keymap.
    for (const auto& m : mods) {
        const QString s = m.toString();
        if (s != "shift") return false;
    }

    QJsonObject ev;
    ev.insert("frame-id", "f1");

    if (key == "RET") {
        ev.insert("text", text_buffers["*minibuffer*"].to_qstring());
        bridge->push_event("minibuffer-submit", ev);
        // v0.37 Phase F: Emacs convention — RET in minibuffer submits AND
        // closes the widget.  Without this the C++ side stayed open after
        // submit and direct callers (test drivers, third-party code that
        // bypasses make-minibuffer-reader's unwind) saw stale open=true.
        // make-minibuffer-reader still calls minibuffer/close from its
        // unwind — both paths are idempotent, so the double-close is harmless.
        minibuffer_open = false;
        if (auto* c = chrome_of(main_widget))
            c->set_minibuffer(false, "", "");
        return true;
    }
    if (key == "ESC") {
        bridge->push_event("minibuffer-cancel", ev);
        // Same close-on-cancel rationale as RET above.  v027-completing-read
        // Ω4 ("open is false after cancel") was the symptom.
        minibuffer_open = false;
        if (auto* c = chrome_of(main_widget))
            c->set_minibuffer(false, "", "");
        return true;
    }
    // BS — delete character before cursor (current implementation: always
    // at end). emits minibuffer-input with updated text. Maps to A2 TODO
    // entry. v0.12.
    if (key == "BS") {
        GapBuffer& buf = text_buffers["*minibuffer*"];
        if (buf.length() > 0) {
            // v0.16: delete a WHOLE codepoint to the left of cursor — for
            // BMP that's 1 UTF-16 unit, for non-BMP it's 2 (the surrogate
            // pair). Otherwise we'd leave dangling surrogates.
            int cur = text_cursors["*minibuffer*"];
            if (cur > 0 && cur <= buf.length()) {
                const QString s = buf.to_qstring();
                int del_units = 1;
                if (cur >= 2
                    && s.at(cur - 1).isLowSurrogate()
                    && s.at(cur - 2).isHighSurrogate()) {
                    del_units = 2;
                }
                buf.remove(cur - del_units, del_units);
                text_cursors["*minibuffer*"] = cur - del_units;
            }
            const QString updated = buf.to_qstring();
            if (auto* c = chrome_of(main_widget))
                c->set_minibuffer(true, minibuffer_prompt, updated);
            ev.insert("text", updated);
            bridge->push_event("minibuffer-input", ev);
        }
        return true;   // consume even at empty (no key fallback)
    }
    // Left / Right — move cursor without modifying text. v0.16: step by
    // a whole codepoint (skip surrogate pair as one unit).
    if (key == "<left>" || key == "<right>") {
        const QString s = text_buffers["*minibuffer*"].to_qstring();
        int cur = text_cursors["*minibuffer*"];
        const int len = s.length();
        if (key == "<left>" && cur > 0) {
            int step = 1;
            if (cur >= 2 && s.at(cur - 1).isLowSurrogate()
                && s.at(cur - 2).isHighSurrogate()) step = 2;
            text_cursors["*minibuffer*"] = cur - step;
        }
        if (key == "<right>" && cur < len) {
            int step = 1;
            if (cur + 1 < len && s.at(cur).isHighSurrogate()
                && s.at(cur + 1).isLowSurrogate()) step = 2;
            text_cursors["*minibuffer*"] = cur + step;
        }
        return true;
    }
    // Home / End — cursor to start / end.
    if (key == "<home>") { text_cursors["*minibuffer*"] = 0; return true; }
    if (key == "<end>") {
        text_cursors["*minibuffer*"] = text_buffers["*minibuffer*"].length();
        return true;
    }
    // Printable single-character key → accumulate into text.
    // "SPC" is the named form of space — key_to_string in limn_input.cpp
    // always returns "SPC" not " " (so binding "SPC" → cmd works), so
    // minibuffer typing has to translate it back to a real space.
    QString to_append;
    if (key.size() == 1 && key.at(0).isPrint() && !key.at(0).isSpace()) {
        to_append = key;
    } else if (key == "SPC") {
        to_append = " ";
    }
    if (!to_append.isEmpty()) {
        GapBuffer& buf = text_buffers["*minibuffer*"];
        int cur = text_cursors["*minibuffer*"];
        // Insert at cursor (not append at end) — let Left/Right move
        // cursor and have typing land there. v0.12 batch 20.
        if (cur < 0 || cur > buf.length()) cur = buf.length();
        buf.insert(cur, to_append);
        text_cursors["*minibuffer*"] = cur + to_append.length();
        const QString updated = buf.to_qstring();
        if (auto* c = chrome_of(main_widget))
            c->set_minibuffer(true, minibuffer_prompt, updated);
        ev.insert("text", updated);
        bridge->push_event("minibuffer-input", ev);
        return true;
    }
    // Anything else (TAB / BS / arrow keys / etc) is currently NOT
    // consumed. Future: BS deletes a char, Up/Down browse history,
    // TAB completes — for now they fall through and the user can
    // still hit ESC to cancel.
    return false;
}

// ─── message/* (SPEC §5.5) ────────────────────────────────────────────
//
// echo  → echo area + *Messages*
// log   → only *Messages* (silent, for background notifications)
// clear → empty echo area, leave *Messages* alone
//
// v0.7 state-only: messages_log accumulates everything, echo_area_text
// holds what would be shown in the bottom status line. Widget rendering
// lands in a later batch.

// message/* writes to the reserved chrome buffers. Following Emacs:
//   echo → append to *messages* (the log) AND replace *echo-area* (display)
//   log  → only append to *messages* (silent / background)
//   clear→ wipe *echo-area* only; *messages* history untouched

void LimnCommand::cmd_message_echo(const QString& id, const QJsonObject& msg) {
    const QString text = msg.value("text").toString();
    if (text.isEmpty()) {
        bridge->send_fail(id, "message/echo: text must be non-empty");
        return;
    }
    GapBuffer& log = text_buffers["*messages*"];
    if (!log.is_empty()) log.insert(log.length(), "\n");
    log.insert(log.length(), text);
    text_buffers["*echo-area*"].clear();
    text_buffers["*echo-area*"].insert(0, text);
    if (auto* c = chrome_of(main_widget)) c->set_echo(text);
    bridge->send_ok(id);
}

void LimnCommand::cmd_message_log(const QString& id, const QJsonObject& msg) {
    const QString text = msg.value("text").toString();
    if (text.isEmpty()) {
        bridge->send_fail(id, "message/log: text must be non-empty");
        return;
    }
    GapBuffer& log = text_buffers["*messages*"];
    if (!log.is_empty()) log.insert(log.length(), "\n");
    log.insert(log.length(), text);
    bridge->send_ok(id);
}

void LimnCommand::cmd_message_clear(const QString& id, const QJsonObject&) {
    text_buffers["*echo-area*"].clear();
    if (auto* c = chrome_of(main_widget)) c->set_echo(QString());
    bridge->send_ok(id);
}

// ─── modeline/* (SPEC §5.6) ───────────────────────────────────────────
//
// v0.7: state-only storage — set / get round-trip through LimnWindow
// fields. The actual widget that renders this on screen lands in a
// later batch (Qt widgets for chrome). Tests assert state behaviour;
// implementing that first means we can validate the wire protocol
// independently of rendering.

void LimnCommand::cmd_modeline_set(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    if (win_id.isEmpty()) {
        bridge->send_fail(id, "modeline/set requires win-id");
        return;
    }
    LimnWindow* win = windows->get(win_id);
    if (!win) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    // Partial update: only fields actually present are touched.
    if (msg.contains("left"))   win->modeline_left   = msg.value("left").toString();
    if (msg.contains("middle")) win->modeline_middle = msg.value("middle").toString();
    if (msg.contains("right"))  win->modeline_right  = msg.value("right").toString();
    if (auto* c = chrome_of(main_widget)) {
        c->set_modeline(win->modeline_left, win->modeline_middle, win->modeline_right);
    }
    bridge->send_ok(id);
}

void LimnCommand::cmd_modeline_get(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    if (win_id.isEmpty()) {
        bridge->send_fail(id, "modeline/get requires win-id");
        return;
    }
    LimnWindow* win = windows->get(win_id);
    if (!win) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    QJsonObject data;
    data.insert("left",   win->modeline_left);
    data.insert("middle", win->modeline_middle);
    data.insert("right",  win->modeline_right);
    bridge->send_ok(id, data);
}

// ─── view/overlays ────────────────────────────────────────────────────
//
// Each layer is validated: type ∈ {rect,line,text}; required geometry
// fields per type; color must be #RRGGBB; opacity is numeric (out-of-range
// values are accepted — spec says "rejected OR clamped").
//
// For headless mode we don't actually paint anything — the OpenGL widget
// has no layout. We just count the layers so test/snapshot can report.

namespace {

bool is_valid_hex_color(const QString& c) {
    if (c.length() != 7 || !c.startsWith('#')) return false;
    for (int i = 1; i < 7; ++i) {
        const QChar ch = c.at(i);
        if (!((ch >= '0' && ch <= '9') ||
              (ch >= 'a' && ch <= 'f') ||
              (ch >= 'A' && ch <= 'F'))) return false;
    }
    return true;
}

bool is_valid_pos_array(const QJsonValue& v) {
    if (!v.isArray()) return false;
    auto a = v.toArray();
    if (a.size() != 2) return false;
    return a[0].isDouble() && a[1].isDouble();
}

bool is_valid_rect_array(const QJsonValue& v) {
    if (!v.isArray()) return false;
    auto a = v.toArray();
    if (a.size() != 4) return false;
    for (int i = 0; i < 4; ++i)
        if (!a[i].isDouble()) return false;
    return true;
}

QString validate_layer(const QJsonObject& layer) {
    const QString type = layer.value("type").toString();
    if (type.isEmpty()) return QStringLiteral("layer missing 'type'");

    // v0.33b: text-range layers live in text-buffer codepoint space, not
    // PDF page space — they don't need 'page'/'color'. Validate them
    // separately and short-circuit.
    if (type == "text-range") {
        if (!layer.contains("buf-id") || layer.value("buf-id").toString().isEmpty())
            return QStringLiteral("text-range overlay missing 'buf-id'");
        if (!layer.contains("start") || !layer.value("start").isDouble())
            return QStringLiteral("text-range overlay missing 'start'");
        if (!layer.contains("end")   || !layer.value("end").isDouble())
            return QStringLiteral("text-range overlay missing 'end'");
        if (layer.contains("opacity") && !layer.value("opacity").isDouble())
            return QStringLiteral("text-range 'opacity' must be numeric");
        if (layer.contains("color")
            && !is_valid_hex_color(layer.value("color").toString()))
            return QStringLiteral("text-range 'color' must be #RRGGBB");
        // face/color: at least one (face resolved at paint time).
        return QString();
    }

    if (!layer.contains("page") || !layer.value("page").isDouble())
        return QStringLiteral("layer missing or invalid 'page'");
    const int page = layer.value("page").toInt();
    if (page < 0) return QStringLiteral("layer 'page' must be >= 0");

    // v0.33b: 'face' may substitute for 'color' — the face registry
    // supplies the foreground hex at paint time. Without either, the
    // layer can't render.
    const bool has_face  = layer.contains("face")
                            && !layer.value("face").toString().isEmpty();
    const bool has_color = layer.contains("color");
    if (!has_face && !has_color)
        return QStringLiteral("layer missing 'color' (or 'face')");
    if (has_color && !is_valid_hex_color(layer.value("color").toString()))
        return QStringLiteral("layer 'color' must be #RRGGBB");

    if (!layer.contains("opacity"))
        return QStringLiteral("layer missing 'opacity'");
    if (!layer.value("opacity").isDouble())
        return QStringLiteral("layer 'opacity' must be numeric");

    if (type == "rect") {
        // v0.33a accepts either 'rect': [x0,y0,x1,y1] (canonical) OR the
        // four-field x0/y0/x1/y1 form (sugar). Both reach the same painter.
        const bool has_rect = layer.contains("rect");
        const bool has_xy   = layer.contains("x0") && layer.contains("y0")
                           && layer.contains("x1") && layer.contains("y1");
        if (!has_rect && !has_xy)
            return QStringLiteral("rect overlay missing 'rect' (or x0/y0/x1/y1)");
        if (has_rect && !is_valid_rect_array(layer.value("rect")))
            return QStringLiteral("rect 'rect' must be [x0,y0,x1,y1]");
        if (has_xy) {
            for (const char* k : {"x0","y0","x1","y1"})
                if (!layer.value(k).isDouble())
                    return QStringLiteral("rect x0/y0/x1/y1 must be numeric");
        }
    } else if (type == "line") {
        if (!layer.contains("from") || !layer.contains("to"))
            return QStringLiteral("line overlay missing 'from' or 'to'");
        if (!is_valid_pos_array(layer.value("from")) ||
            !is_valid_pos_array(layer.value("to")))
            return QStringLiteral("line 'from'/'to' must be [x,y]");
    } else if (type == "text") {
        if (!layer.contains("text"))
            return QStringLiteral("text overlay missing 'text'");
        if (!layer.contains("pos") || !is_valid_pos_array(layer.value("pos")))
            return QStringLiteral("text overlay missing valid 'pos'");
        if (!layer.contains("size") || !layer.value("size").isDouble())
            return QStringLiteral("text overlay missing 'size'");
        if (layer.value("size").toDouble() <= 0)
            return QStringLiteral("text overlay 'size' must be > 0");
    } else {
        return QString("unknown overlay type: %1").arg(type);
    }
    return QString();   // empty = OK
}

}  // anonymous namespace

void LimnCommand::cmd_view_overlays(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    LimnWindow* win = windows->get(win_id);
    if (!win) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    // 'layers' may be missing/null (treated as empty list = clear overlays)
    QJsonArray layers;
    if (msg.contains("layers")) {
        QJsonValue lv = msg.value("layers");
        if (lv.isArray())        layers = lv.toArray();
        else if (lv.isNull())    /* empty */;
        else { bridge->send_fail(id, "'layers' must be an array"); return; }
    }

    // Validate every layer before accepting any (atomicity).
    for (const QJsonValue& lv : layers) {
        if (!lv.isObject()) { bridge->send_fail(id, "layer must be object"); return; }
        QString err = validate_layer(lv.toObject());
        if (!err.isEmpty()) { bridge->send_fail(id, err); return; }
    }

    // v0.14: persist the full layers array (not just the count). paintGL
    // reads from win->overlays; view/get returns it for Lisp introspect.
    win->overlays      = layers;
    win->overlay_count = layers.size();
    // Rebuild the deterministic side-raster IMMEDIATELY so test pixel
    // sampling sees up-to-date overlays without waiting for a real
    // paintGL cycle. Use opengl_widget's current size (fall back to a
    // sane default if widget not yet sized in headless).
    int rw = 1200, rh = 900;
    // v0.33b: when the focused window is showing a text-engine buffer,
    // the surface tests sample IS the QPlainTextEdit, so the raster must
    // match its geometry — not the (hidden) opengl widget's.
    if (text_buffers.contains(win->buffer_id)) {
        if (auto* tw = main_widget->text_widget()) {
            if (tw->viewport()->width()  > 0) rw = tw->viewport()->width();
            if (tw->viewport()->height() > 0) rh = tw->viewport()->height();
        }
    } else if (auto* gl = main_widget->opengl_widget()) {
        if (gl->width()  > 0) rw = gl->width();
        if (gl->height() > 0) rh = gl->height();
    }
    rebuild_overlay_raster(rw, rh);
    if (auto* gl = main_widget->opengl_widget()) gl->update();
    bridge->send_ok(id);
}

// ─── display/sync-faces (v0.25 face registry) ────────────────────────
void LimnCommand::cmd_display_sync_faces(const QString& id, const QJsonObject& msg)
{
    face_registry_.clear();
    const QJsonArray faces = msg.value("faces").toArray();
    for (const QJsonValue& v : faces) {
        QJsonObject f = v.toObject();
        const QString name = f.value("name").toString();
        if (name.isEmpty()) continue;
        LimnFaceEntry entry;
        entry.foreground = f.value("foreground").toString();
        entry.background = f.value("background").toString();
        entry.bold       = f.value("bold").toBool(false);
        entry.italic     = f.value("italic").toBool(false);
        entry.underline  = f.value("underline").toBool(false);
        face_registry_.insert(name, entry);
    }
    bridge->send_ok(id);
}

// ─── view/selection-* (SPEC §5.2 addition, v0.15.1) ──────────────────
//
// Per-window visual selection state. Coords are page-relative norm
// [0,1]² (same contract as view/overlays rect coords) so callers can
// describe selections without knowing sioyek's AbsoluteDocumentPos.
//
// The selection paints into overlay_raster (yellow semi-transparent)
// when its owning window is focused — see rebuild_overlay_raster.

namespace {
// Validate {:|page| n :|x| f :|y| f} object. Returns "" if OK.
QString validate_sel_pos(const QJsonValue& v) {
    if (!v.isObject()) return "begin/end must be objects";
    QJsonObject o = v.toObject();
    if (!o.value("page").isDouble()) return "begin/end :page must be int";
    if (!o.value("x").isDouble())    return "begin/end :x must be number";
    if (!o.value("y").isDouble())    return "begin/end :y must be number";
    return QString();
}
// v0.15.2: extract the actual selected text via sioyek's
// DocumentView::get_text_selection. Converts our page-norm coords
// (x,y ∈ [0,1] of the page rect) into the AbsoluteDocumentPos space
// sioyek wants. Falls back to a synthetic string if the extraction
// turns up empty (e.g., selection over a graphics-only region — still
// gives tests something deterministic to compare).
QString synth_sel_text(const QJsonObject& begin, const QJsonObject& end) {
    return QString("[sel p%1:%2,%3→p%4:%5,%6]")
        .arg(begin.value("page").toInt())
        .arg(begin.value("x").toDouble(), 0, 'f', 3)
        .arg(begin.value("y").toDouble(), 0, 'f', 3)
        .arg(end.value("page").toInt())
        .arg(end.value("x").toDouble(), 0, 'f', 3)
        .arg(end.value("y").toDouble(), 0, 'f', 3);
}

// Translate page-norm (page, nx, ny) → AbsoluteDocumentPos using
// the loaded Document's page geometry. Returns false if doc/page is
// invalid (caller should fall back to synth text).
bool page_norm_to_absolute(Document* doc, int page, double nx, double ny,
                            AbsoluteDocumentPos* out) {
    if (!doc) return false;
    if (page < 0 || page >= doc->num_pages()) return false;
    DocumentPos dp;
    dp.page = page;
    dp.x = static_cast<float>(nx * doc->get_page_width(page));
    dp.y = static_cast<float>(ny * doc->get_page_height(page));
    *out = dp.to_absolute(doc);
    return true;
}

// Extract real text via sioyek's get_text_selection. Empty string on
// any failure (caller decides whether to fall back to synth).
QString extract_selection_text(DocumentView* dv, Document* doc,
                                const QJsonObject& begin,
                                const QJsonObject& end,
                                const QString& mode) {
    if (!dv || !doc) return QString();
    AbsoluteDocumentPos bp, ep;
    if (!page_norm_to_absolute(doc, begin.value("page").toInt(),
                                begin.value("x").toDouble(),
                                begin.value("y").toDouble(), &bp)) return QString();
    if (!page_norm_to_absolute(doc, end.value("page").toInt(),
                                end.value("x").toDouble(),
                                end.value("y").toDouble(), &ep)) return QString();
    std::deque<AbsoluteRect> rects;
    std::wstring text;
    const bool is_word = (mode == "word");
    dv->get_text_selection(bp, ep, is_word, rects, text);
    return QString::fromStdWString(text);
}
}

void LimnCommand::cmd_view_selection_set(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    LimnWindow* win = windows->get(win_id);
    if (!win) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    QString err;
    err = validate_sel_pos(msg.value("begin"));
    if (!err.isEmpty()) { bridge->send_fail(id, err); return; }
    err = validate_sel_pos(msg.value("end"));
    if (!err.isEmpty()) { bridge->send_fail(id, err); return; }

    win->selection_begin  = msg.value("begin").toObject();
    win->selection_end    = msg.value("end").toObject();
    win->selection_mode   = msg.value("mode").toString("char");
    win->selection_active = true;
    // v0.15.2: try real sioyek extraction first. Only works for the
    // focused window (since extraction goes through the live DV's
    // document). For non-focused windows we fall back to synth text,
    // which is still deterministic + distinguishable across coords.
    QString real_text;
    if (windows->focused_id() == win_id) {
        DocumentView* dv = main_widget ? main_widget->document_view() : nullptr;
        Document* doc    = dv ? dv->get_document() : nullptr;
        real_text = extract_selection_text(dv, doc,
                                            win->selection_begin,
                                            win->selection_end,
                                            win->selection_mode);
    }
    win->selection_text = real_text.isEmpty()
        ? synth_sel_text(win->selection_begin, win->selection_end)
        : real_text;

    // If this window is focused, the visible raster needs to redraw
    // (so the selection rect appears immediately for pixel sampling).
    if (windows->focused_id() == win_id) {
        int rw = 1200, rh = 900;
        if (auto* gl = main_widget->opengl_widget()) {
            if (gl->width()  > 0) rw = gl->width();
            if (gl->height() > 0) rh = gl->height();
        }
        rebuild_overlay_raster(rw, rh);
        if (main_widget && main_widget->opengl_widget()) {
            main_widget->opengl_widget()->update();
        }
    }

    QJsonObject data;
    data.insert("selected-text", win->selection_text);
    bridge->send_ok(id, data);
}

void LimnCommand::cmd_view_selection_get(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    LimnWindow* win = windows->get(win_id);
    if (!win) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    QJsonObject data;
    data.insert("active", win->selection_active);
    if (win->selection_active) {
        data.insert("begin", win->selection_begin);
        data.insert("end",   win->selection_end);
        data.insert("mode",  win->selection_mode);
        data.insert("text",  win->selection_text);
    }
    bridge->send_ok(id, data);
}

void LimnCommand::cmd_view_selection_clear(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    LimnWindow* win = windows->get(win_id);
    if (!win) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    win->selection_active = false;
    win->selection_begin  = QJsonObject();
    win->selection_end    = QJsonObject();
    win->selection_text   = QString();
    if (windows->focused_id() == win_id) {
        int rw = 1200, rh = 900;
        if (auto* gl = main_widget->opengl_widget()) {
            if (gl->width()  > 0) rw = gl->width();
            if (gl->height() > 0) rh = gl->height();
        }
        rebuild_overlay_raster(rw, rh);
        if (main_widget && main_widget->opengl_widget()) {
            main_widget->opengl_widget()->update();
        }
    }
    bridge->send_ok(id);
}

// ─── view/get ─────────────────────────────────────────────────────────

void LimnCommand::cmd_view_get(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    if (!windows->has(win_id)) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    bridge->send_ok(id, collect_view_state(win_id));
}

// ─── buffer/open ──────────────────────────────────────────────────────

void LimnCommand::cmd_buffer_open(const QString& id, const QJsonObject& msg) {
    const QString engine = msg.value("engine").toString();
    const QString path   = msg.value("path").toString();

    if (engine.isEmpty() || path.isEmpty()) {
        bridge->send_fail(id, "missing required field: engine and path are required");
        return;
    }
    if (engine != "mupdf") {
        bridge->send_fail(id, QString("unknown engine: %1").arg(engine));
        return;
    }

    // For v0.2: use the main view's open path; buffer/open shows in main
    // window as a side effect (single-window limitation). Will be fixed in
    // phase 10 when multiple windows exist.
    if (!main_widget->open_document(q_to_w(path))) {
        const QString err = QString("failed to open: %1").arg(path);
        bridge->send_fail(id, err);
        QJsonObject ev;
        ev.insert("cmd",     QStringLiteral("buffer/open"));
        ev.insert("message", err);
        bridge->push_event("error", ev);
        return;
    }
    Document* doc = main_widget->document_view()->get_document();
    if (!doc) {
        bridge->send_fail(id, "document loaded but not retrievable");
        return;
    }
    const QString buffer_id = registry->register_buffer(doc);

    // buffer/open attaches to the focused/default tiled window for now.
    LimnWindow* fw = windows->get(windows->focused_id());
    if (!fw) fw = windows->get("w1");
    if (fw) {
        fw->buffer_id     = buffer_id;
        fw->page          = 0;
        fw->zoom          = 1.0f;
        fw->offset_x      = 0.0f;
        fw->offset_y      = 0.0f;
        fw->dark_mode     = false;
        fw->rotation      = 0;
        fw->overlay_count = 0;
        fw->overlays      = QJsonArray();   /* v0.14 */ rebuild_overlay_raster(overlay_raster.width(), overlay_raster.height());
    }
    main_widget->opengl_widget()->set_dark_mode(false);

    bridge->send_ok(id, build_open_data(buffer_id, doc));
    emit_buffer_opened(buffer_id, doc, engine);
}

// ─── buffer/close ─────────────────────────────────────────────────────

void LimnCommand::cmd_buffer_close(const QString& id, const QJsonObject& msg) {
    const QString buffer_id = msg.value("buffer-id").toString();
    if (buffer_id.isEmpty()) {
        bridge->send_fail(id, "missing 'buffer-id'");
        return;
    }

    // Text-engine buffer? Refuse to close reserved chrome ones (they're
    // bootstrapped at startup and must always exist). Allow tN closes.
    if (text_buffers.contains(buffer_id)) {
        if (buffer_id.startsWith('*')) {
            bridge->send_fail(id, QString("can't close reserved chrome buffer: %1")
                                  .arg(buffer_id));
            return;
        }
        text_buffers.remove(buffer_id);
        text_cursors.remove(buffer_id);
        buffer_paths.remove(buffer_id);   // v0.22 §A
        for (const QString& wid : windows->all_ids()) {
            LimnWindow* w = windows->get(wid);
            if (w && w->buffer_id == buffer_id) w->buffer_id.clear();
        }
        bridge->send_ok(id);
        emit_buffer_closed(buffer_id);
        return;
    }

    // mupdf path
    if (!registry->lookup(buffer_id)) {
        bridge->send_fail(id, QString("unknown buffer-id: %1").arg(buffer_id));
        return;
    }
    registry->unregister(buffer_id);
    for (const QString& wid : windows->all_ids()) {
        LimnWindow* w = windows->get(wid);
        if (w && w->buffer_id == buffer_id) w->buffer_id.clear();
    }
    // v0.17: drop any user bookmarks attached to this buffer. Lisp
    // clients that want persistence have already sidecar'd them by now.
    bookmarks.remove(buffer_id);
    bridge->send_ok(id);
    emit_buffer_closed(buffer_id);
}

// ─── SPEC v0.5 §5.3 後段 — text-engine 編輯 primitives ─────────────────
//
// 共通約定：
//   - 只對 text engine（buffer-id 在 text_buffers）生效；mupdf 等 read
//     only engine 一律回 "not supported"。
//   - cursor 是 buffer-local 的 int offset (0 .. text.length())。
//   - insert 預設在 cursor 處插入並推進 cursor。
//   - delete [from, to) 半開區間；cursor 落在被刪範圍內 → 移到 from；
//     落在範圍之後 → 跟著左移；之前不變。

namespace {
// Validate "this buffer-id is a text-engine buffer in our registry".
// Returns true and outputs buffer-id; false and sends fail otherwise.
bool resolve_text_buffer(LimnBridge* bridge,
                         const QHash<QString, GapBuffer>& text_buffers,
                         const QString& id, const QJsonObject& msg,
                         QString& out_buf) {
    const QString buf = msg.value("buffer-id").toString();
    if (buf.isEmpty()) {
        bridge->send_fail(id, "missing 'buffer-id'");
        return false;
    }
    if (!text_buffers.contains(buf)) {
        bridge->send_fail(id, "not supported (buffer is not a text-engine buffer)");
        return false;
    }
    out_buf = buf;
    return true;
}
// v0.16 codepoint helpers (cp_count / cp_to_qsidx / qsidx_to_cp) are
// defined in the earlier anonymous namespace near chrome_of(), so
// cmd_minibuffer_get above this point can also use them.
}  // anonymous

// v0.16 cursor / edit handlers — all wire offsets are CODEPOINT indices.
// Internally we still store QString (UTF-16); convert at every wire
// boundary via the cp_count / cp_to_qsidx / qsidx_to_cp helpers above.

void LimnCommand::cmd_buffer_cursor_get(const QString& id, const QJsonObject& msg) {
    QString buf;
    if (!resolve_text_buffer(bridge, text_buffers, id, msg, buf)) return;
    const QString s = text_buffers.value(buf).to_qstring();
    int qs_idx = text_cursors.value(buf, 0);
    int cp = qsidx_to_cp(s, qs_idx);
    // If cursor somehow lands mid-surrogate (shouldn't with v0.16 setters,
    // but defensive against pre-v0.16 leftovers): snap to the nearest
    // valid codepoint boundary by clamping qs_idx down by 1.
    if (cp < 0 && qs_idx > 0) cp = qsidx_to_cp(s, qs_idx - 1);
    if (cp < 0) cp = 0;
    QJsonObject data;
    data.insert("offset", cp);
    bridge->send_ok(id, data);
}

void LimnCommand::cmd_buffer_cursor_set(const QString& id, const QJsonObject& msg) {
    QString buf;
    if (!resolve_text_buffer(bridge, text_buffers, id, msg, buf)) return;
    if (!msg.contains("offset") || !msg.value("offset").isDouble()) {
        bridge->send_fail(id, "missing or invalid 'offset'");
        return;
    }
    const int cp_offset = msg.value("offset").toInt();
    const QString s = text_buffers.value(buf).to_qstring();
    const int total_cp = cp_count(s);
    if (cp_offset < 0 || cp_offset > total_cp) {
        bridge->send_fail(id, QString("offset %1 out of range [0, %2]")
                              .arg(cp_offset).arg(total_cp));
        return;
    }
    text_cursors[buf] = cp_to_qsidx(s, cp_offset);
    bridge->send_ok(id);
}

void LimnCommand::cmd_buffer_insert(const QString& id, const QJsonObject& msg) {
    QString buf;
    if (!resolve_text_buffer(bridge, text_buffers, id, msg, buf)) return;
    const QString text = msg.value("text").toString();
    if (text.isEmpty()) {
        bridge->send_fail(id, "missing or empty 'text'");
        return;
    }
    GapBuffer& content = text_buffers[buf];
    int& cursor        = text_cursors[buf];           // UTF-16 index internally

    int qs_at;
    int cp_pos;          // v0.23.1 §D8 — capture pre-insertion cp position
    {
        const QString s    = content.to_qstring();
        const int total_cp = cp_count(s);
        if (msg.contains("at") && msg.value("at").isDouble()) {
            const int cp_at = msg.value("at").toInt();
            if (cp_at < 0 || cp_at > total_cp) {
                bridge->send_fail(id, QString("'at' offset %1 out of range [0, %2]")
                                      .arg(cp_at).arg(total_cp));
                return;
            }
            qs_at  = cp_to_qsidx(s, cp_at);
            cp_pos = cp_at;
        } else {
            qs_at  = cursor;
            cp_pos = qsidx_to_cp(s, cursor);
        }
    }
    content.insert(qs_at, text);
    // Cursor shifts (in UTF-16 internal units): AT-or-BEFORE-cursor
    // insertion pushes cursor right by text's UTF-16 length; AFTER-cursor
    // insertion leaves cursor in place.
    if (qs_at <= cursor) cursor += text.length();
    sync_text_widget(buf);   // v0.22 §C — keep display in sync

    // v0.23.1 §D8 — emit buffer-modified for the Lisp undo subsystem.
    {
        QJsonObject ev;
        ev.insert("buffer-id", buf);
        ev.insert("op",        "insert");
        ev.insert("pos",       cp_pos);
        ev.insert("len",       cp_count(text));
        ev.insert("before",    QString(""));
        ev.insert("after",     text);
        bridge->push_event("buffer-modified", ev);
    }
    bridge->send_ok(id);
}

void LimnCommand::cmd_buffer_delete(const QString& id, const QJsonObject& msg) {
    QString buf;
    if (!resolve_text_buffer(bridge, text_buffers, id, msg, buf)) return;
    if (!msg.contains("from") || !msg.value("from").isDouble() ||
        !msg.contains("to")   || !msg.value("to").isDouble()) {
        bridge->send_fail(id, "missing or invalid 'from' / 'to'");
        return;
    }
    const int cp_from = msg.value("from").toInt();
    const int cp_to   = msg.value("to").toInt();
    GapBuffer& content = text_buffers[buf];
    const QString s    = content.to_qstring();
    const int total_cp = cp_count(s);
    if (cp_from < 0 || cp_to > total_cp || cp_from > cp_to) {
        bridge->send_fail(id, QString("range [%1, %2) out of buffer (cp-len=%3)")
                              .arg(cp_from).arg(cp_to).arg(total_cp));
        return;
    }
    const int qs_from = cp_to_qsidx(s, cp_from);
    const int qs_to   = cp_to_qsidx(s, cp_to);
    // v0.23.1 §D8 — snapshot removed text BEFORE mutation so the event
    // payload's :before field carries the data the Lisp undo system
    // needs to reverse the operation.
    const QString removed = s.mid(qs_from, qs_to - qs_from);
    content.remove(qs_from, qs_to - qs_from);
    // Adjust cursor (UTF-16 internal) based on its position vs deleted range:
    int& cursor = text_cursors[buf];
    if (cursor >= qs_to)        cursor -= (qs_to - qs_from);  // shift left
    else if (cursor > qs_from)  cursor = qs_from;             // snap to start
    sync_text_widget(buf);   // v0.22 §C — keep display in sync

    {
        QJsonObject ev;
        ev.insert("buffer-id", buf);
        ev.insert("op",        "delete");
        ev.insert("pos",       cp_from);
        ev.insert("len",       cp_to - cp_from);
        ev.insert("before",    removed);
        ev.insert("after",     QString(""));
        bridge->push_event("buffer-modified", ev);
    }
    bridge->send_ok(id);
}

// ─── SPEC v0.22 §A — text-engine file I/O ──────────────────────────────
//
//   buffer/load-file  讀檔案 → replace buffer 內容 + cursor 歸零 +
//                     記住 path 到 buffer_paths
//   buffer/save       把 buffer 寫回 buffer_paths 綁定的 path
//
// 兩者均只對 text-engine buffer 有效（mupdf 走 resolve_text_buffer 的
// "not supported" 路徑）。UTF-8 編解碼用 QFile + QTextStream，明確設
// UTF-8 codec。

void LimnCommand::cmd_buffer_load_file(const QString& id, const QJsonObject& msg) {
    QString buf;
    if (!resolve_text_buffer(bridge, text_buffers, id, msg, buf)) return;
    const QString path = msg.value("path").toString();
    if (path.isEmpty()) {
        bridge->send_fail(id, "missing or empty 'path'");
        return;
    }
    QFile f(path);
    if (!f.exists()) {
        bridge->send_fail(id, "file not found");
        return;
    }
    if (!f.open(QIODevice::ReadOnly)) {
        bridge->send_fail(id, QString("cannot open: %1").arg(f.errorString()));
        return;
    }
    QTextStream in(&f);
    in.setEncoding(QStringConverter::Utf8);
    const QString content = in.readAll();
    f.close();

    GapBuffer& gb = text_buffers[buf];
    gb.clear();
    if (!content.isEmpty()) gb.insert(0, content);
    text_cursors[buf] = 0;
    buffer_paths[buf] = path;
    sync_text_widget(buf);   // v0.22 §C — keep display in sync

    QJsonObject ev;
    ev.insert("buffer-id", buf);
    bridge->push_event("text-changed", ev);

    bridge->send_ok(id);
}

void LimnCommand::cmd_buffer_save(const QString& id, const QJsonObject& msg) {
    QString buf;
    if (!resolve_text_buffer(bridge, text_buffers, id, msg, buf)) return;
    if (!buffer_paths.contains(buf)) {
        bridge->send_fail(id, "no path (call buffer/load-file first)");
        return;
    }
    const QString path = buffer_paths.value(buf);
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        bridge->send_fail(id, QString("cannot open for writing: %1").arg(f.errorString()));
        return;
    }
    {
        QTextStream out(&f);
        out.setEncoding(QStringConverter::Utf8);
        out << text_buffers[buf].to_qstring();
    }
    if (!f.commit()) {
        bridge->send_fail(id, QString("write failed: %1").arg(f.errorString()));
        return;
    }
    bridge->send_ok(id);
}

// ─── v0.33b — buffer/codepoint-rects ──────────────────────────────────
//
// Given a codepoint range [start, end) in a text buffer, return one pixel
// rect per visual line (post-wrap). Used by Lisp to:
//   - scroll-into-view
//   - compute tooltip / popup positions
//   - drive the type:"text-range" overlay paint branch (which calls the
//     same compute_text_range_rects helper below)
//
// Coordinate space: text-widget local pixels. Origin (0,0) = widget top-left.
// Wrapped lines yield multiple rects (one per visual line).

QVector<QRectF> LimnCommand::compute_text_range_rects(const QString& buf_id,
                                                      int cp_start, int cp_end) {
    QVector<QRectF> out;
    if (!main_widget) return out;
    QPlainTextEdit* tw = main_widget->text_widget();
    if (!tw) return out;
    if (!text_buffers.contains(buf_id)) return out;

    const QString s = text_buffers.value(buf_id).to_qstring();
    if (cp_start < 0) cp_start = 0;
    if (cp_end   < 0) cp_end   = 0;
    if (cp_end > cp_count(s)) cp_end = cp_count(s);
    if (cp_start >= cp_end) return out;

    // Convert codepoint offsets to UTF-16 indices the QTextDocument speaks.
    const int qs_start = cp_to_qsidx(s, cp_start);
    const int qs_end   = cp_to_qsidx(s, cp_end);
    if (qs_start < 0 || qs_end < 0 || qs_start >= qs_end) return out;

    // Talk to QTextDocument's layout directly. cursorRect() needs a shown
    // widget to return meaningful values — in Xvfb without a window
    // manager, the QPlainTextEdit's viewport never gets resized, so we
    // bypass it. The document layout is always valid.
    //
    // QPlainTextEdit uses QPlainTextDocumentLayout, which is optimised
    // for very large plain-text documents: its blockBoundingRect always
    // returns y=0 (block y is computed per-paint based on cursor scroll).
    // So we accumulate y ourselves by walking blocks linearly.
    QTextDocument* doc = tw->document();
    if (!doc) return out;

    // Give the document a wrap width so line layouts compute against a
    // real width (mirrors what the widget would hand it). Fall back to a
    // sane default if viewport hasn't sized yet.
    int wrap_w = tw->viewport()->width();
    if (wrap_w <= 0) wrap_w = qMax(1, tw->width());
    if (wrap_w <= 0) wrap_w = 800;
    doc->setTextWidth(qreal(wrap_w));

    // First pass: accumulate y offset for every block by summing the
    // height of preceding blocks. Use documentLayout's blockBoundingRect
    // to force per-block layout AND get a reliable height; ignore its
    // (always-zero) y since QPlainTextDocumentLayout doesn't track it.
    qreal y_cursor = 0.0;
    for (QTextBlock b = doc->firstBlock(); b.isValid(); b = b.next()) {
        if (b.position() >= qs_end) break;

        QTextLayout* layout = b.layout();
        if (!layout) continue;
        // blockBoundingRect drives the per-block layout pass + returns
        // its height. Without this, QTextLine objects below have no
        // measurements.
        const qreal block_h =
            doc->documentLayout()->blockBoundingRect(b).height();
        if (block_h <= 0) continue;

        const int blk_start = b.position();
        const int blk_len   = b.length();          // includes trailing newline
        const int sel_lo    = qMax(qs_start, blk_start);
        const int sel_hi    = qMin(qs_end,   blk_start + blk_len);
        if (sel_lo < sel_hi) {
            const int line_count = layout->lineCount();
            for (int li = 0; li < line_count; ++li) {
                QTextLine line = layout->lineAt(li);
                const int line_from = line.textStart();
                const int line_to   = line_from + line.textLength();
                const int abs_from = blk_start + line_from;
                const int abs_to   = blk_start + line_to;
                const int lo = qMax(sel_lo, abs_from);
                const int hi = qMin(sel_hi, abs_to);
                if (lo >= hi) continue;

                const qreal x_lo = line.cursorToX(lo - blk_start);
                const qreal x_hi = line.cursorToX(hi - blk_start);
                const QRectF lrect = line.naturalTextRect();
                const qreal y_top = y_cursor + lrect.top();
                const qreal h     = lrect.height() > 0 ? lrect.height()
                                                       : block_h;
                QRectF r(qMin(x_lo, x_hi),
                         y_top,
                         qAbs(x_hi - x_lo),
                         h);
                // cursorToX returns the same x at line-end positions; give
                // those at least 1px so before-string markers are visible.
                if (r.width() < 1.0) r.setWidth(1.0);
                r.translate(-tw->horizontalScrollBar()->value(),
                            -tw->verticalScrollBar()->value());
                out.append(r);
            }
        }
        y_cursor += block_h;
    }
    return out;
}

void LimnCommand::cmd_buffer_codepoint_rects(const QString& id,
                                              const QJsonObject& msg) {
    const QString buf_id = msg.value("buf-id").toString();
    if (buf_id.isEmpty()) {
        bridge->send_fail(id, "missing 'buf-id'");
        return;
    }
    if (!text_buffers.contains(buf_id)) {
        bridge->send_fail(id, QString("unknown text buffer: %1").arg(buf_id));
        return;
    }
    const int cp_start = msg.value("start").toInt(0);
    const int cp_end   = msg.value("end").toInt(0);

    const QVector<QRectF> rects = compute_text_range_rects(buf_id, cp_start, cp_end);

    QJsonArray arr;
    for (const QRectF& r : rects) {
        QJsonArray rect;
        rect.append(int(r.left()));
        rect.append(int(r.top()));
        rect.append(int(r.right()));
        rect.append(int(r.bottom()));
        QJsonObject item;
        item.insert("page", 0);
        item.insert("rect", rect);
        arr.append(item);
    }
    QJsonObject data;
    data.insert("rects", arr);
    bridge->send_ok(id, data);
}

// ─── SPEC v0.22 §C — text-engine display sync ─────────────────────────
//
// sync_text_widget mirrors the GapBuffer contents into the QPlainTextEdit
// when the targeted buffer is the one currently displayed in any focused
// window. Chrome buffers (*minibuffer*, *echo-area*, *messages*) skip
// this — they have their own rendering surface (LimnChromeBar).
//
// Called after every mutation to text_buffers[BUF] (insert / delete /
// load-file). Cheap when the buffer is not currently displayed, so we
// don't bother gating callers.

void LimnCommand::sync_text_widget(const QString& buffer_id) {
    if (buffer_id.startsWith('*')) return;            // chrome → skip
    if (!main_widget) return;
    QPlainTextEdit* tw = main_widget->text_widget();
    if (!tw) return;
    if (!text_buffers.contains(buffer_id)) return;

    // Find the focused window's buffer-id. If it matches, refresh.
    const QString focused_id = windows->focused_id();
    if (focused_id.isEmpty()) return;
    LimnWindow* win = windows->get(focused_id);
    if (!win || win->buffer_id != buffer_id) return;

    const QString s = text_buffers.value(buffer_id).to_qstring();
    // setPlainText is O(n) per call. For v0.22 this is the simplest
    // path; future work can do delta updates by tracking the last mirror.
    // We avoid recursive scroll-to-cursor by NOT calling moveCursor.
    if (tw->toPlainText() != s) {
        tw->setPlainText(s);
    }
    // Mirror cursor position (UTF-16 offset → QTextCursor position).
    const int qs_idx = text_cursors.value(buffer_id, 0);
    QTextCursor c = tw->textCursor();
    const int max_pos = tw->document()->characterCount() - 1;
    c.setPosition(qBound(0, qs_idx, qMax(0, max_pos)));
    tw->setTextCursor(c);
}

// ─── test/text-widget-snapshot (SPEC v0.22 §C) ────────────────────────
//
// Returns a PNG snapshot of the text widget PLUS aggregate stats used
// by OS-tier visual regression tests (batch-os-text-display.lisp):
//   { width, height, png, avg-luminance, pixel-variance }
//
// QPlainTextEdit::grab() works in Xvfb (unlike QOpenGLWidget which needs
// a GL context the X server can't supply). That's the whole reason the
// text-engine viewport is the first one we can do real visual testing
// on at OS tier.

void LimnCommand::cmd_test_text_widget_snapshot(const QString& id,
                                                 const QJsonObject& msg) {
    Q_UNUSED(msg);
    if (!main_widget) { bridge->send_fail(id, "no main widget"); return; }
    QPlainTextEdit* tw = main_widget->text_widget();
    if (!tw) { bridge->send_fail(id, "no text widget"); return; }

    QPixmap pm = tw->grab();
    QImage img = pm.toImage().convertToFormat(QImage::Format_RGB888);
    const int w = img.width();
    const int h = img.height();

    // Encode PNG.
    QByteArray png_bytes;
    QBuffer png_buf(&png_bytes);
    png_buf.open(QIODevice::WriteOnly);
    img.save(&png_buf, "PNG");

    // Compute luminance stats (Rec.601 weights).
    double sum = 0.0, sum_sq = 0.0;
    qint64 count = 0;
    for (int y = 0; y < h; ++y) {
        const uchar* row = img.constScanLine(y);
        for (int x = 0; x < w; ++x) {
            const int r = row[3 * x + 0];
            const int g = row[3 * x + 1];
            const int b = row[3 * x + 2];
            const double lum = 0.299 * r + 0.587 * g + 0.114 * b;
            sum    += lum;
            sum_sq += lum * lum;
            ++count;
        }
    }
    const double avg = (count > 0) ? (sum / count) : 0.0;
    const double var = (count > 0) ? (sum_sq / count - avg * avg) : 0.0;

    QJsonObject data;
    data.insert("width",          w);
    data.insert("height",         h);
    data.insert("png",            QString::fromUtf8(png_bytes.toBase64()));
    data.insert("avg-luminance",  avg);
    data.insert("pixel-variance", var);
    bridge->send_ok(id, data);
}

// ─── Helpers ──────────────────────────────────────────────────────────

QJsonObject LimnCommand::build_open_data(const QString& buffer_id, Document* doc) {
    QJsonObject data;
    data.insert("buffer-id",  buffer_id);
    data.insert("page-count", doc ? doc->num_pages() : 0);
    data.insert("format",     "pdf");
    data.insert("supports",   LimnMupdf::supports());
    return data;
}

QJsonObject LimnCommand::collect_view_state(const QString& win_id) {
    QJsonObject data;
    LimnWindow* win = windows->get(win_id);
    if (!win) return data;

    Document* doc = (!win->buffer_id.isEmpty())
                     ? registry->lookup(win->buffer_id) : nullptr;

    // For the ACTIVE window, sync the *continuous* fields (offset, zoom)
    // from the live DocumentView. These can drift from LimnWindow whenever
    // the user scrolls in Qt directly: without this sync, a subsequent
    // delta-based operation like vim/h would compute "new offset" against
    // a stale 0 and teleport sioyek back to the top.
    //
    // We deliberately do NOT sync `page`. Page is a discrete, intent-level
    // field: set by goto_page / view/set :page. dv->get_center_page_number()
    // is computed from offset_y + viewport_height/2, which is ill-defined
    // in headless/offscreen tests (viewport is degenerate) and would make
    // view/get :page disagree with what the client just set.
    DocumentView* dv = main_widget ? main_widget->document_view() : nullptr;
    // v0.15: focused-id is the single source of truth for "is this
    // window the one driving the live widget". See cmd_view_set for
    // why we don't use the buffer-id heuristic anymore.
    const bool is_active = (windows->focused_id() == win_id);
    if (is_active && dv) {
        win->zoom     = dv->get_zoom_level();
        win->offset_x = dv->get_offset_x();
        win->offset_y = dv->get_offset_y();
    }

    if (!win->buffer_id.isEmpty()) data.insert("buffer-id", win->buffer_id);
    if (doc) {
        data.insert("num-pages",  doc->num_pages());
        data.insert("page-count", doc->num_pages());
    }

    data.insert("page",     win->page);
    data.insert("zoom",     safe_double(win->zoom));
    data.insert("offset-y", safe_double(win->offset_y));
    data.insert("offset-x", safe_double(win->offset_x));

    QJsonObject ep;
    ep.insert("dark-mode", win->dark_mode);
    ep.insert("rotation",  win->rotation);
    data.insert("engine-params", ep);

    // v0.14: expose overlay state so Lisp can introspect what's currently
    // displayed without keeping a parallel cache. :overlays is the full
    // layers array as last set via view/overlays (or empty after clear /
    // fresh window / engine-load). :overlay-count == overlays.size()
    // is kept as a fast scalar for callers that only care about presence.
    data.insert("overlays",      win->overlays);
    data.insert("overlay-count", win->overlays.size());
    return data;
}

void LimnCommand::emit_buffer_opened(const QString& buffer_id, Document* doc,
                                      const QString& engine) {
    QJsonObject ev;
    ev.insert("frame-id",   "f1");
    ev.insert("buffer-id",  buffer_id);
    ev.insert("engine",     engine);
    ev.insert("page-count", doc ? doc->num_pages() : 0);
    // v0.37 Phase F: include the source path so Lisp hooks
    // (pdf-mode-on-buffer-opened, which loads sidecar annotations +
    // restores last-position) can look up the right sidecar without a
    // synchronous round-trip.  For mupdf buffers, use doc->get_path();
    // for text-engine buffers, check buffer_paths (set by buffer/load-file).
    // Either may be empty — Lisp side already guards `(when path ...)`.
    QString path;
    if (doc) {
        // Document::get_path() returns std::wstring — convert to QString.
        const std::wstring wp = doc->get_path();
        path = QString::fromStdWString(wp);
    } else if (buffer_paths.contains(buffer_id)) {
        path = buffer_paths.value(buffer_id);
    }
    ev.insert("path", path);
    bridge->push_event("buffer-opened", ev);
}

void LimnCommand::emit_buffer_closed(const QString& buffer_id) {
    QJsonObject ev;
    ev.insert("frame-id",  "f1");
    ev.insert("buffer-id", buffer_id);
    bridge->push_event("buffer-closed", ev);
}

// ─── Phase 4/5 dispatch helpers ───────────────────────────────────────
//
// Each buffer/* (content) command resolves the buffer-id, validates page,
// and delegates the actual MuPDF work to LimnMupdf::*. We catch
// std::runtime_error from those helpers and turn it into a fail-response.

namespace {

// Returns nullptr and sends a fail-response if the buffer-id is missing or
// unknown. Otherwise returns the Document*.
Document* resolve_buffer(LimnBridge*         bridge,
                         LimnBufferRegistry* registry,
                         const QString&      id,
                         const QJsonObject&  msg) {
    const QString buffer_id = msg.value("buffer-id").toString();
    if (buffer_id.isEmpty()) {
        bridge->send_fail(id, "missing 'buffer-id'");
        return nullptr;
    }
    Document* doc = registry->lookup(buffer_id);
    if (!doc) {
        bridge->send_fail(id, QString("unknown buffer-id: %1").arg(buffer_id));
        return nullptr;
    }
    return doc;
}

}  // anonymous namespace

void LimnCommand::cmd_buffer_toc(const QString& id, const QJsonObject& msg) {
    Document* doc = resolve_buffer(bridge, registry, id, msg);
    if (!doc) return;
    try {
        QJsonArray arr = LimnMupdf::extract_toc(doc);
        QJsonObject resp;  // we want data as ARRAY at top level under "data"
        bridge->send_ok_array(id, arr);
    } catch (const std::exception& e) {
        bridge->send_fail(id, QString::fromUtf8(e.what()));
    }
}

// ─── bookmark/* (SPEC §5.x, v0.17) ─────────────────────────────────────
//
// In-memory per-buffer store. Persistence (sidecar file / outline rewrite
// / hybrid) is user-Lisp territory — framework keeps no opinion. Keyed
// by buffer-id so close() drops everything for that buffer.
//
// Wire shape of a single record:
//   { "name": str, "page": int, "x": float, "y": float, "note": str }
//
// list returns { "items": [<record>, ...] } in insertion order.

namespace {
QJsonObject bookmark_to_json(const LimnCommand::BookmarkRecord& b) {
    QJsonObject o;
    o.insert("name", b.name);
    o.insert("page", b.page);
    o.insert("x",    b.x);
    o.insert("y",    b.y);
    o.insert("note", b.note);
    return o;
}

// Resolve mupdf buffer-id (rejects text-engine and unknown). Returns
// Document* or nullptr with fail-response already sent.
Document* resolve_mupdf_buffer(LimnBridge* bridge, LimnBufferRegistry* reg,
                                const QHash<QString,GapBuffer>& text_bufs,
                                const QString& id, const QString& buffer_id) {
    if (buffer_id.isEmpty()) {
        bridge->send_fail(id, "missing 'buffer-id'");
        return nullptr;
    }
    if (text_bufs.contains(buffer_id)) {
        bridge->send_fail(id, "bookmark/* requires a mupdf buffer (got text-engine)");
        return nullptr;
    }
    Document* doc = reg->lookup(buffer_id);
    if (!doc) {
        bridge->send_fail(id, QString("unknown buffer-id: %1").arg(buffer_id));
        return nullptr;
    }
    return doc;
}
}  // anon

void LimnCommand::cmd_bookmark_list_native(const QString& id, const QJsonObject& msg) {
    const QString buf = msg.value("buffer-id").toString();
    Document* doc = resolve_mupdf_buffer(bridge, registry, text_buffers, id, buf);
    if (!doc) return;
    try {
        QJsonArray items = LimnMupdf::extract_toc(doc);
        QJsonObject data;
        data.insert("items", items);
        bridge->send_ok(id, data);
    } catch (const std::exception& e) {
        bridge->send_fail(id, QString::fromUtf8(e.what()));
    }
}

void LimnCommand::cmd_bookmark_list(const QString& id, const QJsonObject& msg) {
    const QString buf = msg.value("buffer-id").toString();
    if (!resolve_mupdf_buffer(bridge, registry, text_buffers, id, buf)) return;
    QJsonArray items;
    for (const auto& b : bookmarks.value(buf)) items.append(bookmark_to_json(b));
    QJsonObject data;
    data.insert("items", items);
    bridge->send_ok(id, data);
}

void LimnCommand::cmd_bookmark_set(const QString& id, const QJsonObject& msg) {
    const QString buf  = msg.value("buffer-id").toString();
    Document* doc = resolve_mupdf_buffer(bridge, registry, text_buffers, id, buf);
    if (!doc) return;
    const QString name = msg.value("name").toString();
    if (name.isEmpty()) { bridge->send_fail(id, "missing or empty 'name'"); return; }
    if (!msg.value("page").isDouble()) {
        bridge->send_fail(id, "missing or non-integer 'page'"); return;
    }
    const int page = msg.value("page").toInt();
    if (page < 0 || page >= doc->num_pages()) {
        bridge->send_fail(id, QString("page %1 out of range [0, %2)")
                              .arg(page).arg(doc->num_pages()));
        return;
    }
    BookmarkRecord rec;
    rec.name = name;
    rec.page = page;
    rec.x    = msg.value("x").toDouble(0.0);
    rec.y    = msg.value("y").toDouble(0.0);
    rec.note = msg.value("note").toString();

    QList<BookmarkRecord>& list = bookmarks[buf];
    // Upsert: replace existing by name, else append (preserves
    // insertion order for genuinely new entries).
    bool updated = false;
    for (auto& b : list) {
        if (b.name == name) { b = rec; updated = true; break; }
    }
    if (!updated) list.append(rec);
    bridge->send_ok(id);
}

void LimnCommand::cmd_bookmark_get(const QString& id, const QJsonObject& msg) {
    const QString buf  = msg.value("buffer-id").toString();
    if (!resolve_mupdf_buffer(bridge, registry, text_buffers, id, buf)) return;
    const QString name = msg.value("name").toString();
    if (name.isEmpty()) { bridge->send_fail(id, "missing or empty 'name'"); return; }
    for (const auto& b : bookmarks.value(buf)) {
        if (b.name == name) { bridge->send_ok(id, bookmark_to_json(b)); return; }
    }
    bridge->send_fail(id, QString("no bookmark named: %1").arg(name));
}

void LimnCommand::cmd_bookmark_delete(const QString& id, const QJsonObject& msg) {
    const QString buf  = msg.value("buffer-id").toString();
    if (!resolve_mupdf_buffer(bridge, registry, text_buffers, id, buf)) return;
    const QString name = msg.value("name").toString();
    if (name.isEmpty()) { bridge->send_fail(id, "missing or empty 'name'"); return; }
    QList<BookmarkRecord>& list = bookmarks[buf];
    for (int i = 0; i < list.size(); ++i) {
        if (list[i].name == name) { list.removeAt(i); bridge->send_ok(id); return; }
    }
    bridge->send_fail(id, QString("no bookmark named: %1").arg(name));
}

void LimnCommand::cmd_buffer_text(const QString& id, const QJsonObject& msg) {
    const QString buffer_id = msg.value("buffer-id").toString();

    // Text-engine buffer (chrome or user-opened) — return {text: "..."} as
    // a single string. SPEC §5.3 lets each engine pick its response shape
    // for buffer/text; for text engines there's no spatial layout so we
    // skip the words+rect form mupdf uses.
    if (text_buffers.contains(buffer_id)) {
        QJsonObject data;
        data.insert("text", text_buffers.value(buffer_id).to_qstring());
        bridge->send_ok(id, data);
        return;
    }

    // Otherwise: mupdf path (per-page text extraction with rects).
    Document* doc = resolve_buffer(bridge, registry, id, msg);
    if (!doc) return;
    if (!msg.contains("page") || !msg.value("page").isDouble()) {
        bridge->send_fail(id, "missing or invalid 'page'");
        return;
    }
    const int page = msg.value("page").toInt();
    try {
        bridge->send_ok(id, LimnMupdf::extract_page_text(doc, page));
    } catch (const std::exception& e) {
        bridge->send_fail(id, QString::fromUtf8(e.what()));
    }
}

void LimnCommand::cmd_buffer_links(const QString& id, const QJsonObject& msg) {
    Document* doc = resolve_buffer(bridge, registry, id, msg);
    if (!doc) return;
    if (!msg.contains("page") || !msg.value("page").isDouble()) {
        bridge->send_fail(id, "missing or invalid 'page'");
        return;
    }
    const int page = msg.value("page").toInt();
    try {
        bridge->send_ok_array(id, LimnMupdf::extract_page_links(doc, page));
    } catch (const std::exception& e) {
        bridge->send_fail(id, QString::fromUtf8(e.what()));
    }
}

// v0.27 §B: full-document text search.
//
// Wire shape:
//   { cmd:"buffer/search", buffer-id, query, case-sensitive }
//   →  { ok:true, data:{ hits:[ {page:N, rects:[[x0,y0,x1,y1],...]}, ... ] } }
//
// Empty query returns hits:[]. Missing buffer-id / unknown buffer → ok:false.
void LimnCommand::cmd_buffer_search(const QString& id, const QJsonObject& msg) {
    Document* doc = resolve_buffer(bridge, registry, id, msg);
    if (!doc) return;
    const QString query = msg.value("query").toString();
    const bool case_sensitive = msg.value("case-sensitive").toBool();
    try {
        bridge->send_ok(id, LimnMupdf::extract_search_hits(doc, query, case_sensitive));
    } catch (const std::exception& e) {
        bridge->send_fail(id, QString::fromUtf8(e.what()));
    }
}

void LimnCommand::cmd_buffer_metadata(const QString& id, const QJsonObject& msg) {
    Document* doc = resolve_buffer(bridge, registry, id, msg);
    if (!doc) return;
    try {
        bridge->send_ok(id, LimnMupdf::extract_metadata(doc));
    } catch (const std::exception& e) {
        bridge->send_fail(id, QString::fromUtf8(e.what()));
    }
}

void LimnCommand::cmd_buffer_render(const QString& id, const QJsonObject& msg) {
    Document* doc = resolve_buffer(bridge, registry, id, msg);
    if (!doc) return;
    if (!msg.contains("page") || !msg.value("page").isDouble()) {
        bridge->send_fail(id, "missing or invalid 'page'");
        return;
    }
    const int  page = msg.value("page").toInt();
    const int  dpi  = msg.contains("dpi") ? msg.value("dpi").toInt() : 72;
    try {
        bridge->send_ok(id, LimnMupdf::render_page_to_png(doc, page, dpi));
    } catch (const std::exception& e) {
        bridge->send_fail(id, QString::fromUtf8(e.what()));
    }
}

// ─── Phase 7: test/* commands ─────────────────────────────────────────
//
// Each test/inject-* command translates its parameters into the exact
// payload of the matching event, then asks the bridge to push it. The
// effect: real-event handlers (phase 8) and inject-driven tests both
// converge on the same event push path.

namespace {

QJsonObject pick_keys(const QJsonObject& src,
                      std::initializer_list<const char*> keys) {
    QJsonObject o;
    for (const char* k : keys) {
        if (src.contains(k)) o.insert(k, src.value(k));
    }
    return o;
}

}  // anonymous namespace

void LimnCommand::cmd_test_inject_key(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg, {"frame-id", "key"});
    // `mods` must be an array (possibly empty), never null.
    QJsonValue mv = msg.value("mods");
    if (mv.isArray()) ev.insert("mods", mv.toArray());
    else              ev.insert("mods", QJsonArray{});
    bridge->push_event("key", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_inject_mouse_click(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg, {"frame-id", "win-id", "page", "x", "y", "button"});
    bridge->push_event("mouse-click", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_inject_mouse_drag(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg,
        {"frame-id", "win-id", "page", "x", "y", "dx", "dy", "button"});
    bridge->push_event("mouse-drag", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_inject_scroll(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg, {"frame-id", "win-id", "dx", "dy"});
    bridge->push_event("scroll", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_inject_gesture(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg,
        {"frame-id", "win-id", "type", "scale", "dx", "dy"});
    bridge->push_event("gesture", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_inject_drag_drop(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg, {"frame-id", "win-id", "paths"});
    bridge->push_event("drag-drop", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_inject_ime_commit(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg, {"frame-id", "text"});
    // v0.16: SPEC §6 requires :frame-id on every frame-scoped event.
    // Default to "f1" if caller didn't pass one (back-compat with v0.7).
    if (!ev.contains("frame-id")) ev.insert("frame-id", "f1");
    const QString text = msg.value("text").toString();

    // v0.16: SERVER-SIDE dispatch. When the minibuffer is open, commit
    // the IME text into *minibuffer* (advancing cursor by codepoint
    // count of text) and emit minibuffer-input so Lisp observers see
    // the change. When the minibuffer is closed: just fire the
    // ime-commit event (graceful no-op for the text — observers can
    // still react if they want).
    //
    // Same vanilla-Emacs C-core pattern: the C-level commit_text path
    // mutates the buffer at point; Lisp doesn't have to wire dispatch.
    if (minibuffer_open && !text.isEmpty()) {
        GapBuffer& buf = text_buffers["*minibuffer*"];
        int&       cur = text_cursors["*minibuffer*"];
        buf.insert(cur, text);
        cur += text.length();         // UTF-16 internal units
        const QString updated = buf.to_qstring();
        if (auto* c = chrome_of(main_widget))
            c->set_minibuffer(true, minibuffer_prompt, updated);
        QJsonObject input_ev;
        input_ev.insert("frame-id", "f1");
        input_ev.insert("text", updated);
        bridge->push_event("minibuffer-input", input_ev);
    }

    bridge->push_event("ime-commit", ev);
    bridge->send_ok(id);
}

// v0.16: parallel primitive for the in-progress composition string the
// IME is currently displaying. Distinct event type from ime-commit so
// clients can show preedit underline / styling separately.
void LimnCommand::cmd_test_inject_ime_preedit(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg, {"frame-id", "text"});
    if (!ev.contains("frame-id")) ev.insert("frame-id", "f1");
    // Empty :text by convention = "cancel composition". Same event shape,
    // dispatcher can distinguish by string length.
    bridge->push_event("ime-preedit", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_inject_audio_input(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg, {"frame-id", "text"});
    bridge->push_event("audio-input", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_inject_resize(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg, {"frame-id", "win-id", "width", "height"});
    // v0.33b: when running in Xvfb without a window manager, xdotool
    // windowsize doesn't reach the inner widgets. Tests that need a
    // real Qt resize event (wrap-on-narrow, viewport reflow) call us;
    // perform the actual widget resize so paint state reflects it.
    const int w = msg.value("width").toInt(0);
    const int h = msg.value("height").toInt(0);
    if (main_widget && w > 0 && h > 0) {
        if (auto* tw = main_widget->text_widget()) {
            tw->resize(w, h);
            // Match the document's text width to the new viewport width
            // so wrap recomputes immediately. Without this the next paint
            // would still wrap to the old text-width.
            tw->document()->setTextWidth(tw->viewport()->width());
        }
        main_widget->resize(w, h);
        // v0.33b: any focused-window text-range overlays need to re-layout
        // against the new geometry. Test surface is overlay_raster; rebuild
        // it now so subsequent test/region-bbox sees fresh paint without
        // the caller having to re-push view/overlays.
        const QString fid = windows ? windows->focused_id() : QString();
        LimnWindow* fw    = (windows && !fid.isEmpty()) ? windows->get(fid) : nullptr;
        if (fw && text_buffers.contains(fw->buffer_id)) {
            int rw = main_widget->text_widget()
                       ? main_widget->text_widget()->viewport()->width() : w;
            int rh = main_widget->text_widget()
                       ? main_widget->text_widget()->viewport()->height() : h;
            if (rw > 0 && rh > 0) rebuild_overlay_raster(rw, rh);
        }
    }
    bridge->push_event("resize", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_emit_heartbeat(const QString& id, const QJsonObject&) {
    bridge->emit_heartbeat();
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_snapshot(const QString& id, const QJsonObject&) {
    QJsonObject data;
    data.insert("buffer-count",  registry->count());
    // Sum overlay-count across all windows.
    int total_overlays = 0;
    for (const QString& wid : windows->all_ids()) {
        if (LimnWindow* w = windows->get(wid)) total_overlays += w->overlay_count;
    }
    data.insert("overlay-count", total_overlays);
    data.insert("test-mode",     test_mode);
    bridge->send_ok(id, data);
}

void LimnCommand::cmd_test_flush_caches(const QString& id, const QJsonObject&) {
    // No-op for now: sioyek's caches are managed by DocumentManager and
    // we don't expose a public flush. The test only verifies that the
    // command responds cleanly and the frontend stays usable.
    bridge->send_ok(id);
}

// ─── test/grab-window ───────────────────────────────────────────────────
//
// Grab the current rendered pixels of a widget into a PNG. With
// QT_QPA_PLATFORM=offscreen this paints into a backing store and is fully
// deterministic — exactly what GUI regression tests need.
//
// Returns: { png: base64, width, height, avg-luminance, opaque-pixels }
// `win-id` is accepted for forward compat but currently always grabs the
// MainWidget (we don't yet have one QWidget per logical Limn window).

void LimnCommand::cmd_test_grab_window(const QString& id, const QJsonObject& msg) {
    QWidget* target = main_widget;
    if (!target) {
        bridge->send_fail(id, "no widget to grab");
        return;
    }

    // Make sure pending layout / paint events have run before we grab.
    // Without this, freshly-mutated state (e.g. just after view/set) may
    // not yet be reflected in the backing store.
    QCoreApplication::processEvents();

    QPixmap pm = target->grab();
    QImage img = pm.toImage().convertToFormat(QImage::Format_ARGB32);

    // Encode to base64-PNG.
    QByteArray png_bytes;
    {
        QBuffer buf(&png_bytes);
        buf.open(QIODevice::WriteOnly);
        img.save(&buf, "PNG");
    }
    QString b64 = QString::fromLatin1(png_bytes.toBase64());

    // Compute aggregate stats once, server-side — saves the Lisp side from
    // needing a PNG decoder.
    qint64 lum_sum = 0;
    qint64 opaque  = 0;
    const int w = img.width();
    const int h = img.height();
    for (int y = 0; y < h; ++y) {
        const QRgb* row = reinterpret_cast<const QRgb*>(img.constScanLine(y));
        for (int x = 0; x < w; ++x) {
            const QRgb px = row[x];
            const int a = qAlpha(px);
            if (a > 0) {
                ++opaque;
                // Rec.601 luma
                lum_sum += (299 * qRed(px) + 587 * qGreen(px) + 114 * qBlue(px))
                           / 1000;
            }
        }
    }
    const double avg_lum = (opaque > 0)
                           ? (double)lum_sum / (double)opaque
                           : 0.0;

    QJsonObject data;
    data.insert("png",            b64);
    data.insert("width",          w);
    data.insert("height",         h);
    data.insert("avg-luminance",  avg_lum);
    data.insert("opaque-pixels",  static_cast<qint64>(opaque));
    // Accept the win-id for echo even though we ignore it for routing.
    if (msg.contains("win-id")) {
        data.insert("win-id", msg.value("win-id").toString());
    }
    bridge->send_ok(id, data);
}

// ─── v0.14: focused window overlays accessor (for paintGL) ──────────────

QJsonArray LimnCommand::focused_window_overlays() const {
    if (!windows) return QJsonArray();
    const QString fid = windows->focused_id();
    if (fid.isEmpty()) return QJsonArray();
    // const-cast is fine here — get() doesn't mutate the registry,
    // it just returns a pointer; the registry's API isn't const-correct.
    LimnWindow* w = const_cast<LimnWindowRegistry*>(windows)->get(fid);
    if (!w) return QJsonArray();
    return w->overlays;
}

// ─── v0.14: rebuild overlay raster (single source of truth) ─────────────
//
// Renders all overlays for the focused window into LimnCommand::overlay_raster
// using QPainter on a software-backed QImage. White background. Same code
// path that PdfViewOpenGLWidget::paintGL blits onto the GL surface.

void LimnCommand::rebuild_overlay_raster(int width, int height) {
    if (width <= 0 || height <= 0) {
        overlay_raster = QImage();
        return;
    }
    if (overlay_raster.width()  != width ||
        overlay_raster.height() != height ||
        overlay_raster.format() != QImage::Format_ARGB32) {
        overlay_raster = QImage(width, height, QImage::Format_ARGB32);
    }
    // v0.36-dogfood: was opaque white — when any overlay is set, SourceOver
    // blit in render_overlays paints the white substrate over the PDF and
    // visually erases it. Transparent substrate lets only the actual overlay
    // pixels (selection rect, highlights, etc.) reach the screen; PDF render
    // beneath stays visible. The v0.14 comment in render_overlays already
    // flagged this as a known limitation; this is the fix.
    overlay_raster.fill(QColor(0, 0, 0, 0));      // transparent substrate

    QJsonArray layers = focused_window_overlays();

    // v0.33b: text-mode paint path. When the focused window is showing a
    // text-engine buffer, the PDF render machinery doesn't apply: no doc,
    // no pages, coords aren't page-norm. We paint type:"text-range"
    // layers directly using widget-local pixels and return.
    {
        const QString fid = windows ? windows->focused_id() : QString();
        LimnWindow* fw    = (windows && !fid.isEmpty()) ? windows->get(fid) : nullptr;
        if (fw && text_buffers.contains(fw->buffer_id)) {
            QPainter painter(&overlay_raster);
            painter.setRenderHint(QPainter::Antialiasing, false);
            painter.setCompositionMode(QPainter::CompositionMode_SourceOver);

            // Sort low→high by priority so high prio paints on top.
            QVector<QJsonObject> sorted;
            sorted.reserve(layers.size());
            for (const QJsonValue& lv : layers) {
                if (lv.isObject()) sorted.append(lv.toObject());
            }
            std::stable_sort(sorted.begin(), sorted.end(),
                [](const QJsonObject& a, const QJsonObject& b) {
                    return a.value("priority").toInt(0)
                         < b.value("priority").toInt(0);
                });

            for (const QJsonObject& l : sorted) {
                if (l.value("type").toString() != "text-range") continue;
                const QString layer_buf = l.value("buf-id").toString();
                if (layer_buf.isEmpty() || !text_buffers.contains(layer_buf))
                    continue;
                const int cp_start = l.value("start").toInt(0);
                const int cp_end   = l.value("end").toInt(0);

                // Resolve fill color: face background takes precedence
                // (this is a fill, not a foreground glyph paint), then
                // face fg, then explicit color. Missing color is fine for
                // before-string-only overlays; we just skip the fillRect.
                QString colstr;
                if (l.contains("face")) {
                    const QString faceName = l.value("face").toString();
                    auto it = face_registry_.find(faceName);
                    if (it != face_registry_.end()) {
                        if (!it->background.isEmpty()) colstr = it->background;
                        else if (!it->foreground.isEmpty()) colstr = it->foreground;
                    }
                }
                if (colstr.isEmpty()) colstr = l.value("color").toString();

                bool have_col = false;
                QColor col;
                if (colstr.length() == 7 && colstr.startsWith('#')) {
                    col = QColor(colstr);
                    if (col.isValid()) {
                        double opacity = l.value("opacity").toDouble(1.0);
                        if (opacity < 0.0) opacity = 0.0;
                        if (opacity > 1.0) opacity = 1.0;
                        col.setAlphaF(opacity);
                        have_col = true;
                    }
                }

                const QVector<QRectF> rects =
                    compute_text_range_rects(layer_buf, cp_start, cp_end);
                if (have_col) {
                    for (const QRectF& r : rects) painter.fillRect(r, col);
                }

                // v0.33b: render before-string (and after-string) as text
                // anchored at the overlay's first / last rect. Lets tests
                // verify visual injection without mutating buffer text.
                const QString before = l.value("before-string").toString();
                const QString after  = l.value("after-string").toString();
                if (!before.isEmpty() || !after.isEmpty()) {
                    QFont f = main_widget->text_widget()->font();
                    f.setPixelSize(qMax(8, f.pixelSize()));
                    painter.setFont(f);
                    painter.setPen(QPen(QColor(0, 0, 0)));
                    if (!before.isEmpty()) {
                        // If the range is empty (start == end) we still
                        // need a position — fall back to a 0-codepoint
                        // anchor.
                        QVector<QRectF> anchor = rects.isEmpty()
                            ? compute_text_range_rects(layer_buf,
                                                        cp_start,
                                                        cp_start + 1)
                            : rects;
                        if (!anchor.isEmpty()) {
                            QFontMetricsF fm(f);
                            painter.drawText(QPointF(anchor.first().left(),
                                                     anchor.first().top()
                                                     + fm.ascent()),
                                             before);
                            last_text_render = QJsonObject{
                                {"text", before},
                                {"font-family", f.family()},
                                {"pixel-size", f.pixelSize()}};
                        }
                    }
                    if (!after.isEmpty() && !rects.isEmpty()) {
                        QFontMetricsF fm(f);
                        painter.drawText(QPointF(rects.last().right(),
                                                 rects.last().top()
                                                 + fm.ascent()),
                                         after);
                    }
                }
            }
            return;
        }
    }

    DocumentView* dv = main_widget ? main_widget->document_view() : nullptr;
    Document* doc    = dv ? dv->get_document() : nullptr;
    if (!dv || !doc) return;

    // v0.14: page filter — only render layers whose :page matches the
    // focused window's current page. Layers on other pages exist in
    // state but don't paint until you navigate to that page.
    int current_page     = 0;
    int current_rotation = 0;
    LimnWindow* focused_win = nullptr;
    if (windows) {
        const QString fid = windows->focused_id();
        focused_win = windows->get(fid);
        if (focused_win) {
            current_page     = focused_win->page;
            current_rotation = focused_win->rotation;
        }
    }

    QPainter painter(&overlay_raster);
    painter.setRenderHint(QPainter::Antialiasing,         false);
    painter.setRenderHint(QPainter::TextAntialiasing,     false);
    painter.setRenderHint(QPainter::SmoothPixmapTransform, false);
    painter.setCompositionMode(QPainter::CompositionMode_SourceOver);

    // v0.15.1: per-window rotation applied to painter so overlays AND
    // selection follow rotation. Rotate around raster center; for
    // 90°/270° the page-norm (0..1)² is interpreted as fitting the
    // *rotated* bounding box (swapped width↔height).
    const bool axes_swapped =
        (current_rotation == 90 || current_rotation == 270);
    if (current_rotation != 0) {
        painter.translate(width / 2.0, height / 2.0);
        painter.rotate(current_rotation);
        if (axes_swapped) {
            painter.translate(-height / 2.0, -width / 2.0);
        } else {
            painter.translate(-width / 2.0, -height / 2.0);
        }
    }
    // Effective raster dimensions after rotation (for the norm-to-pixel
    // mapping below). Both lambdas — overlay loop and selection — use
    // these so behaviour is consistent.
    const int eff_w = axes_swapped ? height : width;
    const int eff_h = axes_swapped ? width  : height;

    for (const QJsonValue& lv : layers) {
        if (!lv.isObject()) continue;
        const QJsonObject l = lv.toObject();
        const QString type  = l.value("type").toString();
        const int     page  = l.value("page").toInt(-1);
        if (page < 0 || page >= doc->num_pages()) continue;
        if (page != current_page) continue;            // v0.14 page filter

        // v0.25: "face" field overrides "color" — resolve foreground from registry
        QString colstr = l.value("color").toString();
        if (l.contains("face")) {
            const QString faceName = l.value("face").toString();
            auto it = face_registry_.find(faceName);
            if (it != face_registry_.end() && !it->foreground.isEmpty())
                colstr = it->foreground;
        }
        if (colstr.length() != 7 || !colstr.startsWith('#')) continue;
        QColor col(colstr);
        if (!col.isValid()) continue;
        double opacity = l.value("opacity").toDouble(1.0);
        if (opacity < 0.0) opacity = 0.0;
        if (opacity > 1.0) opacity = 1.0;
        col.setAlphaF(opacity);

        // v0.14 overlay coord contract for the side-raster:
        // page-norm [0,1]² maps to the FULL raster (= focused widget),
        // *after* rotation (so eff_w/eff_h are the post-rotation
        // dimensions). Decouples overlay coordinates from sioyek's
        // view layout state — deterministic test output.
        auto norm_to_pixel = [&](double nx, double ny,
                                  float* ox, float* oy) {
            *ox = nx * eff_w;
            *oy = ny * eff_h;
        };

        if (type == "rect") {
            float x0, y0, x1, y1;
            const QJsonArray ra = l.value("rect").toArray();
            if (ra.size() == 4) {
                norm_to_pixel(ra[0].toDouble(), ra[1].toDouble(), &x0, &y0);
                norm_to_pixel(ra[2].toDouble(), ra[3].toDouble(), &x1, &y1);
            } else if (l.contains("x0") && l.contains("y0")
                    && l.contains("x1") && l.contains("y1")) {
                // v0.33b: alternate sugar — x0/y0/x1/y1 numeric fields.
                norm_to_pixel(l.value("x0").toDouble(),
                              l.value("y0").toDouble(), &x0, &y0);
                norm_to_pixel(l.value("x1").toDouble(),
                              l.value("y1").toDouble(), &x1, &y1);
            } else {
                continue;
            }
            QRectF r(QPointF(std::min(x0, x1), std::min(y0, y1)),
                     QPointF(std::max(x0, x1), std::max(y0, y1)));
            painter.fillRect(r, col);
        }
        else if (type == "line") {
            const QJsonArray from = l.value("from").toArray();
            const QJsonArray to   = l.value("to").toArray();
            if (from.size() != 2 || to.size() != 2) continue;
            float ax, ay, bx, by;
            norm_to_pixel(from[0].toDouble(), from[1].toDouble(), &ax, &ay);
            norm_to_pixel(to[0].toDouble(),   to[1].toDouble(),   &bx, &by);
            const int width = l.value("width").toInt(1);
            QPen pen(col);
            pen.setWidth(width);
            pen.setCapStyle(Qt::FlatCap);
            painter.setPen(pen);
            painter.drawLine(QPointF(ax, ay), QPointF(bx, by));
        }
        else if (type == "text") {
            const QJsonArray pos = l.value("pos").toArray();
            if (pos.size() != 2) continue;
            float px, py;
            norm_to_pixel(pos[0].toDouble(), pos[1].toDouble(), &px, &py);
            const double size_pt = l.value("size").toDouble(12.0);
            if (size_pt <= 0) continue;
            const QString text   = l.value("text").toString();
            const QString family = l.value("font").toString(
                                       QStringLiteral("DejaVu Sans"));
            QFont f(family);
            f.setPixelSize(static_cast<int>(size_pt));
            f.setHintingPreference(QFont::PreferNoHinting);
            painter.setFont(f);
            painter.setPen(QPen(col));
            painter.drawText(QPointF(px, py), text);

            QFontInfo fi(painter.font());
            QFontMetricsF fm(painter.font());
            const QRectF bbox = fm.tightBoundingRect(text);
            QJsonObject info;
            info.insert("font-family",  fi.family());
            info.insert("pixel-size",   fi.pixelSize());
            info.insert("weight",       fi.weight());
            info.insert("italic",       fi.italic());
            const int sub =
                (fi.family().compare(family, Qt::CaseInsensitive) == 0)
                    ? 0 : static_cast<int>(text.length());
            info.insert("glyphs-substituted", sub);
            QJsonObject bbjs;
            bbjs.insert("x", static_cast<int>(px + bbox.x()));
            bbjs.insert("y", static_cast<int>(py + bbox.y()));
            bbjs.insert("w", static_cast<int>(bbox.width()));
            bbjs.insert("h", static_cast<int>(bbox.height()));
            info.insert("bbox", bbjs);
            last_text_render = info;
        }
    }

    // v0.36-dogfood: paint visual selection via the real DocumentView
    // transform (page-norm → absolute doc → window pixels). The old code
    // used (x * eff_w, y * eff_h) — i.e. "page == entire widget" — which
    // is only correct at fit-to-page with zero scroll. With any other
    // zoom / scroll, the yellow rect drifted off the actual selected
    // text AND stayed glued to widget coords when the user scrolled.
    if (focused_win && focused_win->selection_active && dv && doc) {
        const QJsonObject sb = focused_win->selection_begin;
        const QJsonObject se = focused_win->selection_end;
        const int sp_begin = sb.value("page").toInt(-1);
        const int sp_end   = se.value("page").toInt(-1);
        if (sp_begin == sp_end && sp_begin >= 0) {
            AbsoluteDocumentPos abs_b, abs_e;
            if (page_norm_to_absolute(doc, sp_begin,
                                       sb.value("x").toDouble(),
                                       sb.value("y").toDouble(), &abs_b) &&
                page_norm_to_absolute(doc, sp_end,
                                       se.value("x").toDouble(),
                                       se.value("y").toDouble(), &abs_e)) {
                const WindowPos wb = dv->absolute_to_window_pos_in_pixels(abs_b);
                const WindowPos we = dv->absolute_to_window_pos_in_pixels(abs_e);
                // dv's transform already accounts for rotation/scroll/zoom.
                // The earlier painter.rotate(current_rotation) is for the
                // page-norm overlay loop; don't double-rotate here.
                painter.save();
                painter.resetTransform();
                const int x1 = std::min(wb.x, we.x);
                const int y1 = std::min(wb.y, we.y);
                const int x2 = std::max(wb.x, we.x);
                const int y2 = std::max(wb.y, we.y);
                QRectF r(QPointF(x1, y1), QPointF(x2, y2));
                QColor selcol(255, 255, 0);          // yellow
                selcol.setAlphaF(0.5);
                painter.fillRect(r, selcol);
                painter.restore();
            }
        }
    }
}

// ─── v0.14: pixel-level test primitives ─────────────────────────────────
//
// These exist to support strict deterministic paint testing without
// transporting whole PNG framebuffers back to Lisp. Each command does
// the heavy work server-side and returns at most a few dozen bytes.
//
// Pattern: grab the MainWidget once (offscreen-deterministic via Qt's
// QWidget::grab() + QT_QPA_PLATFORM=offscreen) into a QImage, then do
// whatever per-pixel scan the caller asked for.

namespace {

// v0.14: pixel-level test primitives read from LimnCommand::overlay_raster
// (the deterministic side QImage rendered by rebuild_overlay_raster).
// We DON'T use QWidget::grab() or QOpenGLWidget::grabFramebuffer() —
// those depend on GL context / widget show timing which is flaky in
// headless container environments. The raster is always deterministic.
const QImage& test_image_source(const LimnCommand* lc) {
    return lc->current_overlay_raster();
}

// Parse "#RRGGBB" → (r,g,b). Returns false on malformed input.
bool parse_hex_color(const QString& hex, int* r, int* g, int* b) {
    if (hex.length() != 7 || !hex.startsWith('#')) return false;
    bool ok1=false, ok2=false, ok3=false;
    *r = hex.mid(1,2).toInt(&ok1, 16);
    *g = hex.mid(3,2).toInt(&ok2, 16);
    *b = hex.mid(5,2).toInt(&ok3, 16);
    return ok1 && ok2 && ok3;
}

// Clamp (x0,y0)-(x1,y1) to image bounds, returns false if degenerate.
bool clamp_region(const QImage& img, int& x0, int& y0, int& x1, int& y1) {
    x0 = std::max(0, std::min(img.width(),  x0));
    y0 = std::max(0, std::min(img.height(), y0));
    x1 = std::max(0, std::min(img.width(),  x1));
    y1 = std::max(0, std::min(img.height(), y1));
    if (x1 <= x0 || y1 <= y0) return false;
    return true;
}

}  // anonymous namespace

// ── test/sample-pixel ───────────────────────────────────────────────────
//
// Args: :x :y (widget pixel coords)
// Returns: { r, g, b, a } each 0..255
//
// 4 bytes of payload semantically. Use to spot-check known coordinates
// after setting an overlay.

void LimnCommand::cmd_test_sample_pixel(const QString& id,
                                         const QJsonObject& msg) {
    if (!main_widget) { bridge->send_fail(id, "no main widget"); return; }
    const int x = msg.value("x").toInt(-1);
    const int y = msg.value("y").toInt(-1);
    const QImage & img = overlay_raster;
    if (img.isNull()) { bridge->send_fail(id, "grab failed"); return; }
    if (x < 0 || y < 0 || x >= img.width() || y >= img.height()) {
        bridge->send_fail(id,
            QString("pixel out of bounds: (%1,%2) in %3x%4")
                .arg(x).arg(y).arg(img.width()).arg(img.height()));
        return;
    }
    const QRgb px = img.pixel(x, y);
    QJsonObject data;
    data.insert("r", qRed(px));
    data.insert("g", qGreen(px));
    data.insert("b", qBlue(px));
    data.insert("a", qAlpha(px));
    bridge->send_ok(id, data);
}

// ── test/region-bbox ────────────────────────────────────────────────────
//
// Args: :x0 :y0 :x1 :y1 :match-color "#RRGGBB"
// Returns: { x, y, w, h } of pixels matching the color (per-channel
//           tolerance ±8) OR null if no match.
//
// Used to verify "the overlay actually painted in the right pixel rect"
// without averaging.

void LimnCommand::cmd_test_region_bbox(const QString& id,
                                        const QJsonObject& msg) {
    if (!main_widget) { bridge->send_fail(id, "no main widget"); return; }
    int x0 = msg.value("x0").toInt();
    int y0 = msg.value("y0").toInt();
    int x1 = msg.value("x1").toInt();
    int y1 = msg.value("y1").toInt();
    const QString color = msg.value("match-color").toString();
    int mr, mg, mb;
    if (!parse_hex_color(color, &mr, &mg, &mb)) {
        bridge->send_fail(id,
            QString("invalid match-color: %1").arg(color));
        return;
    }
    const QImage & img = overlay_raster;
    if (img.isNull()) { bridge->send_fail(id, "grab failed"); return; }
    if (!clamp_region(img, x0, y0, x1, y1)) {
        bridge->send_fail(id, "degenerate region after clamp");
        return;
    }
    const int TOL = 8;
    int min_x = INT_MAX, min_y = INT_MAX, max_x = INT_MIN, max_y = INT_MIN;
    bool any = false;
    for (int y = y0; y < y1; ++y) {
        const QRgb* row = reinterpret_cast<const QRgb*>(img.constScanLine(y));
        for (int x = x0; x < x1; ++x) {
            const QRgb p = row[x];
            if (std::abs(qRed(p)   - mr) <= TOL &&
                std::abs(qGreen(p) - mg) <= TOL &&
                std::abs(qBlue(p)  - mb) <= TOL) {
                any = true;
                if (x < min_x) min_x = x;
                if (y < min_y) min_y = y;
                if (x > max_x) max_x = x;
                if (y > max_y) max_y = y;
            }
        }
    }
    if (!any) {
        bridge->send_ok(id, QJsonObject());     // null bbox = empty data
        return;
    }
    QJsonObject data;
    data.insert("x", min_x);
    data.insert("y", min_y);
    data.insert("w", max_x - min_x + 1);
    data.insert("h", max_y - min_y + 1);
    bridge->send_ok(id, data);
}

// ── test/region-hash ────────────────────────────────────────────────────
//
// Args: :x0 :y0 :x1 :y1
// Returns: { sha256 } hex string of the raw RGBA bytes in the region.
//
// Used for golden-image comparison without storing PNGs. Deterministic
// across runs when Qt rendering knobs are locked.

void LimnCommand::cmd_test_region_hash(const QString& id,
                                        const QJsonObject& msg) {
    if (!main_widget) { bridge->send_fail(id, "no main widget"); return; }
    int x0 = msg.value("x0").toInt();
    int y0 = msg.value("y0").toInt();
    int x1 = msg.value("x1").toInt();
    int y1 = msg.value("y1").toInt();
    const QImage & img = overlay_raster;
    if (img.isNull()) { bridge->send_fail(id, "grab failed"); return; }
    if (!clamp_region(img, x0, y0, x1, y1)) {
        bridge->send_fail(id, "degenerate region after clamp");
        return;
    }
    QCryptographicHash h(QCryptographicHash::Sha256);
    for (int y = y0; y < y1; ++y) {
        const uchar* row = img.constScanLine(y);
        // 4 bytes per pixel (Format_ARGB32), slice the row to [x0, x1)
        h.addData(reinterpret_cast<const char*>(row + x0 * 4),
                  (x1 - x0) * 4);
    }
    QJsonObject data;
    data.insert("sha256", QString::fromLatin1(h.result().toHex()));
    data.insert("w",      x1 - x0);
    data.insert("h",      y1 - y0);
    bridge->send_ok(id, data);
}

// ── test/page-pixel-rect ────────────────────────────────────────────────
//
// Args: :win-id :page
// Returns: { x, y, w, h } widget pixel rect of where PAGE of WIN-ID is
//          currently rendered; OR empty {} if page is not currently
//          visible (or no document loaded).
//
// Tests use this to translate page-norm (0..1) overlay coords into the
// widget pixel coords they should land on, so sample-pixel / region-bbox
// can be aimed correctly without baking in any zoom / offset assumption.

void LimnCommand::cmd_test_page_pixel_rect(const QString& id,
                                            const QJsonObject& msg) {
    Q_UNUSED(msg);
    if (!main_widget) { bridge->send_fail(id, "no main widget"); return; }
    DocumentView* dv = main_widget->document_view();
    Document* doc    = dv ? dv->get_document() : nullptr;
    if (!dv || !doc) {
        // v0.33b: when a text-engine buffer is in the focused window, no
        // PDF doc exists but the overlay_raster is still the test surface
        // (sized to the text widget). Return its dimensions so tests can
        // sample the painted text-range overlays.
        const QString fid = windows ? windows->focused_id() : QString();
        LimnWindow* fw    = (windows && !fid.isEmpty()) ? windows->get(fid) : nullptr;
        if (fw && text_buffers.contains(fw->buffer_id)
              && !overlay_raster.isNull()) {
            QJsonObject td;
            td.insert("x", 0);
            td.insert("y", 0);
            td.insert("w", overlay_raster.width());
            td.insert("h", overlay_raster.height());
            bridge->send_ok(id, td);
            return;
        }
        // No doc loaded and no text buffer either — return empty (not error;
        // tests can decide whether that's the expected state).
        bridge->send_ok(id, QJsonObject());
        return;
    }
    const int page = msg.value("page").toInt(0);
    if (page < 0 || page >= doc->num_pages()) {
        bridge->send_ok(id, QJsonObject());
        return;
    }
    const float pw = doc->get_page_width(page);
    const float ph = doc->get_page_height(page);
    if (pw <= 0 || ph <= 0) {
        bridge->send_ok(id, QJsonObject());
        return;
    }
    // Build a DocumentRect covering the whole page, ask sioyek to
    // project it into widget pixels. Same conversion path as click
    // handling (so coords are consistent across overlay / click).
    // v0.14: must match rebuild_overlay_raster's coord contract —
    // page-norm fills the full raster (= widget). Return the raster
    // dimensions directly (origin 0,0).
    QJsonObject data;
    data.insert("x", 0);
    data.insert("y", 0);
    data.insert("w", overlay_raster.width());
    data.insert("h", overlay_raster.height());
    bridge->send_ok(id, data);
}

// ── test/last-text-render ───────────────────────────────────────────────
//
// Args: (none)
// Returns: { font-family, pixel-size, weight, italic, glyphs-substituted,
//            bbox: {x, y, w, h} }
//
// Populated by paintGL each time a text overlay is drawn. Lets tests
// confirm:
//   (a) Qt actually used the font we asked for (not silent fallback)
//   (b) glyphs-substituted == 0 → no missing-glyph fallback
//   (c) bbox dimensions match font metrics ("I" < "M" in proportional)

void LimnCommand::cmd_test_last_text_render(const QString& id,
                                             const QJsonObject&) {
    bridge->send_ok(id, last_text_render);
}

// ─── test/widget-tree ───────────────────────────────────────────────────
//
// Dump the QWidget tree under MainWidget as JSON. Lets tests verify
// structural facts (split produced two viewports, floating window is at
// the right geometry, focus is on the expected widget) without pixel maths.

static QJsonObject widget_to_json(QWidget* w) {
    QJsonObject o;
    o.insert("class",   QString::fromUtf8(w->metaObject()->className()));
    o.insert("name",    w->objectName());
    o.insert("visible", w->isVisible());
    o.insert("focus",   w->hasFocus());
    QJsonArray geom;
    geom.append(w->x()); geom.append(w->y());
    geom.append(w->width()); geom.append(w->height());
    o.insert("geometry", geom);

    QJsonArray kids;
    for (QObject* child : w->children()) {
        if (auto* cw = qobject_cast<QWidget*>(child)) {
            kids.append(widget_to_json(cw));
        }
    }
    o.insert("children", kids);
    return o;
}

// ─── test/inject-qt-key ────────────────────────────────────────────────
//
// Like test/inject-key, but instead of bypassing Qt and pushing a synthetic
// bridge event directly, this dispatches a REAL QKeyEvent through
// QApplication. Goes through the same code paths as a hardware keystroke:
//   QApplication::sendEvent → installed event filters (LimnInputFilter) →
//   focused widget's keyPressEvent.
//
// This is what we need to verify end-to-end "key → filter → bridge → SBCL"
// without a human pressing a button.

namespace {
int parse_qt_key(const QString& k) {
    if (k.size() == 1) {
        QChar c = k.at(0);
        return c.toUpper().unicode();
    }
    if (k == "RET") return Qt::Key_Return;
    if (k == "ESC") return Qt::Key_Escape;
    if (k == "TAB") return Qt::Key_Tab;
    if (k == "SPC") return Qt::Key_Space;
    if (k == "BS")  return Qt::Key_Backspace;
    if (k == "DEL") return Qt::Key_Delete;
    if (k == "<up>")       return Qt::Key_Up;
    if (k == "<down>")     return Qt::Key_Down;
    if (k == "<left>")     return Qt::Key_Left;
    if (k == "<right>")    return Qt::Key_Right;
    if (k == "<home>")     return Qt::Key_Home;
    if (k == "<end>")      return Qt::Key_End;
    if (k == "<pageup>")   return Qt::Key_PageUp;
    if (k == "<pagedown>") return Qt::Key_PageDown;
    return 0;
}
Qt::KeyboardModifiers parse_qt_mods(const QJsonArray& a) {
    Qt::KeyboardModifiers m = Qt::NoModifier;
    for (const auto& v : a) {
        QString s = v.toString();
        if (s == "ctrl")  m |= Qt::ControlModifier;
        if (s == "shift") m |= Qt::ShiftModifier;
        if (s == "alt")   m |= Qt::AltModifier;
        if (s == "meta")  m |= Qt::MetaModifier;
    }
    return m;
}
}  // anonymous namespace

void LimnCommand::cmd_test_inject_qt_key(const QString& id, const QJsonObject& msg) {
    if (!main_widget) {
        bridge->send_fail(id, "no main widget");
        return;
    }
    const QString key_str = msg.value("key").toString();
    const int qkey  = parse_qt_key(key_str);
    const auto mods = parse_qt_mods(msg.value("mods").toArray());
    if (qkey == 0) {
        bridge->send_fail(id, QString("can't map key %1 to Qt::Key").arg(key_str));
        return;
    }

    // Pick a target: prefer the focused widget; fall back to MainWidget.
    QWidget* target = QApplication::focusWidget();
    if (!target) target = main_widget;
    // If MainWidget hasn't been activated (common on macOS for windows
    // launched from a terminal), force activation so focus is real.
    main_widget->activateWindow();
    main_widget->setFocus();

    // Real keyboards encode keys in the QKeyEvent's text field thus:
    //   plain letter "a"        → text "a"
    //   Shift+a                  → text "A"
    //   Ctrl+a (or any non-Shift mod) → text "\x01" (non-printable) or ""
    // We mirror that so the filter exercises the SAME code path as a real
    // keystroke. Otherwise test/inject-qt-key would always feed printable
    // text and miss bugs where key_to_string falls through to its key-
    // code fallback (that's what hid the Ctrl-d binding regression).
    QString text = key_str;
    const auto non_shift_mods =
        mods & ~Qt::KeyboardModifiers(Qt::ShiftModifier | Qt::KeypadModifier);
    if (key_str.size() == 1 && (mods & Qt::ShiftModifier)) {
        text = key_str.toUpper();
    }
    if (key_str.size() == 1 && non_shift_mods) {
        // Ctrl / Alt / Meta + letter: empty text, just like macOS gives Qt.
        text = QString();
    }
    QKeyEvent press(QEvent::KeyPress, qkey, mods, text);
    QApplication::sendEvent(target, &press);
    QKeyEvent release(QEvent::KeyRelease, qkey, mods, text);
    QApplication::sendEvent(target, &release);

    QJsonObject data;
    data.insert("target", target->metaObject()->className());
    data.insert("focus",  QApplication::focusWidget()
                          ? QApplication::focusWidget()->metaObject()->className()
                          : QString("(none)"));
    bridge->send_ok(id, data);
}

// SPEC v0.5 §6 — map a widget-local pixel click on the OpenGL viewport to
// (page, normalized-x, normalized-y). Returns false if no document is
// loaded; clamps to the valid range otherwise (negative widget coords
// also handled — we still get a page, just at edges of doc).
bool LimnCommand::widget_to_page_norm(int widget_x, int widget_y,
                                       int* out_page,
                                       double* out_nx, double* out_ny) {
    if (!main_widget) return false;
    DocumentView* dv = main_widget->document_view();
    Document* doc    = dv ? dv->get_document() : nullptr;
    if (!dv || !doc) return false;

    DocumentPos dp = dv->window_to_document_pos(WindowPos(widget_x, widget_y));
    if (dp.page < 0) return false;

    const float pw = doc->get_page_width(dp.page);
    const float ph = doc->get_page_height(dp.page);
    if (pw <= 0 || ph <= 0) return false;

    *out_page = dp.page;
    // DocumentPos x/y are in page-local doc units; normalize by page rect.
    *out_nx = static_cast<double>(dp.x) / static_cast<double>(pw);
    *out_ny = static_cast<double>(dp.y) / static_cast<double>(ph);
    // Reject NaN — sioyek's window_to_document_pos can return NaN under
    // incomplete layout (e.g. Xvfb without OpenGL context). Callers
    // expect "true means valid finite coords"; falling through to
    // pixel-coord fallback is cleaner than letting NaN propagate
    // to JSON (where it becomes null and breaks downstream math).
    // v0.10 batch 2 B6 caught it.
    if (!std::isfinite(*out_nx) || !std::isfinite(*out_ny)) {
        return false;
    }
    return true;
}

// SPEC §8 — test/inject-qt-mouse-click. Posts a real QMouseEvent through
// QApplication::sendEvent onto the OpenGL viewport. Goes through the
// LimnInputFilter the same way a hardware mouse would, so the test
// exercises the full filter → bridge → SBCL path including the page
// computation added in v0.8.
void LimnCommand::cmd_test_inject_qt_mouse_click(const QString& id,
                                                 const QJsonObject& msg) {
    if (!main_widget) {
        bridge->send_fail(id, "no main widget");
        return;
    }
    QWidget* target = main_widget->opengl_widget();
    if (!target) {
        bridge->send_fail(id, "no opengl widget");
        return;
    }
    const int    x      = msg.value("x").toInt();
    const int    y      = msg.value("y").toInt();
    const int    button = msg.value("button").toInt();      // 1=L, 2=M, 3=R
    Qt::MouseButton qb =
        (button == 1) ? Qt::LeftButton  :
        (button == 2) ? Qt::MiddleButton :
        (button == 3) ? Qt::RightButton  : Qt::LeftButton;

    const QPointF local(x, y);
    const QPointF global = target->mapToGlobal(local);
    QMouseEvent press(QEvent::MouseButtonPress, local, global,
                      qb, qb, Qt::NoModifier);
    QApplication::sendEvent(target, &press);
    QMouseEvent release(QEvent::MouseButtonRelease, local, global,
                        qb, Qt::NoButton, Qt::NoModifier);
    QApplication::sendEvent(target, &release);

    bridge->send_ok(id);
}

void LimnCommand::cmd_test_widget_tree(const QString& id, const QJsonObject&) {
    if (!main_widget) {
        bridge->send_fail(id, "no main widget");
        return;
    }
    QCoreApplication::processEvents();
    QJsonObject data;
    data.insert("tree", widget_to_json(main_widget));
    bridge->send_ok(id, data);
}

void LimnCommand::cmd_buffer_render_region(const QString& id, const QJsonObject& msg) {
    Document* doc = resolve_buffer(bridge, registry, id, msg);
    if (!doc) return;
    if (!msg.contains("page") || !msg.value("page").isDouble()) {
        bridge->send_fail(id, "missing or invalid 'page'");
        return;
    }
    if (!msg.contains("rect") || !msg.value("rect").isArray()) {
        bridge->send_fail(id, "missing or invalid 'rect' (expected 4-number array)");
        return;
    }
    const QJsonArray rect = msg.value("rect").toArray();
    if (rect.size() != 4) {
        bridge->send_fail(id, "'rect' must have exactly 4 numbers");
        return;
    }
    const int page = msg.value("page").toInt();
    const int dpi  = msg.contains("dpi") ? msg.value("dpi").toInt() : 72;
    const double x0 = rect[0].toDouble();
    const double y0 = rect[1].toDouble();
    const double x1 = rect[2].toDouble();
    const double y1 = rect[3].toDouble();
    try {
        bridge->send_ok(id, LimnMupdf::render_region_to_png(doc, page,
                                                              x0, y0, x1, y1, dpi));
    } catch (const std::exception& e) {
        bridge->send_fail(id, QString::fromUtf8(e.what()));
    }
}

// ─── frame/* (SPEC §3.2 §7.2, v0.18.0) ────────────────────────────────
//
// v0.18.0 ships the registry + wire commands + events. v0.18.1 will
// actually instantiate a second Qt MainWindow per frame. For now,
// frames are abstract: they own LimnWindows by frame_id, fire events
// when created/closed/focused, but only the f1 frame has a visible
// MainWidget.

void LimnCommand::cmd_frame_list(const QString& id, const QJsonObject&) {
    QJsonArray items;
    for (const QString& fid : frames->all_ids()) {
        LimnFrame* f = frames->get(fid);
        QJsonObject o;
        o.insert("frame-id", fid);
        // Only emit :focused when true — same rationale as LimnWindow::to_json:
        // CL clients often count-if on this and CL's :false keyword is truthy.
        if (f && f->focused) o.insert("focused", true);
        // Collect win-ids belonging to this frame.
        QJsonArray wids;
        for (const QString& wid : windows->all_ids()) {
            LimnWindow* w = windows->get(wid);
            if (w && w->frame_id == fid) wids.append(wid);
        }
        o.insert("win-ids", wids);
        items.append(o);
    }
    QJsonObject data;
    data.insert("items", items);
    bridge->send_ok(id, data);
}

void LimnCommand::cmd_frame_create(const QString& id, const QJsonObject&) {
    const QString new_id = frames->allocate_id();
    LimnFrame* f = frames->add(new_id);
    // v0.18.1: instantiate a real second Qt MainWindow. Each MainWidget
    // builds its own DocumentManager / DB / DocumentView / PdfRenderer
    // (see main_widget.cpp ctor), so they're functionally independent
    // — shared state is just the module-level fz_context (cloned per
    // worker thread inside PdfRenderer) and the static stub_config.
    //
    // Per-frame wire command routing (view/set, engine-load, etc.
    // targeting a window in fN drives fN's MainWidget) is queued as
    // v0.18.2. For v0.18.1 the second window appears, can be focused/
    // raised, and gets cleaned up on frame/close; commands still flow
    // through f1's MainWidget for compatibility.
    if (f && main_widget) {
        MainWidget* mw = new MainWidget();
        mw->setWindowTitle(QString("Limn — %1").arg(new_id));
        mw->resize(1200, 900);
        mw->show();
        f->widget      = mw;
        f->owns_widget = true;
    }
    QJsonObject ev;
    ev.insert("frame-id", new_id);
    bridge->push_event("frame-create", ev);
    QJsonObject data;
    data.insert("frame-id", new_id);
    bridge->send_ok(id, data);
}

void LimnCommand::cmd_frame_close(const QString& id, const QJsonObject& msg) {
    const QString fid = msg.value("frame-id").toString();
    if (fid.isEmpty()) {
        bridge->send_fail(id, "missing 'frame-id'");
        return;
    }
    if (!frames->has(fid)) {
        bridge->send_fail(id, QString("unknown frame-id: %1").arg(fid));
        return;
    }
    if (frames->count() <= 1) {
        bridge->send_fail(id, "cannot close the last frame");
        return;
    }
    // Cascade: drop all LimnWindows in this frame. We do this BEFORE
    // removing the frame entry so per-window cleanup (buffer-id
    // detachment, etc.) sees consistent state.
    for (const QString& wid : windows->all_ids()) {
        LimnWindow* w = windows->get(wid);
        if (w && w->frame_id == fid) windows->remove(wid);
    }
    // v0.18.1: tear down the Qt MainWindow if this frame owns one.
    LimnFrame* f = frames->get(fid);
    if (f && f->widget && f->owns_widget) {
        f->widget->hide();
        f->widget->deleteLater();   // safe inside an event handler
        f->widget = nullptr;
    }
    frames->remove(fid);
    QJsonObject ev;
    ev.insert("frame-id", fid);
    bridge->push_event("frame-close", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_frame_focus(const QString& id, const QJsonObject& msg) {
    const QString fid = msg.value("frame-id").toString();
    if (!frames->has(fid)) {
        bridge->send_fail(id, QString("unknown frame-id: %1").arg(fid));
        return;
    }
    frames->set_focused(fid);
    // v0.18.1: actually raise the corresponding OS window. For f1 we
    // use main_widget (passed at construction); for fN > 1 we use the
    // frame's owned widget. Skip in headless contexts where neither
    // exists.
    LimnFrame* f = frames->get(fid);
    MainWidget* target = nullptr;
    if (fid == "f1")           target = main_widget;
    else if (f && f->widget)   target = f->widget;
    if (target) {
        target->show();
        target->raise();
        target->activateWindow();
    }
    QJsonObject ev;
    ev.insert("frame-id", fid);
    bridge->push_event("frame-focus", ev);
    bridge->send_ok(id);
}
