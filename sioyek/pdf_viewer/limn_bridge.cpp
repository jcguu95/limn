#include "limn_bridge.h"
#include "limn_command.h"

#include <QDateTime>
#include <QJsonDocument>

LimnBridge::LimnBridge(const QString& socket_path, QObject* parent)
    : QObject(parent), socket_path(socket_path) {
    // Clean up stale socket file from a previous crash/run.
    QLocalServer::removeServer(socket_path);

    server = new QLocalServer(this);
    if (!server->listen(socket_path)) {
        qFatal("LimnBridge: failed to listen on %s: %s",
                qPrintable(socket_path),
                qPrintable(server->errorString()));
    }
    connect(server, &QLocalServer::newConnection,
            this,   &LimnBridge::on_new_connection);

    // Periodic heartbeat — every 3 seconds. Backend may use this to detect
    // a healthy bridge connection.
    heartbeat_timer = new QTimer(this);
    heartbeat_timer->setInterval(3000);
    connect(heartbeat_timer, &QTimer::timeout, this, &LimnBridge::emit_heartbeat);
    heartbeat_timer->start();

    fprintf(stderr, "[limn-bridge] listening on %s\n", qPrintable(socket_path));
}

LimnBridge::~LimnBridge() {
    if (client) client->disconnectFromServer();
    if (server) server->close();
    QLocalServer::removeServer(socket_path);
}

bool LimnBridge::has_client() const {
    return client && client->state() == QLocalSocket::ConnectedState;
}

// -- new connection / disconnection --------------------------------------

void LimnBridge::on_new_connection() {
    if (client) {
        // For now we accept only one client (spec: 同一條連線).
        // Detach our slots first so the old client's delayed disconnected
        // signal can't accidentally clear the NEW client we're about to set.
        QObject::disconnect(client, nullptr, this, nullptr);
        client->disconnectFromServer();
        client->deleteLater();
        client = nullptr;
        read_buffer.clear();
    }
    client = server->nextPendingConnection();
    if (!client) return;
    connect(client, &QLocalSocket::readyRead,    this, &LimnBridge::on_ready_read);
    connect(client, &QLocalSocket::disconnected, this, &LimnBridge::on_disconnected);
    fprintf(stderr, "[limn-bridge] client connected\n");
}

void LimnBridge::on_disconnected() {
    // Only act if the sender matches our current client. With lifecycle
    // disconnect/reconnect churn, a stale 'disconnected' signal from an
    // old QLocalSocket may arrive after we've already adopted a new one.
    QObject* who = sender();
    if (who && who == client) {
        client->deleteLater();
        client = nullptr;
        read_buffer.clear();
    }
    fprintf(stderr, "[limn-bridge] client disconnected\n");
}

// -- read: accumulate, split on \n, dispatch each complete line ----------

void LimnBridge::on_ready_read() {
    if (!client) return;
    read_buffer.append(client->readAll());
    int newline_pos;
    while ((newline_pos = read_buffer.indexOf('\n')) != -1) {
        QByteArray line = read_buffer.left(newline_pos);
        read_buffer.remove(0, newline_pos + 1);
        if (line.trimmed().isEmpty()) continue;
        dispatch_line(line);
    }
}

void LimnBridge::dispatch_line(const QByteArray& line) {
    QJsonParseError err;
    QJsonDocument doc = QJsonDocument::fromJson(line, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        // Malformed JSON: we may not have an id. Push an error event.
        QJsonObject ev;
        ev.insert("cmd",     QJsonValue());
        ev.insert("message", QString("malformed JSON: %1").arg(err.errorString()));
        push_event("error", ev);
        return;
    }
    if (command_handler) {
        command_handler->dispatch(doc.object());
    } else {
        QString id = doc.object().value("id").toString();
        send_fail(id, "no command handler installed");
    }
}

// -- writing -------------------------------------------------------------

void LimnBridge::write_object(const QJsonObject& obj) {
    if (!has_client()) return;
    QJsonDocument doc(obj);
    QByteArray bytes = doc.toJson(QJsonDocument::Compact);
    bytes.append('\n');
    client->write(bytes);
    client->flush();
}

void LimnBridge::send_ok(const QString& id) {
    QJsonObject o;
    if (!id.isEmpty()) o.insert("id", id);
    o.insert("ok", true);
    write_object(o);
}

void LimnBridge::send_ok(const QString& id, const QJsonObject& data) {
    QJsonObject o;
    if (!id.isEmpty()) o.insert("id", id);
    o.insert("ok", true);
    o.insert("data", data);
    write_object(o);
}

void LimnBridge::send_ok_array(const QString& id, const QJsonArray& data) {
    QJsonObject o;
    if (!id.isEmpty()) o.insert("id", id);
    o.insert("ok", true);
    o.insert("data", data);
    write_object(o);
}

void LimnBridge::send_fail(const QString& id, const QString& error) {
    QJsonObject o;
    if (!id.isEmpty()) o.insert("id", id);
    o.insert("ok", false);
    o.insert("error", error);
    write_object(o);
}

void LimnBridge::push_event(const QString& event_type, const QJsonObject& payload) {
    QJsonObject o = payload;
    o.insert("event", event_type);
    write_object(o);
}

void LimnBridge::emit_heartbeat() {
    QJsonObject ev;
    ev.insert("timestamp",
              static_cast<qint64>(QDateTime::currentMSecsSinceEpoch()));
    push_event("heartbeat", ev);
}
