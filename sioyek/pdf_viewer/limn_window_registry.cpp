#include "limn_window_registry.h"

QJsonObject LimnWindow::to_json() const {
    QJsonObject o;
    o.insert("win-id",    win_id);
    o.insert("frame-id",  frame_id);   // v0.18: every window belongs to a frame
    o.insert("type",      type);
    o.insert("engine",    "mupdf");
    if (!buffer_id.isEmpty()) o.insert("buffer-id", buffer_id);
    // Only emit `focused` when true — Lisp clients often `count-if` the
    // field and CL's :false keyword is still truthy in that context.
    if (focused) o.insert("focused", true);
    if (type == "float") {
        o.insert("x",      x);
        o.insert("y",      y);
        o.insert("width",  width);
        o.insert("height", height);
    }
    return o;
}

LimnWindowRegistry::LimnWindowRegistry() {
    LimnWindow w1;
    w1.win_id  = "w1";
    w1.type    = "tiled";
    w1.focused = true;
    windows.append(w1);
}

bool LimnWindowRegistry::has(const QString& win_id) const {
    for (const auto& w : windows)
        if (w.win_id == win_id) return true;
    return false;
}

LimnWindow* LimnWindowRegistry::get(const QString& win_id) {
    for (auto& w : windows)
        if (w.win_id == win_id) return &w;
    return nullptr;
}

QStringList LimnWindowRegistry::all_ids() const {
    QStringList ids;
    for (const auto& w : windows) ids.append(w.win_id);
    return ids;
}

int LimnWindowRegistry::tiled_count() const {
    int n = 0;
    for (const auto& w : windows)
        if (w.type == "tiled") ++n;
    return n;
}

QString LimnWindowRegistry::allocate_id() {
    return QString("w%1").arg(next_seq++);
}

LimnWindow* LimnWindowRegistry::add_tiled(const QString& win_id) {
    LimnWindow w;
    w.win_id = win_id;
    w.type   = "tiled";
    windows.append(w);
    return &windows.last();
}

LimnWindow* LimnWindowRegistry::add_float(const QString& win_id,
                                            int x, int y, int width, int height) {
    LimnWindow w;
    w.win_id = win_id;
    w.type   = "float";
    w.x      = x;
    w.y      = y;
    w.width  = (width  > 0) ? width  : 400;
    w.height = (height > 0) ? height : 300;
    windows.append(w);
    return &windows.last();
}

bool LimnWindowRegistry::remove(const QString& win_id) {
    for (int i = 0; i < windows.size(); ++i) {
        if (windows[i].win_id == win_id) {
            const bool was_focused = windows[i].focused;
            windows.removeAt(i);
            // Transfer focus to first remaining tiled window
            if (was_focused) {
                for (auto& w : windows) {
                    if (w.type == "tiled") { w.focused = true; break; }
                }
            }
            return true;
        }
    }
    return false;
}

void LimnWindowRegistry::set_focused(const QString& win_id) {
    for (auto& w : windows) w.focused = (w.win_id == win_id);
}

QString LimnWindowRegistry::focused_id() const {
    for (const auto& w : windows)
        if (w.focused) return w.win_id;
    return QString();
}

QJsonArray LimnWindowRegistry::to_json() const {
    QJsonArray arr;
    for (const auto& w : windows) arr.append(w.to_json());
    return arr;
}

// ─── LimnFrameRegistry (v0.18.0) ──────────────────────────────────────

LimnFrameRegistry::LimnFrameRegistry() {
    LimnFrame f1;
    f1.frame_id = "f1";
    f1.focused  = true;
    frames.append(f1);
}

bool LimnFrameRegistry::has(const QString& fid) const {
    for (const auto& f : frames) if (f.frame_id == fid) return true;
    return false;
}

LimnFrame* LimnFrameRegistry::get(const QString& fid) {
    for (auto& f : frames) if (f.frame_id == fid) return &f;
    return nullptr;
}

QString LimnFrameRegistry::allocate_id() {
    return QString("f%1").arg(next_seq++);
}

LimnFrame* LimnFrameRegistry::add(const QString& fid) {
    LimnFrame f;
    f.frame_id = fid;
    f.focused  = false;     // new frame doesn't steal focus by default
    frames.append(f);
    return &frames.last();
}

bool LimnFrameRegistry::remove(const QString& fid) {
    for (int i = 0; i < frames.size(); ++i) {
        if (frames[i].frame_id == fid) {
            const bool was_focused = frames[i].focused;
            frames.removeAt(i);
            // If we just removed the focused frame, fall back to the
            // first remaining (typically f1) to keep an invariant of
            // exactly-one-focused.
            if (was_focused && !frames.isEmpty()) frames.first().focused = true;
            return true;
        }
    }
    return false;
}

void LimnFrameRegistry::set_focused(const QString& fid) {
    for (auto& f : frames) f.focused = (f.frame_id == fid);
}

QString LimnFrameRegistry::focused_id() const {
    for (const auto& f : frames) if (f.focused) return f.frame_id;
    return frames.isEmpty() ? QString() : frames.first().frame_id;
}

QStringList LimnFrameRegistry::all_ids() const {
    QStringList ids;
    for (const auto& f : frames) ids.append(f.frame_id);
    return ids;
}
