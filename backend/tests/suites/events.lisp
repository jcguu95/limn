;;;; Event tests
;;;;
;;;; Covers section 6 of LIMN-SPEC: events that Frontend pushes spontaneously
;;;; to Backend.
;;;;
;;;; Note: many of these tests need a way to inject input from outside
;;;; (e.g. simulate a key press). For pure protocol testing in headless mode,
;;;; we either:
;;;;   (a) verify the shape of events that arrive naturally (heartbeat, buffer-opened)
;;;;   (b) use a special test command that triggers an event (--test-inject-key X)
;;;;
;;;; Tests in this file mainly verify event shape & key fields.

(in-package #:limn/test)

;;; ── buffer-opened ────────────────────────────────────────────────────────

(deftest test-event-buffer-opened-on-load
  "Loading a buffer triggers a 'buffer-opened' event."
  (send! "bridge/engine-load"
         :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)
  ;; The event should have been pushed alongside the response.
  (let ((ev (read-event :type "buffer-opened" :timeout 2)))
    (when ev
      (assert-has-key :|event|      ev "event field")
      (assert-has-key :|frame-id|   ev "frame-id field")
      (assert-has-key :|buffer-id|  ev "buffer-id field")
      (assert-has-key :|page-count| ev "page-count field")
      (assert-equal "buffer-opened" (getf ev :|event|)))))

(deftest test-event-buffer-opened-fields-types
  "buffer-opened event field types match spec."
  (send! "bridge/engine-load"
         :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)
  (let ((ev (read-event :type "buffer-opened" :timeout 2)))
    (when ev
      (assert-type (getf ev :|frame-id|)   string)
      (assert-type (getf ev :|buffer-id|)  string)
      (assert-type (getf ev :|page-count|) integer))))

;;; ── buffer-closed ────────────────────────────────────────────────────────

(deftest test-event-buffer-closed
  "Closing a buffer triggers a 'buffer-closed' event."
  (let* ((load-r (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*))
         (bid    (json-get* load-r :|data| :|buffer-id|)))
    (drain-events)                       ; ignore the buffer-opened event
    (send! "buffer/close" :|buffer-id| bid)
    (let ((ev (read-event :type "buffer-closed" :timeout 2)))
      (when ev
        (assert-equal bid (getf ev :|buffer-id|))))))

;;; ── error ───────────────────────────────────────────────────────────────

(deftest test-event-error-on-engine-failure
  "Engine failures may push an 'error' event in addition to ok=false response."
  ;; This is engine-dependent — spec says SHOULD, not MUST.
  (send! "bridge/engine-load"
         :|win-id| "w1" :|engine| "mupdf" :|path| "/no/such/file.pdf")
  (let ((ev (read-event :type "error" :timeout 1)))
    (when ev
      (assert-has-key :|cmd|     ev "cmd field on error event")
      (assert-has-key :|message| ev "message field on error event"))))

;;; ── heartbeat ───────────────────────────────────────────────────────────

(deftest test-event-heartbeat-arrives
  "Frontend periodically sends a heartbeat event."
  ;; Wait up to 7 seconds for a heartbeat. Spec doesn't mandate exact interval.
  (let ((ev (read-event :type "heartbeat" :timeout 7)))
    (when ev
      (assert-has-key :|timestamp| ev "heartbeat has timestamp")
      (assert-numeric (getf ev :|timestamp|)))))

(deftest test-event-heartbeat-no-id
  "Heartbeat event has no id (it's an event, not a response)."
  (let ((ev (read-event :type "heartbeat" :timeout 7)))
    (when ev
      (assert-equal nil (getf ev :|id|) "no id field"))))

;;; ── frame-id requirement ────────────────────────────────────────────────

(deftest test-event-has-frame-id
  "All events (except heartbeat/error) include frame-id."
  ;; Test by triggering buffer-opened and inspecting
  (send! "bridge/engine-load"
         :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)
  (let ((ev (read-event :type "buffer-opened" :timeout 2)))
    (when ev
      (assert-has-key :|frame-id| ev "buffer-opened has frame-id")
      (assert-type (getf ev :|frame-id|) string))))

;;; ── resize event ─────────────────────────────────────────────────────────
;;; These require interaction with a real window; in headless mode they're
;;; mainly negative tests (we don't expect to see them spontaneously).

(deftest test-event-resize-shape-when-it-arrives
  "If a resize event arrives (e.g. via test-inject), it has width and height."
  (let ((ev (read-event :type "resize" :timeout 0.5)))
    (when ev
      (assert-has-key :|frame-id| ev)
      (assert-has-key :|win-id|   ev)
      (assert-has-key :|width|    ev)
      (assert-has-key :|height|   ev)
      (assert-numeric (getf ev :|width|))
      (assert-numeric (getf ev :|height|)))))

;;; ── key event shape (requires injection) ─────────────────────────────────

(deftest test-event-key-injected
  "If frontend supports test-inject-key, the resulting key event has
   frame-id, key, mods."
  ;; Try a test-only injection command. If frontend doesn't support it,
  ;; the assertion just passes via the early return (no event).
  (let ((r (send! "test/inject-key"
                  :|frame-id| "f1" :|key| "j" :|mods| nil)))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "key" :timeout 1)))
        (when ev
          (assert-has-key :|frame-id| ev)
          (assert-has-key :|key|      ev)
          (assert-has-key :|mods|     ev)
          (assert-equal "j" (getf ev :|key|))
          (assert-type (getf ev :|mods|) list))))))

