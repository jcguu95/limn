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
#include <QObject>
#include <QJsonObject>
#include <QString>

class LimnBridge;
class LimnBufferRegistry;
class MainWidget;
class Document;
struct LimnOptions;

class LimnCommand : public QObject {
    Q_OBJECT
public:
    LimnCommand(LimnBridge*         bridge,
                LimnBufferRegistry* registry,
                MainWidget*         main_widget,
                const LimnOptions&  options,
                QObject*            parent = nullptr);

    // Entry point from LimnBridge after JSON parsing.
    void dispatch(const QJsonObject& msg);

private:
    // ─── bridge/* ─────────────────────────────────────────────────────
    void cmd_bridge_capabilities(const QString& id, const QJsonObject& msg);
    void cmd_bridge_engine_load (const QString& id, const QJsonObject& msg);
    void cmd_bridge_win_list    (const QString& id, const QJsonObject& msg);

    // ─── view/* ───────────────────────────────────────────────────────
    void cmd_view_set     (const QString& id, const QJsonObject& msg);
    void cmd_view_get     (const QString& id, const QJsonObject& msg);
    void cmd_view_overlays(const QString& id, const QJsonObject& msg);

    // ─── buffer/* ─────────────────────────────────────────────────────
    void cmd_buffer_open         (const QString& id, const QJsonObject& msg);
    void cmd_buffer_close        (const QString& id, const QJsonObject& msg);
    void cmd_buffer_toc          (const QString& id, const QJsonObject& msg);
    void cmd_buffer_text         (const QString& id, const QJsonObject& msg);
    void cmd_buffer_links        (const QString& id, const QJsonObject& msg);
    void cmd_buffer_metadata     (const QString& id, const QJsonObject& msg);
    void cmd_buffer_render       (const QString& id, const QJsonObject& msg);
    void cmd_buffer_render_region(const QString& id, const QJsonObject& msg);

    // ─── test/* (enabled only when --test-mode is set) ────────────────
    void cmd_test_inject_key        (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_mouse_click(const QString& id, const QJsonObject& msg);
    void cmd_test_inject_mouse_drag (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_scroll     (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_gesture    (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_drag_drop  (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_ime_commit (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_audio_input(const QString& id, const QJsonObject& msg);
    void cmd_test_inject_resize     (const QString& id, const QJsonObject& msg);
    void cmd_test_emit_heartbeat    (const QString& id, const QJsonObject& msg);
    void cmd_test_snapshot          (const QString& id, const QJsonObject& msg);
    void cmd_test_flush_caches      (const QString& id, const QJsonObject& msg);

    // Helpers
    QJsonObject build_open_data(const QString& buffer_id, Document* doc);
    QJsonObject collect_view_state();
    void        emit_buffer_opened(const QString& buffer_id, Document* doc);
    void        emit_buffer_closed(const QString& buffer_id);

    LimnBridge*         bridge;
    LimnBufferRegistry* registry;
    MainWidget*         main_widget;
    bool                test_mode;
    // Per-window state. For Phase 2/3 there's a single window "w1".
    QString             w1_buffer_id;
};
