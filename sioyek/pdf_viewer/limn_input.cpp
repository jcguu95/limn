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
    //
    // For letters: if Shift is held, return uppercase so it round-trips
    // through case_encodes_shift logic in modifiers_to_array. Without
    // this, C-M-S-x would silently drop the shift (key="x" + mods strips
    // shift via case_encodes_shift → S- disappears). v0.10 A12 caught it.
    if (ev->key() >= Qt::Key_A && ev->key() <= Qt::Key_Z) {
        QChar c(ev->key());     // Qt::Key_A..Z is 0x41..0x5A = 'A'..'Z'
        if (ev->modifiers() & Qt::ShiftModifier) {
            return QString(c);                  // already uppercase
        }
        return QString(c).toLower();
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
        case Qt::Key_Insert:    return "<insert>";
        // Function keys F1–F12 — v0.10 batch 3 H2/E2 caught they were
        // falling through to the "<key-N>" default and thus could not
        // be bound by name (limn:bind "F12" 'cmd). Now named.
        case Qt::Key_F1:        return "<f1>";
        case Qt::Key_F2:        return "<f2>";
        case Qt::Key_F3:        return "<f3>";
        case Qt::Key_F4:        return "<f4>";
        case Qt::Key_F5:        return "<f5>";
        case Qt::Key_F6:        return "<f6>";
        case Qt::Key_F7:        return "<f7>";
        case Qt::Key_F8:        return "<f8>";
        case Qt::Key_F9:        return "<f9>";
        case Qt::Key_F10:       return "<f10>";
        case Qt::Key_F11:       return "<f11>";
        case Qt::Key_F12:       return "<f12>";
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
    // X11/sioyek convention extends button numbering past 1/2/3:
    //   1 left, 2 middle, 3 right, 4/5 scroll up/down (Wheel event,
    //   not MouseButton), 6/7 scroll left/right, 8 back, 9 forward.
    // Previously returned 0 for anything outside 1/2/3 — that lost
    // info AND collided with "no button" semantic. v0.10 batch 1.6
    // λ1 caught it.
    if (b == Qt::LeftButton)    return 1;
    if (b == Qt::MiddleButton)  return 2;
    if (b == Qt::RightButton)   return 3;
    if (b == Qt::BackButton)    return 8;
    if (b == Qt::ForwardButton) return 9;
    // unknown button: -1 signals "saw a click but don't know which button"
    return -1;
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
    //
    // 但 Resize event 只走 QWindow path（Xvfb + openbox 上 QWidget 不收
    // 二次分發）。所以這個 filter 對 Resize 特例放行。
    if (qobject_cast<QWindow*>(obj) && ev->type() != QEvent::Resize) {
        return false;
    }

    switch (ev->type()) {
        case QEvent::KeyPress: {
            auto* kev = static_cast<QKeyEvent*>(ev);

            // Skip bare modifier presses. When the user types C-x C-f,
            // X11 / Qt deliver THREE KeyPress events: bare Ctrl, then
            // Ctrl+x, then bare Ctrl (release-press cycle?), then
            // Ctrl+f. The bare Ctrl events have no character payload —
            // they're just modifier-being-held notifications. If we
            // forward them as 'key' events, the backend's prefix-key
            // accumulator (limn::*key-prefix*) sees an unbound spec
            // like "C-<key-16777249>" and resets, killing any in-flight
            // multi-key sequence. OS-level e2e test batch-os-prefix
            // (v0.10 A6) caught this.
            int qk = kev->key();
            if (qk == Qt::Key_Control || qk == Qt::Key_Alt    ||
                qk == Qt::Key_Shift   || qk == Qt::Key_Meta   ||
                qk == Qt::Key_AltGr   || qk == Qt::Key_Super_L ||
                qk == Qt::Key_Super_R) {
                break;
            }

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
        case QEvent::MouseButtonDblClick:
            // Qt 把「短時間內第二次按鍵」合併成 MouseButtonDblClick、
            // 不再 fire MouseButtonPress。為了讓 xdotool click --repeat
            // 2 (或人類雙擊) 在 backend 看起來就是兩個 mouse-click event、
            // 把 DblClick 直接 fall-through 到 Press 的處理。v0.10
            // batch 2 B2 caught it.
            [[fallthrough]];
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
            // SPEC §6: mouse-click carries modifier state so users can
            // bind C-mouse-1 / S-mouse-1 / etc. Previously missing —
            // v0.10 batch 1.5 γ1 caught it.
            e.insert("mods", modifiers_to_array(mev->modifiers(), QString()));
            bridge->push_event("mouse-click", e);

            // Begin drag tracking: remember anchor for subsequent
            // MouseMove events. Reset on MouseButtonRelease.
            drag_active      = true;
            drag_button      = button_id(mev->button());
            drag_anchor_x    = static_cast<int>(mev->position().x());
            drag_anchor_y    = static_cast<int>(mev->position().y());
            drag_anchor_page = -1;
            drag_anchor_nx   = 0.0;
            drag_anchor_ny   = 0.0;
            if (command &&
                command->widget_to_page_norm(drag_anchor_x, drag_anchor_y,
                                              &drag_anchor_page,
                                              &drag_anchor_nx,
                                              &drag_anchor_ny)) {
                // ok — anchor coords on a page
            } else {
                drag_anchor_page = -1;
            }
            break;
        }
        case QEvent::MouseMove: {
            if (!drag_active) break;
            auto* mev = static_cast<QMouseEvent*>(ev);
            // Compute current page-relative coords for delta. If
            // current cursor is off any page, use widget pixel delta.
            int    cur_page = -1;
            double cur_nx = 0.0, cur_ny = 0.0;
            bool ok = (command &&
                       command->widget_to_page_norm(
                           static_cast<int>(mev->position().x()),
                           static_cast<int>(mev->position().y()),
                           &cur_page, &cur_nx, &cur_ny));
            QJsonObject e;
            e.insert("frame-id", "f1");
            e.insert("win-id",   "w1");
            if (ok && cur_page == drag_anchor_page && drag_anchor_page >= 0) {
                // both anchor and current on same page → page-norm delta
                e.insert("page", drag_anchor_page);
                e.insert("x",    drag_anchor_nx);
                e.insert("y",    drag_anchor_ny);
                e.insert("dx",   cur_nx - drag_anchor_nx);
                e.insert("dy",   cur_ny - drag_anchor_ny);
            } else {
                // fallback: pixel coords + pixel delta
                e.insert("page", drag_anchor_page);
                e.insert("x",    drag_anchor_x);
                e.insert("y",    drag_anchor_y);
                e.insert("dx",   static_cast<int>(mev->position().x()) - drag_anchor_x);
                e.insert("dy",   static_cast<int>(mev->position().y()) - drag_anchor_y);
            }
            e.insert("button", drag_button);
            e.insert("mods",   modifiers_to_array(mev->modifiers(), QString()));
            bridge->push_event("mouse-drag", e);
            break;
        }
        case QEvent::MouseButtonRelease: {
            drag_active = false;
            break;
        }
        case QEvent::Wheel: {
            auto* wev = static_cast<QWheelEvent*>(ev);
            QJsonObject e;
            e.insert("frame-id", "f1");
            e.insert("win-id",   "w1");
            e.insert("dx",       wev->angleDelta().x());
            e.insert("dy",       wev->angleDelta().y());
            // SPEC §6: scroll carries modifier state (Ctrl-scroll = zoom
            // convention etc). v0.10 batch 1.5 γ4 caught the omission.
            e.insert("mods", modifiers_to_array(wev->modifiers(), QString()));
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
