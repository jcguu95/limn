#pragma once
//
// Limn CLI options parser.
//
// Supported flags:
//   --headless           start without showing window (for testing/CI)
//   --socket <path>      socket path (default: /tmp/limn-<PID>)
//   --test-mode          enable test/* command namespace
//
// v0.39: positional <path> arg removed. Document opening goes through
// the bridge's buffer/open command exclusively — having a CLI shortcut
// that bypassed it created a dual-path bug where pdf-mode never got
// installed for the loaded window (no buffer-opened event fired).
//
#include <QString>
#include <QStringList>

struct LimnOptions {
    bool    headless     = false;
    bool    test_mode    = false;
    QString socket_path;          // empty means use default /tmp/limn-<PID>

    QString effective_socket_path() const;   // resolves the empty default

    // Parse from app.arguments(). Tolerates unknown flags by ignoring them.
    static LimnOptions parse(const QStringList& args);
};
