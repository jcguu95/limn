#pragma once
//
// LimnInputFilter — captures Qt input events from the host widget tree
// and translates them into Limn event payloads pushed through LimnBridge.
//
// Acts as a QObject event filter installed on QApplication. Each filtered
// event becomes the SAME payload as the corresponding test/inject-* would
// produce, so phase-8 (real input) and phase-7 (test injection) converge
// on a single event vocabulary.
//
// In headless mode no input events arrive, so this filter is a no-op.
// It exists so that when --headless is OFF and a user actually interacts
// with the window, the Backend (SBCL) receives events the same way.
//
#include <QObject>
#include <QEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QWheelEvent>
#include <QResizeEvent>

class LimnBridge;
class LimnCommand;

class LimnInputFilter : public QObject {
    Q_OBJECT
public:
    // `command` is optional (nullable). When set, the filter gives it a
    // chance to intercept key events that should go through the minibuffer
    // routing rules (SPEC §6 Minibuffer events) instead of as normal `key`
    // events.
    LimnInputFilter(LimnBridge* bridge,
                     LimnCommand* command = nullptr,
                     QObject* parent = nullptr);

protected:
    bool eventFilter(QObject* obj, QEvent* ev) override;

private:
    LimnBridge*  bridge;
    LimnCommand* command;

    // Drag tracking: between MouseButtonPress and MouseButtonRelease, when
    // a MouseMove event fires we emit mouse-drag with the start (anchor)
    // position + delta. Reset on Release. v0.10 batch 1.5 γ3 / batch 2 B6.
    bool   drag_active     = false;
    int    drag_button     = 0;
    int    drag_anchor_x   = 0;       // widget coords of original press
    int    drag_anchor_y   = 0;
    int    drag_anchor_page = -1;     // pdf page at press (for events)
    double drag_anchor_nx  = 0.0;     // normalized x on anchor page
    double drag_anchor_ny  = 0.0;
};
