#include "limn_options.h"

#include <unistd.h>   // getpid

QString LimnOptions::effective_socket_path() const {
    if (!socket_path.isEmpty()) return socket_path;
    return QString("/tmp/limn-%1").arg(static_cast<qint64>(getpid()));
}

LimnOptions LimnOptions::parse(const QStringList& args) {
    LimnOptions o;
    // args[0] is the program name; skip it.
    for (int i = 1; i < args.size(); ++i) {
        const QString& a = args[i];
        if (a == "--headless") {
            o.headless = true;
        } else if (a == "--test-mode") {
            o.test_mode = true;
        } else if (a == "--socket") {
            if (i + 1 < args.size()) {
                o.socket_path = args[i + 1];
                ++i;
            }
        } else if (a.startsWith("--socket=")) {
            o.socket_path = a.mid(QString("--socket=").size());
        } else if (!a.startsWith("--")) {
            // first positional → initial document
            if (o.initial_path.isEmpty()) o.initial_path = a;
        }
        // unknown flags silently ignored (Qt may inject its own)
    }
    return o;
}
