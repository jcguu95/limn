#include "limn_command.h"

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
#include <QApplication>
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
                         MainWidget*         main_widget,
                         const LimnOptions&  options,
                         QObject*            parent)
    : QObject(parent),
      bridge(bridge),
      registry(registry),
      windows(windows),
      main_widget(main_widget),
      test_mode(options.test_mode) {
    // SPEC §1.2: bootstrap the three reserved text-engine buffers that
    // back the chrome text surfaces. These IDs are intentionally
    // bracketed with asterisks so they never collide with the auto-
    // allocated t1 / t2 / ... ids for user-opened text buffers.
    text_buffers.insert("*minibuffer*", QString());
    text_buffers.insert("*echo-area*",  QString());
    text_buffers.insert("*messages*",   QString());
}

// ─── Dispatch ──────────────────────────────────────────────────────────

void LimnCommand::dispatch(const QJsonObject& msg) {
    const QString id  = msg.value("id").toString();
    const QString cmd = msg.value("cmd").toString();

    if (cmd.isEmpty()) {
        bridge->send_fail(id, "missing or empty 'cmd' field");
        return;
    }

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

    // view/*
    if (cmd == "view/set")      { cmd_view_set     (id, msg); return; }
    if (cmd == "view/get")      { cmd_view_get     (id, msg); return; }
    if (cmd == "view/overlays") { cmd_view_overlays(id, msg); return; }

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
    if (cmd == "buffer/links")         { cmd_buffer_links        (id, msg); return; }
    if (cmd == "buffer/metadata")      { cmd_buffer_metadata     (id, msg); return; }
    if (cmd == "buffer/render")        { cmd_buffer_render       (id, msg); return; }
    if (cmd == "buffer/render-region") { cmd_buffer_render_region(id, msg); return; }

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
        if (cmd == "test/inject-ime-commit")  { cmd_test_inject_ime_commit (id, msg); return; }
        if (cmd == "test/inject-audio-input") { cmd_test_inject_audio_input(id, msg); return; }
        if (cmd == "test/inject-resize")      { cmd_test_inject_resize     (id, msg); return; }
        if (cmd == "test/emit-heartbeat")     { cmd_test_emit_heartbeat    (id, msg); return; }
        if (cmd == "test/snapshot")           { cmd_test_snapshot          (id, msg); return; }
        if (cmd == "test/flush-caches")       { cmd_test_flush_caches      (id, msg); return; }
        if (cmd == "test/grab-window")        { cmd_test_grab_window       (id, msg); return; }
        if (cmd == "test/widget-tree")        { cmd_test_widget_tree       (id, msg); return; }
        if (cmd == "test/inject-qt-key")      { cmd_test_inject_qt_key     (id, msg); return; }
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
        text_buffers.insert(tid, QString());
        win->buffer_id     = tid;
        win->page          = 0;
        win->zoom          = 1.0f;
        win->offset_x      = 0.0f;
        win->offset_y      = 0.0f;
        win->dark_mode     = false;
        win->rotation      = 0;
        win->overlay_count = 0;

        QJsonObject data;
        data.insert("buffer-id", tid);
        QJsonArray supports;
        supports.append("buffer/text");
        data.insert("supports", supports);
        bridge->send_ok(id, data);

        QJsonObject ev;
        ev.insert("frame-id",   "f1");
        ev.insert("buffer-id",  tid);
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

    Document* doc = main_widget->document_view()->get_document();
    if (!doc) {
        bridge->send_fail(id, "document loaded but not attached to view");
        return;
    }

    const QString buffer_id = registry->register_buffer(doc);

    // Reset per-window state for this window.
    win->buffer_id     = buffer_id;
    win->page          = 0;
    win->zoom          = 1.0f;
    win->offset_x      = 0.0f;
    win->offset_y      = 0.0f;
    win->dark_mode     = false;
    win->rotation      = 0;
    win->overlay_count = 0;
    main_widget->opengl_widget()->set_dark_mode(false);

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

    emit_buffer_opened(buffer_id, doc);
}

// ─── bridge/win-list ──────────────────────────────────────────────────

void LimnCommand::cmd_bridge_win_list(const QString& id, const QJsonObject&) {
    bridge->send_ok_array(id, windows->to_json());
}

// ─── bridge/win-split ──────────────────────────────────────────────────

void LimnCommand::cmd_bridge_win_split(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    const QString dir    = msg.value("dir").toString();
    if (!windows->has(win_id)) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    if (dir != "h" && dir != "v") {
        bridge->send_fail(id, QString("invalid 'dir' (expected 'h' or 'v'): %1").arg(dir));
        return;
    }
    const QString new_id = windows->allocate_id();
    windows->add_tiled(new_id);
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
    windows->set_focused(win_id);
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

    // The active document_view is the Qt widget; it currently holds whichever
    // doc was last loaded. For multi-window state independence, we track each
    // window's page/zoom in LimnWindow, and only forward to the live widget
    // if this window is the focused/active one.
    DocumentView* dv = main_widget->document_view();
    Document* doc = dv->get_document();
    const QString live_buf  = registry->find_id(doc);
    const bool    is_active = (!win->buffer_id.isEmpty()
                                && win->buffer_id == live_buf);

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
}

void LimnCommand::cmd_minibuffer_open(const QString& id, const QJsonObject& msg) {
    minibuffer_open   = true;
    minibuffer_prompt = msg.value("prompt").toString();   // empty = no prompt
    text_buffers["*minibuffer*"].clear();                 // fresh each open
    if (auto* c = chrome_of(main_widget))
        c->set_minibuffer(true, minibuffer_prompt, text_buffers["*minibuffer*"]);
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
        c->set_minibuffer(true, minibuffer_prompt, text_buffers["*minibuffer*"]);
    bridge->send_ok(id);
}

