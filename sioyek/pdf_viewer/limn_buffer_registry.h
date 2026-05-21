#pragma once
//
// LimnBufferRegistry maps buffer-id strings ("b1", "b2", ...) to Document*.
// A buffer is a logical content unit. The underlying Document is owned by
// sioyek's DocumentManager (which caches by path), so the registry does NOT
// own Documents — it just tracks identity for the Limn protocol.
//
#include <QHash>
#include <QString>
#include <QStringList>

class Document;

class LimnBufferRegistry {
public:
    // Allocates a fresh buffer-id, maps it to doc. If doc is already
    // registered, returns the existing id (same buffer, same id).
    QString register_buffer(Document* doc);

    // Removes the mapping. Doesn't destroy the Document.
    // Returns true if id existed, false otherwise.
    bool unregister(const QString& buffer_id);

    // Returns Document* or nullptr.
    Document* lookup(const QString& buffer_id) const;

    // Reverse lookup: returns empty string if doc not registered.
    QString find_id(Document* doc) const;

    QStringList all_ids() const;
    int count() const { return by_id.size(); }

private:
    QHash<QString, Document*> by_id;
    int next_seq = 1;
};
