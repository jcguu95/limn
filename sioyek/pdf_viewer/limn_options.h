#pragma once
//
// Limn CLI options parser.
//
// Supported flags:
//   --headless           start without showing window (for testing/CI)
//   --socket <path>      socket path (default: /tmp/limn-<PID>)
//   --test-mode          enable test/* command namespace
//   <path>               positional: open this file in default window
//
#include <QString>
#include <QStringList>

struct LimnOptions {
    bool    headless     = false;
    bool    test_mode    = false;
    QString socket_path;          // empty means use default /tmp/limn-<PID>
    QString initial_path;         // first non-flag positional, if any

    QString effective_socket_path() const;   // resolves the empty default

    // Parse from app.arguments(). Tolerates unknown flags by ignoring them.
    static LimnOptions parse(const QStringList& args);
};
