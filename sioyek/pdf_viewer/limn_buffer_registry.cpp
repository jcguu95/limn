#include "limn_buffer_registry.h"

QString LimnBufferRegistry::register_buffer(Document* doc) {
    if (!doc) return QString();
    // Always allocate a fresh id — each open is a logically distinct buffer
    // even if it points to the same underlying Document (cached by sioyek's
    // DocumentManager). For find_id() reverse lookup, the first matching id
    // is returned (any one works for our purposes).
    QString id = QString("b%1").arg(next_seq++);
    by_id.insert(id, doc);
    return id;
}

bool LimnBufferRegistry::unregister(const QString& buffer_id) {
    return by_id.remove(buffer_id) > 0;
}

Document* LimnBufferRegistry::lookup(const QString& buffer_id) const {
    return by_id.value(buffer_id, nullptr);
}

QString LimnBufferRegistry::find_id(Document* doc) const {
    for (auto it = by_id.constBegin(); it != by_id.constEnd(); ++it) {
        if (it.value() == doc) return it.key();
    }
    return QString();
}

QStringList LimnBufferRegistry::all_ids() const {
    return by_id.keys();
}
