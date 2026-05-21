#include "limn_command.h"

#include "limn_bridge.h"
#include "limn_buffer_registry.h"
#include "limn_engine_mupdf.h"
#include "limn_options.h"
#include "main_widget.h"
#include "document.h"
#include "document_view.h"
#include "pdf_view_opengl_widget.h"

#include <QJsonArray>
#include <QJsonValue>
#include <cmath>
#include <stdexcept>

namespace {

// Per-window engine state we track ourselves (sioyek's DocumentView /
// PdfViewOpenGLWidget don't expose getters for these). For Phase 2/3 we
// have a single window "w1"; later this becomes per-window state.
struct EngineState {
    bool dark_mode = false;
    int  rotation  = 0;        // 0/90/180/270
    int  page      = 0;        // last-set page; tracked because in headless
                                // mode sioyek's page-from-offset can lag.
    int  overlay_count = 0;    // last view/overlays size, for test/snapshot
};

static double safe_double(float v) {
    if (std::isnan(v) || std::isinf(v)) return 0.0;
    return static_cast<double>(v);
}

static EngineState g_state_w1;   // single-window placeholder

QString DEFAULT_WIN_ID = QStringLiteral("w1");

// Convert std::wstring (sioyek) ↔ QString
QString w_to_q(const std::wstring& w) {
    return QString::fromStdWString(w);
}
std::wstring q_to_w(const QString& q) {
    return q.toStdWString();
}

}  // anonymous namespace

LimnCommand::LimnCommand(LimnBridge*         bridge,
                         LimnBufferRegistry* registry,
                         MainWidget*         main_widget,
                         const LimnOptions&  options,
                         QObject*            parent)
    : QObject(parent),
      bridge(bridge),
      registry(registry),
      main_widget(main_widget),
      test_mode(options.test_mode) {}

// ─── Dispatch ──────────────────────────────────────────────────────────

void LimnCommand::dispatch(const QJsonObject& msg) {
    const QString id  = msg.value("id").toString();
    const QString cmd = msg.value("cmd").toString();

    if (cmd.isEmpty()) {
        bridge->send_fail(id, "missing or empty 'cmd' field");
        return;
    }

    // bridge/*
    if (cmd == "bridge/capabilities") { cmd_bridge_capabilities(id, msg); return; }
    if (cmd == "bridge/engine-load")  { cmd_bridge_engine_load (id, msg); return; }
    if (cmd == "bridge/win-list")     { cmd_bridge_win_list    (id, msg); return; }

    // view/*
    if (cmd == "view/set")      { cmd_view_set     (id, msg); return; }
    if (cmd == "view/get")      { cmd_view_get     (id, msg); return; }
    if (cmd == "view/overlays") { cmd_view_overlays(id, msg); return; }

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
        bridge->send_fail(id, QString("unknown test command: %1").arg(cmd));
        return;
    }

    bridge->send_fail(id, QString("unknown command: %1").arg(cmd));
}

// ─── bridge/capabilities ──────────────────────────────────────────────

void LimnCommand::cmd_bridge_capabilities(const QString& id, const QJsonObject&) {
    QJsonObject data;
    QJsonArray engines;  engines.append("mupdf");
    data.insert("engines",  engines);
    data.insert("frontend", "qt");
    data.insert("version",  "0.3");
    bridge->send_ok(id, data);
}

// ─── bridge/engine-load ───────────────────────────────────────────────