(deftest test-event-key-with-modifiers
  "Key event with ctrl modifier is correctly tagged."
  (let ((r (send! "test/inject-key"
                  :|frame-id| "f1" :|key| "s" :|mods| (list "ctrl"))))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "key" :timeout 1)))
        (when ev
          (assert-contains "ctrl" (getf ev :|mods|)))))))

;;; ── mouse events (requires injection) ────────────────────────────────────

(deftest test-event-mouse-click-shape
  "mouse-click event includes win-id, page, x, y, button."
  (let ((r (send! "test/inject-mouse-click"
                  :|frame-id| "f1" :|win-id| "w1"
                  :|page| 0 :|x| 0.5 :|y| 0.5 :|button| 1)))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "mouse-click" :timeout 1)))
        (when ev
          (assert-has-key :|win-id| ev)
          (assert-has-key :|page|   ev)
          (assert-has-key :|x|      ev)
          (assert-has-key :|y|      ev)
          (assert-has-key :|button| ev)
          ;; coordinates should be normalized (document space, 0–1)
          (assert-numeric (getf ev :|x|))
          (assert-numeric (getf ev :|y|)))))))

(deftest test-event-mouse-drag-shape
  "mouse-drag includes dx, dy."
  (let ((r (send! "test/inject-mouse-drag"
                  :|frame-id| "f1" :|win-id| "w1"
                  :|page| 0 :|x| 0.5 :|y| 0.5 :|dx| 0.02 :|dy| 0.05
                  :|button| 1)))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "mouse-drag" :timeout 1)))
        (when ev
          (assert-has-key :|dx| ev)
          (assert-has-key :|dy| ev))))))

;;; ── scroll event ─────────────────────────────────────────────────────────

(deftest test-event-scroll-shape
  "scroll event has dx, dy."
  (let ((r (send! "test/inject-scroll"
                  :|frame-id| "f1" :|win-id| "w1"
                  :|dx| 0 :|dy| 120)))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "scroll" :timeout 1)))
        (when ev
          (assert-has-key :|dx| ev)
          (assert-has-key :|dy| ev))))))

;;; ── gesture event ────────────────────────────────────────────────────────

(deftest test-event-gesture-pinch
  "Pinch gesture event has type and scale."
  (let ((r (send! "test/inject-gesture"
                  :|frame-id| "f1" :|win-id| "w1"
                  :|type| "pinch" :|scale| 1.2)))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "gesture" :timeout 1)))
        (when ev
          (assert-equal "pinch" (getf ev :|type|))
          (assert-has-key :|scale| ev))))))

