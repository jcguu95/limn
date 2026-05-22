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
#include <QHash>

class LimnBridge;
class LimnBufferRegistry;
class LimnWindowRegistry;
class MainWidget;
class Document;
struct LimnOptions;

class LimnCommand : public QObject {
    Q_OBJECT
public:
    LimnCommand(LimnBridge*         bridge,
                LimnBufferRegistry* registry,
                LimnWindowRegistry* windows,
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
    // SPEC v0.5 §5.3 後段 — text engine 編輯 primitives
    void cmd_buffer_cursor_get   (const QString& id, const QJsonObject& msg);
    void cmd_buffer_cursor_set   (const QString& id, const QJsonObject& msg);
    void cmd_buffer_insert       (const QString& id, const QJsonObject& msg);
    void cmd_buffer_delete       (const QString& id, const QJsonObject& msg);

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
    void cmd_test_grab_window       (const QString& id, const QJsonObject& msg);
    void cmd_test_widget_tree       (const QString& id, const QJsonObject& msg);
    void cmd_test_inject_qt_key     (const QString& id, const QJsonObject& msg);

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
private:

    // Helpers
    QJsonObject build_open_data(const QString& buffer_id, Document* doc);
    QJsonObject collect_view_state(const QString& win_id);
    void        emit_buffer_opened(const QString& buffer_id, Document* doc);
    void        emit_buffer_closed(const QString& buffer_id);

    LimnBridge*         bridge;
    LimnBufferRegistry* registry;
    LimnWindowRegistry* windows;
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
    QHash<QString, QString> text_buffers;
    QHash<QString, int>     text_cursors;     // per-buffer cursor (offset)
    int                     next_text_seq = 1;

    // ─── minibuffer meta-state (SPEC §5.4) ─────────────────────────
    // The text content lives in text_buffers["*minibuffer*"]. These
    // two are the "frame around" the content: is the minibuffer
    // currently shown? what's the prompt prefix?
    bool     minibuffer_open = false;
    QString  minibuffer_prompt;
};
