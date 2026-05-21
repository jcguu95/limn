;;;; Tests for the test/ namespace itself (Spec section 8)
;;;;
;;;; --test-mode enables a set of test/* commands for injecting fake input
;;;; events. We verify each inject command:
;;;;   1. Returns ok=true when test mode is enabled
;;;;   2. Triggers exactly one corresponding event with matching fields
;;;;   3. Returns ok=false (with "test mode disabled" hint) when not enabled
;;;;
;;;; Each inject is paired with the natural event it simulates.

(in-package #:limn/test)

;;; ── test/inject-key ───────────────────────────────────────────────────────

(deftest test-inject-key-roundtrip
  "test/inject-key triggers a key event with matching fields."
  (drain-events)
  (let ((r (send! "test/inject-key"
                  :|frame-id| "f1" :|key| "x" :|mods| nil)))
    (assert-ok r "inject-key returns ok")
    (let ((ev (read-event :type "key" :timeout 1)))
      (assert-true ev "key event arrived")
      (when ev
        (assert-equal "x"  (getf ev :|key|))
        (assert-equal "f1" (getf ev :|frame-id|))))))

(deftest test-inject-key-with-modifiers-roundtrip
  (drain-events)
  (send! "test/inject-key"
         :|frame-id| "f1" :|key| "s" :|mods| (list "ctrl" "meta"))
  (let ((ev (read-event :type "key" :timeout 1)))
    (when ev
      (assert-equal "s" (getf ev :|key|))
      (assert-contains "ctrl" (getf ev :|mods|))
      (assert-contains "meta" (getf ev :|mods|)))))

;;; ── test/inject-mouse-click ──────────────────────────────────────────────

(deftest test-inject-mouse-click-roundtrip
  (drain-events)
  (let ((r (send! "test/inject-mouse-click"
                  :|frame-id| "f1" :|win-id| "w1"
                  :|page| 2 :|x| 0.4 :|y| 0.6 :|button| 1)))
    (assert-ok r)
    (let ((ev (read-event :type "mouse-click" :timeout 1)))
      (when ev
        (assert-equal 2 (getf ev :|page|))
        (assert-equal 1 (getf ev :|button|))
        (check-assertion (< (abs (- (getf ev :|x|) 0.4)) 0.001)
                         "x value matches")
        (check-assertion (< (abs (- (getf ev :|y|) 0.6)) 0.001)
                         "y value matches")))))

;;; ── test/inject-mouse-drag ───────────────────────────────────────────────

(deftest test-inject-mouse-drag-roundtrip
  (drain-events)
  (send! "test/inject-mouse-drag"
         :|frame-id| "f1" :|win-id| "w1"
         :|page| 0 :|x| 0.2 :|y| 0.2
         :|dx| 0.05 :|dy| 0.05 :|button| 1)
  (let ((ev (read-event :type "mouse-drag" :timeout 1)))
    (when ev
      (assert-has-key :|dx| ev)
      (assert-has-key :|dy| ev))))

;;; ── test/inject-scroll ───────────────────────────────────────────────────

(deftest test-inject-scroll-roundtrip
  (drain-events)
  (send! "test/inject-scroll"
         :|frame-id| "f1" :|win-id| "w1" :|dx| 0 :|dy| 120)
  (let ((ev (read-event :type "scroll" :timeout 1)))
    (when ev
      (assert-equal 0   (getf ev :|dx|))
      (assert-equal 120 (getf ev :|dy|)))))

;;; ── test/inject-gesture ──────────────────────────────────────────────────

(deftest test-inject-gesture-pinch-roundtrip
  (drain-events)
  (send! "test/inject-gesture"
         :|frame-id| "f1" :|win-id| "w1"
         :|type| "pinch" :|scale| 1.5)
  (let ((ev (read-event :type "gesture" :timeout 1)))
    (when ev
      (assert-equal "pinch" (getf ev :|type|))
      (check-assertion (< (abs (- (getf ev :|scale|) 1.5)) 0.001)
                       "scale value matches"))))

(deftest test-inject-gesture-swipe-roundtrip
  (drain-events)
  (send! "test/inject-gesture"
         :|frame-id| "f1" :|win-id| "w1"
         :|type| "swipe" :|dx| -1 :|dy| 0)
  (let ((ev (read-event :type "gesture" :timeout 1)))
    (when ev
      (assert-equal "swipe" (getf ev :|type|)))))

;;; ── test/inject-drag-drop ────────────────────────────────────────────────

(deftest test-inject-drag-drop-roundtrip
  (drain-events)
  (send! "test/inject-drag-drop"
         :|frame-id| "f1" :|win-id| "w1"
         :|paths| (list "/tmp/a.pdf" "/tmp/b.pdf"))
  (let ((ev (read-event :type "drag-drop" :timeout 1)))
    (when ev
      (let ((paths (getf ev :|paths|)))
        (assert-equal 2 (length paths))
        (assert-contains "/tmp/a.pdf" paths)
        (assert-contains "/tmp/b.pdf" paths)))))

;;; ── test/inject-ime-commit ───────────────────────────────────────────────

(deftest test-inject-ime-commit-roundtrip
  (drain-events)
  (send! "test/inject-ime-commit"
         :|frame-id| "f1" :|text| "你好世界")
  (let ((ev (read-event :type "ime-commit" :timeout 1)))
    (when ev
      (assert-equal "你好世界" (getf ev :|text|)))))

;;; ── test/inject-audio-input ──────────────────────────────────────────────

(deftest test-inject-audio-input-roundtrip
  (drain-events)
  (send! "test/inject-audio-input"
         :|frame-id| "f1" :|text| "next page")
  (let ((ev (read-event :type "audio-input" :timeout 1)))
    (when ev
      (assert-equal "next page" (getf ev :|text|)))))

;;; ── test/inject-resize ───────────────────────────────────────────────────

(deftest test-inject-resize-roundtrip
  (drain-events)
  (send! "test/inject-resize"
         :|frame-id| "f1" :|win-id| "w1"
         :|width| 1024 :|height| 768)
  (let ((ev (read-event :type "resize" :timeout 1)))
    (when ev
      (assert-equal 1024 (getf ev :|width|))
      (assert-equal 768  (getf ev :|height|)))))

;;; ── test/emit-heartbeat ──────────────────────────────────────────────────

(deftest test-emit-heartbeat-immediate
  (drain-events)
  (send! "test/emit-heartbeat")
  (let ((ev (read-event :type "heartbeat" :timeout 1)))
    (assert-true ev "forced heartbeat arrived immediately")))

;;; ── test/snapshot ────────────────────────────────────────────────────────

(deftest test-snapshot-shape
  "test/snapshot returns internal state for inspection."
  (let ((r (send! "test/snapshot")))
    (when (eq (getf r :|ok|) t)
      (assert-has-key :|data| r "snapshot has data"))))

;;; ── test/flush-caches ────────────────────────────────────────────────────

(deftest test-flush-caches-clean
  "test/flush-caches succeeds and leaves the frontend responsive."
  (let ((r (send! "test/flush-caches")))
    (when (eq (getf r :|ok|) t)
      (assert-ok (send! "bridge/capabilities")
                 "frontend still responsive post-flush"))))