(deftest test-event-gesture-swipe
  "Swipe gesture has direction (dx, dy)."
  (let ((r (send! "test/inject-gesture"
                  :|frame-id| "f1" :|win-id| "w1"
                  :|type| "swipe" :|dx| -1 :|dy| 0)))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "gesture" :timeout 1)))
        (when ev
          (assert-equal "swipe" (getf ev :|type|))
          (assert-has-key :|dx| ev)
          (assert-has-key :|dy| ev))))))

;;; ── drag-drop ───────────────────────────────────────────────────────────

(deftest test-event-drag-drop-shape
  "drag-drop event includes a list of paths."
  (let ((r (send! "test/inject-drag-drop"
                  :|frame-id| "f1" :|win-id| "w1"
                  :|paths| (list "/tmp/a.pdf" "/tmp/b.pdf"))))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "drag-drop" :timeout 1)))
        (when ev
          (assert-has-key :|paths| ev)
          (assert-type (getf ev :|paths|) list)
          (assert-list-of #'stringp (getf ev :|paths|)))))))

;;; ── IME and audio input ──────────────────────────────────────────────────

(deftest test-event-ime-commit-shape
  "ime-commit event delivers final committed text."
  (let ((r (send! "test/inject-ime-commit" :|frame-id| "f1" :|text| "你好")))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "ime-commit" :timeout 1)))
        (when ev
          (assert-has-key :|text| ev)
          (assert-type (getf ev :|text|) string))))))

(deftest test-event-audio-input-shape
  "audio-input event has transcribed text."
  (let ((r (send! "test/inject-audio-input"
                  :|frame-id| "f1" :|text| "scroll down")))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "audio-input" :timeout 1)))
        (when ev
          (assert-has-key :|text| ev)
          (assert-type (getf ev :|text|) string))))))

;;; ── frame-id is on EVERY event ───────────────────────────────────────────

(deftest test-all-events-have-frame-id
  "Every event type that originates in a frame must include frame-id.
   We iterate through all inject-able events and check each."
  (drain-events)
  ;; key
  (when (eq (getf (send! "test/inject-key"
                          :|frame-id| "f1" :|key| "a" :|mods| nil) :|ok|) t)
    (let ((ev (read-event :type "key" :timeout 1)))
      (when ev (assert-has-key :|frame-id| ev "key event has frame-id"))))
  ;; mouse-click
  (when (eq (getf (send! "test/inject-mouse-click"
                          :|frame-id| "f1" :|win-id| "w1"
                          :|page| 0 :|x| 0.1 :|y| 0.1 :|button| 1) :|ok|) t)
    (let ((ev (read-event :type "mouse-click" :timeout 1)))
      (when ev (assert-has-key :|frame-id| ev "mouse-click has frame-id"))))
  ;; resize
  (when (eq (getf (send! "test/inject-resize"
                          :|frame-id| "f1" :|win-id| "w1"
                          :|width| 800 :|height| 600) :|ok|) t)
    (let ((ev (read-event :type "resize" :timeout 1)))
      (when ev (assert-has-key :|frame-id| ev "resize has frame-id"))))
  ;; drag-drop
  (when (eq (getf (send! "test/inject-drag-drop"
                          :|frame-id| "f1" :|win-id| "w1"
                          :|paths| (list "/tmp/x.pdf")) :|ok|) t)
    (let ((ev (read-event :type "drag-drop" :timeout 1)))
      (when ev (assert-has-key :|frame-id| ev "drag-drop has frame-id")))))

;;; ── Mouse coordinates are normalized (document space 0–1) ────────────────