void LimnCommand::cmd_minibuffer_set_text(const QString& id, const QJsonObject& msg) {
    if (!minibuffer_open) {
        bridge->send_fail(id, "minibuffer/set-text: minibuffer is not open");
        return;
    }
    text_buffers["*minibuffer*"] = msg.value("text").toString();
    if (auto* c = chrome_of(main_widget))
        c->set_minibuffer(true, minibuffer_prompt, text_buffers["*minibuffer*"]);
    bridge->send_ok(id);
}

void LimnCommand::cmd_minibuffer_get(const QString& id, const QJsonObject&) {
    QJsonObject data;
    data.insert("open",   minibuffer_open);
    data.insert("prompt", minibuffer_prompt);
    data.insert("text",   text_buffers["*minibuffer*"]);
    bridge->send_ok(id, data);
}

// Called by LimnInputFilter on every KeyPress. Returns TRUE iff this
// keystroke was consumed by the minibuffer (so the filter should not
// also push a normal `key` event). See SPEC §6 Minibuffer 事件.
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
        ev.insert("text", text_buffers["*minibuffer*"]);
        bridge->push_event("minibuffer-submit", ev);
        return true;
    }
    if (key == "ESC") {
        bridge->push_event("minibuffer-cancel", ev);
        return true;
    }
    // Printable single-character key → accumulate into text.
    if (key.size() == 1 && key.at(0).isPrint() && !key.at(0).isSpace()) {
        text_buffers["*minibuffer*"].append(key);
        if (auto* c = chrome_of(main_widget))
            c->set_minibuffer(true, minibuffer_prompt, text_buffers["*minibuffer*"]);
        ev.insert("text", text_buffers["*minibuffer*"]);
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
    QString& log = text_buffers["*messages*"];
    if (!log.isEmpty()) log.append('\n');
    log.append(text);
    text_buffers["*echo-area*"] = text;
    if (auto* c = chrome_of(main_widget)) c->set_echo(text);
    bridge->send_ok(id);
}

void LimnCommand::cmd_message_log(const QString& id, const QJsonObject& msg) {
    const QString text = msg.value("text").toString();
    if (text.isEmpty()) {
        bridge->send_fail(id, "message/log: text must be non-empty");
        return;
    }
    QString& log = text_buffers["*messages*"];
    if (!log.isEmpty()) log.append('\n');
    log.append(text);
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

    if (!layer.contains("page") || !layer.value("page").isDouble())
        return QStringLiteral("layer missing or invalid 'page'");
    const int page = layer.value("page").toInt();
    if (page < 0) return QStringLiteral("layer 'page' must be >= 0");

    if (!layer.contains("color"))
        return QStringLiteral("layer missing 'color'");
    if (!is_valid_hex_color(layer.value("color").toString()))
        return QStringLiteral("layer 'color' must be #RRGGBB");

    if (!layer.contains("opacity"))
        return QStringLiteral("layer missing 'opacity'");
    if (!layer.value("opacity").isDouble())
        return QStringLiteral("layer 'opacity' must be numeric");

    if (type == "rect") {
        if (!layer.contains("rect"))
            return QStringLiteral("rect overlay missing 'rect'");
        if (!is_valid_rect_array(layer.value("rect")))
            return QStringLiteral("rect 'rect' must be [x0,y0,x1,y1]");
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

    win->overlay_count = layers.size();
    main_widget->opengl_widget()->update();
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
    }
    main_widget->opengl_widget()->set_dark_mode(false);

    bridge->send_ok(id, build_open_data(buffer_id, doc));
    emit_buffer_opened(buffer_id, doc);
}

// ─── buffer/close ─────────────────────────────────────────────────────

void LimnCommand::cmd_buffer_close(const QString& id, const QJsonObject& msg) {
    const QString buffer_id = msg.value("buffer-id").toString();
    if (buffer_id.isEmpty()) {
        bridge->send_fail(id, "missing 'buffer-id'");
        return;
    }
    if (!registry->lookup(buffer_id)) {
        bridge->send_fail(id, QString("unknown buffer-id: %1").arg(buffer_id));
        return;
    }
    registry->unregister(buffer_id);
    // Detach from any window that pointed at this buffer.
    for (const QString& wid : windows->all_ids()) {
        LimnWindow* w = windows->get(wid);
        if (w && w->buffer_id == buffer_id) w->buffer_id.clear();
    }
    bridge->send_ok(id);
    emit_buffer_closed(buffer_id);
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
    Document* live_doc = dv ? dv->get_document() : nullptr;
    const QString live_buf = registry->find_id(live_doc);
    const bool is_active = (!win->buffer_id.isEmpty()
                            && win->buffer_id == live_buf);
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
    return data;
}

void LimnCommand::emit_buffer_opened(const QString& buffer_id, Document* doc) {
    QJsonObject ev;
    ev.insert("frame-id",   "f1");
    ev.insert("buffer-id",  buffer_id);
    ev.insert("page-count", doc ? doc->num_pages() : 0);
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

void LimnCommand::cmd_buffer_text(const QString& id, const QJsonObject& msg) {
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
    bridge->push_event("ime-commit", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_inject_audio_input(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg, {"frame-id", "text"});
    bridge->push_event("audio-input", ev);
    bridge->send_ok(id);
}

void LimnCommand::cmd_test_inject_resize(const QString& id, const QJsonObject& msg) {
    QJsonObject ev = pick_keys(msg, {"frame-id", "win-id", "width", "height"});
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
