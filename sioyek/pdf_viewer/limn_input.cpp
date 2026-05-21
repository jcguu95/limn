#include "limn_input.h"

#include "limn_bridge.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QString>

namespace {

QString key_to_string(QKeyEvent* ev) {
    // Prefer the printable text when available (covers letters & symbols).
    QString t = ev->text();
    if (!t.isEmpty() && t.at(0).isPrint() && !t.at(0).isSpace()) return t;

    switch (ev->key()) {
        case Qt::Key_Return:    return "RET";
        case Qt::Key_Enter:     return "RET";
        case Qt::Key_Escape:    return "ESC";
        case Qt::Key_Tab:       return "TAB";
        case Qt::Key_Backtab:   return "BACKTAB";
        case Qt::Key_Space:     return "SPC";
        case Qt::Key_Backspace: return "BS";
        case Qt::Key_Delete:    return "DEL";
        case Qt::Key_Up:        return "<up>";
        case Qt::Key_Down:      return "<down>";
        case Qt::Key_Left:      return "<left>";
        case Qt::Key_Right:     return "<right>";
        case Qt::Key_Home:      return "<home>";
        case Qt::Key_End:       return "<end>";
        case Qt::Key_PageUp:    return "<pageup>";
        case Qt::Key_PageDown:  return "<pagedown>";
        default:
            return QString("<key-%1>").arg(ev->key());
    }
}

QJsonArray modifiers_to_array(Qt::KeyboardModifiers mods) {
    QJsonArray a;
    if (mods & Qt::ControlModifier) a.append("ctrl");
    if (mods & Qt::ShiftModifier)   a.append("shift");
    if (mods & Qt::AltModifier)     a.append("alt");
    if (mods & Qt::MetaModifier)    a.append("meta");
    return a;
}

QJsonArray buttons_to_array(Qt::MouseButtons b) {
    // not used in spec right now, but kept for future
    QJsonArray a;
    if (b & Qt::LeftButton)   a.append("left");
    if (b & Qt::RightButton)  a.append("right");
    if (b & Qt::MiddleButton) a.append("middle");
    return a;
}

int button_id(Qt::MouseButton b) {
    if (b == Qt::LeftButton)   return 1;
    if (b == Qt::MiddleButton) return 2;
    if (b == Qt::RightButton)  return 3;
    return 0;
}

}  // anonymous namespace

LimnInputFilter::LimnInputFilter(LimnBridge* bridge, QObject* parent)
    : QObject(parent), bridge(bridge) {}

bool LimnInputFilter::eventFilter(QObject* obj, QEvent* ev) {
    if (!bridge) return false;

    switch (ev->type()) {
        case QEvent::KeyPress: {
            auto* kev = static_cast<QKeyEvent*>(ev);
            QJsonObject e;
            e.insert("frame-id", "f1");
            e.insert("key",  key_to_string(kev));
            e.insert("mods", modifiers_to_array(kev->modifiers()));
            bridge->push_event("key", e);
            break;
        }
        case QEvent::MouseButtonPress: {
            auto* mev = static_cast<QMouseEvent*>(ev);
            QJsonObject e;
            e.insert("frame-id", "f1");
            e.insert("win-id",   "w1");
            e.insert("page",     0);                            // ← TODO: map widget pos to page
            e.insert("x",        mev->position().x());
            e.insert("y",        mev->position().y());
            e.insert("button",   button_id(mev->button()));
            bridge->push_event("mouse-click", e);
            break;
        }
        case QEvent::Wheel: {
            auto* wev = static_cast<QWheelEvent*>(ev);
            QJsonObject e;
            e.insert("frame-id", "f1");
            e.insert("win-id",   "w1");
            e.insert("dx",       wev->angleDelta().x());
            e.insert("dy",       wev->angleDelta().y());
            bridge->push_event("scroll", e);
            break;
        }
        case QEvent::Resize: {
            auto* rev = static_cast<QResizeEvent*>(ev);
            QJsonObject e;
            e.insert("frame-id", "f1");
            e.insert("win-id",   "w1");
            e.insert("width",    rev->size().width());
            e.insert("height",   rev->size().height());
            bridge->push_event("resize", e);
            break;
        }
        default:
            break;
    }
    return false;   // don't consume the event — let Qt continue dispatching
}
