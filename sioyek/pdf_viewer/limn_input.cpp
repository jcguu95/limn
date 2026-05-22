#include "limn_input.h"

#include "limn_bridge.h"
#include "limn_command.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QWindow>

namespace {

QString key_to_string(QKeyEvent* ev) {
    // Prefer the printable text when available (covers letters & symbols).
    QString t = ev->text();
    if (!t.isEmpty() && t.at(0).isPrint() && !t.at(0).isSpace()) return t;

    // Letter / digit keys with a modifier produce non-printable text:
    // Ctrl-d gives ASCII 0x04, not "d". Without this fallback the bridge
    // would report key="<key-68>" mods=["ctrl"] and the user's "C-d"
    // binding could never match.
    if (ev->key() >= Qt::Key_A && ev->key() <= Qt::Key_Z) {
        return QString(QChar(ev->key())).toLower();
    }
    if (ev->key() >= Qt::Key_0 && ev->key() <= Qt::Key_9) {
        return QString(QChar(ev->key()));
    }

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

QJsonArray modifiers_to_array(Qt::KeyboardModifiers mods, const QString& key) {
    QJsonArray a;
    if (mods & Qt::ControlModifier) a.append("ctrl");
    // For single printable characters (letters, digits, punctuation), the
    // character itself already encodes Shift — "G" vs "g", "?" vs "/", etc.
    // Reporting Shift again would force users to bind "S-G" instead of "G",
    // which doesn't match Emacs/Vim convention. We only emit "shift" when
    // it's meaningful: combined with a named key like Tab, arrow, etc.
    const bool case_encodes_shift =
        (key.size() == 1 && key.at(0).isPrint() && !key.at(0).isSpace());
    if ((mods & Qt::ShiftModifier) && !case_encodes_shift) a.append("shift");
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

LimnInputFilter::LimnInputFilter(LimnBridge* bridge,
                                 LimnCommand* command,
                                 QObject* parent)
    : QObject(parent), bridge(bridge), command(command) {}

bool LimnInputFilter::eventFilter(QObject* obj, QEvent* ev) {
    if (!bridge) return false;

    // Qt delivers each key event twice through the app-level filter: once
    // when posted to the backing QWidgetWindow, once when forwarded to the
    // focused QWidget. Skip the QWindow pass so each press fires our
    // bindings exactly once.
    if (qobject_cast<QWindow*>(obj)) return false;

    switch (ev->type()) {
        case QEvent::KeyPress: {
            auto* kev = static_cast<QKeyEvent*>(ev);
            QString k = key_to_string(kev);
            QJsonArray mods = modifiers_to_array(kev->modifiers(), k);
            // Diagnostic: stderr-log every captured key. Lets us tell, from
            // the log file alone, whether Qt is delivering events to the
            // filter (vs. focus / OS swallowing them upstream).
            fprintf(stderr, "[limn-input] KeyPress key=%s mods=0x%x obj=%s\n",
                    qPrintable(k), (unsigned)kev->modifiers(),
                    obj ? obj->metaObject()->className() : "(null)");

            // Minibuffer interception (SPEC §6). When open, printable
            // chars / RET / ESC become minibuffer-input/submit/cancel
            // events instead of `key`.
            if (command && command->minibuffer_handle_key(k, mods)) {
                break;  // consumed; no normal `key` event for this press
            }

            QJsonObject e;
            e.insert("frame-id", "f1");
            e.insert("key",  k);
            e.insert("mods", mods);
            bridge->push_event("key", e);
            break;
        }
        case QEvent::MouseButtonPress: {
            auto* mev = static_cast<QMouseEvent*>(ev);
            QJsonObject e;
            e.insert("frame-id", "f1");
            e.insert("win-id",   "w1");

            // SPEC v0.5 §6 — compute real page + normalized x/y. If we
            // can't (no doc loaded, click outside any page), report
            // page = -1 + raw pixel coords as a fallback.
            int    page = -1;
            double nx = 0.0, ny = 0.0;
            if (command &&
                command->widget_to_page_norm(
                    static_cast<int>(mev->position().x()),
                    static_cast<int>(mev->position().y()),
                    &page, &nx, &ny)) {
                e.insert("page", page);
                e.insert("x",    nx);
                e.insert("y",    ny);
            } else {
                e.insert("page", -1);
                e.insert("x",    mev->position().x());
                e.insert("y",    mev->position().y());
            }
            e.insert("button", button_id(mev->button()));
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