void LimnCommand::cmd_bridge_engine_load(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    const QString engine = msg.value("engine").toString();
    const QString path   = msg.value("path").toString();

    if (win_id.isEmpty() || engine.isEmpty() || path.isEmpty()) {
        bridge->send_fail(id, "missing required field: win-id, engine, and path are required");
        return;
    }
    if (win_id != DEFAULT_WIN_ID) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    if (engine != "mupdf") {
        bridge->send_fail(id, QString("unknown engine: %1").arg(engine));
        return;
    }

    const bool ok = main_widget->open_document(q_to_w(path));
    if (!ok) {
        const QString err = QString("failed to open: %1").arg(path);
        bridge->send_fail(id, err);
        // Per spec 7.4: engine MUST push an `error` event on failure.
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
    w1_buffer_id = buffer_id;        // remember which id is "live" in w1

    // Reset our per-window engine-state tracking — fresh doc means page 0,
    // no rotation, no dark-mode override.
    g_state_w1 = EngineState{};
    main_widget->opengl_widget()->set_dark_mode(false);

    QJsonObject data;
    data.insert("buffer-id", buffer_id);
    bridge->send_ok(id, data);

    emit_buffer_opened(buffer_id, doc);
}

// ─── bridge/win-list ──────────────────────────────────────────────────

void LimnCommand::cmd_bridge_win_list(const QString& id, const QJsonObject&) {
    QJsonArray data;
    QJsonObject w1;
    w1.insert("win-id", DEFAULT_WIN_ID);
    w1.insert("engine", "mupdf");
    w1.insert("type",   "tiled");
    if (!w1_buffer_id.isEmpty()) {
        w1.insert("buffer-id", w1_buffer_id);
    }
    data.append(w1);
    bridge->send_ok_array(id, data);
}

// ─── view/set ─────────────────────────────────────────────────────────

void LimnCommand::cmd_view_set(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    if (win_id != DEFAULT_WIN_ID) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }

    DocumentView* dv = main_widget->document_view();
    Document* doc = dv->get_document();
    if (!doc) {
        bridge->send_fail(id, "no buffer loaded in this window");
        return;
    }

    // Validate first (atomicity: don't partially apply)
    if (msg.contains("page")) {
        const QJsonValue v = msg.value("page");
        if (!v.isDouble()) { bridge->send_fail(id, "'page' must be integer"); return; }
        const int p = v.toInt();
        if (p < 0)              { bridge->send_fail(id, "page must be >= 0"); return; }
        if (p >= doc->num_pages()) {
            bridge->send_fail(id, QString("page %1 out of range (num-pages=%2)")
                                    .arg(p).arg(doc->num_pages()));
            return;
        }
    }
    if (msg.contains("zoom")) {
        const QJsonValue v = msg.value("zoom");
        if (!v.isDouble()) { bridge->send_fail(id, "'zoom' must be numeric"); return; }
        const double z = v.toDouble();
        if (z <= 0) { bridge->send_fail(id, "zoom must be > 0"); return; }
    }
    if (msg.contains("offset-y") && !msg.value("offset-y").isDouble()) {
        bridge->send_fail(id, "'offset-y' must be numeric"); return;
    }
    if (msg.contains("offset-x") && !msg.value("offset-x").isDouble()) {
        bridge->send_fail(id, "'offset-x' must be numeric"); return;
    }
    // engine-params validation
    if (msg.contains("engine-params") && !msg.value("engine-params").isObject()) {
        bridge->send_fail(id, "'engine-params' must be an object"); return;
    }

    // Apply (all validated above)
    if (msg.contains("zoom")) {
        dv->set_zoom_level(static_cast<float>(msg.value("zoom").toDouble()),
                           true, true);
    }
    if (msg.contains("page")) {
        const int p = msg.value("page").toInt();
        dv->goto_page(p);
        g_state_w1.page = p;
    }
    if (msg.contains("offset-y")) {
        const float oy = static_cast<float>(msg.value("offset-y").toDouble());
        const float ox = dv->get_offset_x();
        dv->set_offsets(ox, oy, true);
    }
    if (msg.contains("offset-x")) {
        const float ox = static_cast<float>(msg.value("offset-x").toDouble());
        const float oy = dv->get_offset_y();
        dv->set_offsets(ox, oy, true);
    }
    if (msg.contains("engine-params")) {
        const QJsonObject ep = msg.value("engine-params").toObject();
        if (ep.contains("dark-mode")) {
            const bool dm = ep.value("dark-mode").toBool();
            g_state_w1.dark_mode = dm;
            main_widget->opengl_widget()->set_dark_mode(dm);
        }
        if (ep.contains("rotation")) {
            const int target = ep.value("rotation").toInt();
            // Only accept multiples of 90 in [0, 360).
            if (target % 90 == 0 && target >= 0 && target < 360) {
                int diff = (target - g_state_w1.rotation + 360) % 360;
                const int steps = diff / 90;
                for (int i = 0; i < steps; ++i) dv->rotate();
                g_state_w1.rotation = target;
            }
            // Non-multiples are silently ignored (we accepted the response
            // already; per spec it's "rejected or snapped").
        }
        // Unknown engine-params keys are silently ignored.
    }

    main_widget->opengl_widget()->update();
    bridge->send_ok(id);
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
    if (win_id != DEFAULT_WIN_ID) {
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

    g_state_w1.overlay_count = layers.size();
    main_widget->opengl_widget()->update();
    bridge->send_ok(id);
}

// ─── view/get ─────────────────────────────────────────────────────────

void LimnCommand::cmd_view_get(const QString& id, const QJsonObject& msg) {
    const QString win_id = msg.value("win-id").toString();
    if (win_id != DEFAULT_WIN_ID) {
        bridge->send_fail(id, QString("unknown win-id: %1").arg(win_id));
        return;
    }
    bridge->send_ok(id, collect_view_state());
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
    w1_buffer_id = buffer_id;        // buffer/open shows in main view in v0.2

    // Reset per-window state since main view now shows this buffer.
    g_state_w1 = EngineState{};
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
    if (w1_buffer_id == buffer_id) w1_buffer_id.clear();
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

QJsonObject LimnCommand::collect_view_state() {
    QJsonObject data;
    DocumentView* dv = main_widget->document_view();
    Document* doc = dv->get_document();

    if (doc) {
        if (!w1_buffer_id.isEmpty()) data.insert("buffer-id", w1_buffer_id);
        data.insert("num-pages",  doc->num_pages());
        data.insert("page-count", doc->num_pages());
    }

    data.insert("page",     g_state_w1.page);
    data.insert("zoom",     safe_double(dv->get_zoom_level()));
    data.insert("offset-y", safe_double(dv->get_offset_y()));
    data.insert("offset-x", safe_double(dv->get_offset_x()));

    QJsonObject ep;
    ep.insert("dark-mode", g_state_w1.dark_mode);
    ep.insert("rotation",  g_state_w1.rotation);
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
    data.insert("overlay-count", g_state_w1.overlay_count);
    data.insert("test-mode",     test_mode);
    bridge->send_ok(id, data);
}

void LimnCommand::cmd_test_flush_caches(const QString& id, const QJsonObject&) {
    // No-op for now: sioyek's caches are managed by DocumentManager and
    // we don't expose a public flush. The test only verifies that the
    // command responds cleanly and the frontend stays usable.
    bridge->send_ok(id);
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
