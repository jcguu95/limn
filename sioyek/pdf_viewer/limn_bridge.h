#pragma once
//
// LimnBridge: Unix-socket JSON message bus between Backend (SBCL) and
// Frontend (this Qt process).
//
// Responsibilities:
//   - Own the QLocalServer and a single client connection.
//   - Read newline-delimited JSON, parse, hand off to the command handler.
//   - Send back ok/fail responses with matching id.
//   - Push asynchronous events (no id).
//
// The bridge is dumb about commands. A LimnCommand is plugged in via
// set_command_handler() and receives parsed JSON objects.
//
#include <QObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QJsonObject>
#include <QJsonArray>

class LimnCommand;

class LimnBridge : public QObject {
    Q_OBJECT
public:
    LimnBridge(const QString& socket_path, QObject* parent = nullptr);
    ~LimnBridge() override;

    void set_command_handler(LimnCommand* handler) { command_handler = handler; }

    // Build & write response messages. Always include the matching id.
    void send_ok(const QString& id);
    void send_ok(const QString& id, const QJsonObject& data);
    void send_ok_array(const QString& id, const QJsonArray& data);   // data is array
    void send_fail(const QString& id, const QString& error);

    // Push an event. Adds the "event" field; payload provides the rest.
    void push_event(const QString& event_type, const QJsonObject& payload);

    // True if a client is currently connected.
    bool has_client() const;

private slots:
    void on_new_connection();
    void on_ready_read();
    void on_disconnected();

private:
    void dispatch_line(const QByteArray& line);
    void write_object(const QJsonObject& obj);

    QString        socket_path;
    QLocalServer*  server          = nullptr;
    QLocalSocket*  client          = nullptr;
    QByteArray     read_buffer;            // accumulates partial lines
    LimnCommand*   command_handler = nullptr;
};