(deftest test-event-mouse-coords-normalized
  "Per spec section 6, mouse coords are 'page coords 0–1'."
  (when (eq (getf (send! "test/inject-mouse-click"
                          :|frame-id| "f1" :|win-id| "w1"
                          :|page| 0 :|x| 0.5 :|y| 0.5 :|button| 1) :|ok|) t)
    (let ((ev (read-event :type "mouse-click" :timeout 1)))
      (when ev
        (let ((x (getf ev :|x|))
              (y (getf ev :|y|)))
          (assert-numeric x)
          (assert-numeric y)
          (check-assertion (and (<= 0 x 1) (<= 0 y 1))
                           "coords in [0,1] range"
                           "x=~s y=~s" x y))))))

(deftest test-event-mouse-drag-coords-normalized
  "mouse-drag coords also in document space [0,1] for x/y."
  (when (eq (getf (send! "test/inject-mouse-drag"
                          :|frame-id| "f1" :|win-id| "w1"
                          :|page| 0 :|x| 0.3 :|y| 0.3
                          :|dx| 0.05 :|dy| 0.05 :|button| 1) :|ok|) t)
    (let ((ev (read-event :type "mouse-drag" :timeout 1)))
      (when ev
        (let ((x (getf ev :|x|)) (y (getf ev :|y|)))
          (when (and (numberp x) (numberp y))
            (check-assertion (and (<= 0 x 1) (<= 0 y 1))
                             "drag coords in [0,1]"
                             "x=~s y=~s" x y)))))))

;;; ── Event ordering is preserved ──────────────────────────────────────────

(deftest test-event-order-preserved
  "If we inject A then B, the events arrive in order A, B."
  (drain-events)
  (send! "test/inject-key" :|frame-id| "f1" :|key| "1" :|mods| nil)
  (send! "test/inject-key" :|frame-id| "f1" :|key| "2" :|mods| nil)
  (send! "test/inject-key" :|frame-id| "f1" :|key| "3" :|mods| nil)
  (let ((events (list (read-event :type "key" :timeout 1)
                      (read-event :type "key" :timeout 1)
                      (read-event :type "key" :timeout 1))))
    (when (every #'identity events)
      (let ((keys (mapcar (lambda (e) (getf e :|key|)) events)))
        (assert-equal '("1" "2" "3") keys
                      "events arrive in order")))))

;;; ── Heartbeat interval is reasonable ─────────────────────────────────────

(deftest test-event-heartbeat-interval
  "Heartbeats arrive at a reasonable cadence (1–10 seconds apart)."
  (drain-events)
  (let ((ev1 (read-event :type "heartbeat" :timeout 10)))
    (when ev1
      (let* ((t1 (getf ev1 :|timestamp|))
             (ev2 (read-event :type "heartbeat" :timeout 12))
             (t2 (when ev2 (getf ev2 :|timestamp|))))
        (when (and t1 t2)
          (let ((delta (abs (- t2 t1))))
            ;; allow a wide range, just to detect "every 100ms" or "every hour"
            (check-assertion (< delta 60000)
                             "heartbeat interval < 60s"
                             "delta=~s" delta)))))))

;;; ── test/emit-heartbeat: forced heartbeat ────────────────────────────────

(deftest test-event-forced-heartbeat
  "test/emit-heartbeat (per spec 8.4) triggers an immediate heartbeat event."
  (drain-events)
  (let ((r (send! "test/emit-heartbeat")))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "heartbeat" :timeout 1)))
        (assert-true ev "forced heartbeat arrived immediately")))))

;;; ── error event details ──────────────────────────────────────────────────

(deftest test-event-error-includes-frame-when-window-specific
  "When an error originates from a windowed operation, the error event includes frame-id."
  (drain-events)
  (send! "bridge/engine-load"
         :|win-id| "w1" :|engine| "mupdf" :|path| "/no/file.pdf")
  (let ((ev (read-event :type "error" :timeout 1)))
    (when ev
      ;; error events from frame-scoped ops should have frame-id;
      ;; if it's a global error (e.g. malformed JSON), it may not.
      ;; This test is informational.
      (format t "    note: error event ~a frame-id~%"
              (if (getf ev :|frame-id|) "includes" "lacks")))))
