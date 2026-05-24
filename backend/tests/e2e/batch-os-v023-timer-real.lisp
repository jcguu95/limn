;;;; OS-tier batch v0.23 §B: real wall-clock timer
;;;;
;;;; Unit-tier uses a fake-clock for deterministic timer tests. This
;;;; batch exercises the same API against the REAL clock — making
;;;; sure the abstraction layer doesn't drop ticks under real
;;;; scheduling pressure.

(in-package :cl-user)
(require :sb-posix)

(defparameter *bdir*
  (or (handler-case (sb-posix:getenv "LIMN_BACKEND_DIR") (error () nil))
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))

(load (concatenate 'string *bdir* "limn-hooks.lisp"))
(load (concatenate 'string *bdir* "limn-log.lisp"))
(load (concatenate 'string *bdir* "limn-error.lisp"))
(load (concatenate 'string *bdir* "limn-timer.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    → ~a~%" details))
  (unless ok (push msg *failures*)))

(format t "~%=== batch-os-v023-timer-real ===~%")

;;; ── single-shot 500ms ────────────────────────────────────────────────
(limn/timer:reset-all-timers)
(let* ((fired-at nil)
       (t0 (get-internal-real-time)))
  (limn/timer:run-at-time 0.5
                          (lambda ()
                            (setf fired-at
                                  (/ (- (get-internal-real-time) t0)
                                     (coerce internal-time-units-per-second 'double-float)))))
  ;; Real-clock dispatch — poll dispatch-due until callback fires or 2s timeout.
  (loop with deadline = (+ (get-internal-real-time)
                           (* 2 internal-time-units-per-second))
        while (< (get-internal-real-time) deadline)
        until fired-at
        do (limn/timer:dispatch-due)
           (sleep 0.02))
  (check "single 500ms timer fired" fired-at)
  (when fired-at
    (format t "  fired at: ~,3F s~%" fired-at)
    (check "fire time ∈ [0.4, 1.5]"
           (and (>= fired-at 0.4) (<= fired-at 1.5)))))

;;; ── repeat 200ms × 5 ─────────────────────────────────────────────────
(limn/timer:reset-all-timers)
(let* ((fires 0)
       (t0 (get-internal-real-time)))
  (limn/timer:run-at-time 0.2 (lambda () (incf fires)) :repeat 0.2)
  (loop with deadline = (+ (get-internal-real-time)
                           (* 2 internal-time-units-per-second))
        while (< (get-internal-real-time) deadline)
        until (>= fires 5)
        do (limn/timer:dispatch-due)
           (sleep 0.02))
  (let ((dt (/ (- (get-internal-real-time) t0)
               (coerce internal-time-units-per-second 'double-float))))
    (format t "  got ~A fires in ~,3F s~%" fires dt)
    (check "repeat fired ≥ 5 times" (>= fires 5))
    (check "repeat total elapsed < 2.5s" (<= dt 2.5))))

;;; ── cancel mid-repeat ────────────────────────────────────────────────
(limn/timer:reset-all-timers)
(let* ((fires 0)
       (tm (limn/timer:run-at-time 0.1 (lambda () (incf fires)) :repeat 0.1)))
  ;; Let it fire a couple of times.
  (loop repeat 30 do
    (limn/timer:dispatch-due) (sleep 0.02))
  (let ((before-cancel fires))
    (limn/timer:cancel-timer tm)
    ;; Wait another 0.5s, should NOT fire.
    (loop repeat 25 do
      (limn/timer:dispatch-due) (sleep 0.02))
    (format t "  fires before cancel: ~A, after: ~A~%" before-cancel fires)
    (check "fires happened before cancel" (>= before-cancel 2))
    (check "cancel stopped further fires" (= fires before-cancel))))

;;; ── many timers, drift-free dispatch ─────────────────────────────────
(limn/timer:reset-all-timers)
(let ((counts (make-hash-table)))
  (loop for i from 1 to 10
        do (let ((idx i))
             (limn/timer:run-at-time (* 0.05 idx)
                                     (lambda ()
                                       (incf (gethash idx counts 0))))))
  (loop with deadline = (+ (get-internal-real-time)
                           (* 2 internal-time-units-per-second))
        while (< (get-internal-real-time) deadline)
        until (loop for i from 1 to 10
                    always (plusp (gethash i counts 0)))
        do (limn/timer:dispatch-due)
           (sleep 0.02))
  (let ((all-fired (loop for i from 1 to 10
                         always (plusp (gethash i counts 0)))))
    (check "all 10 staggered timers fired" all-fired)))

;;; ── Verdict ──────────────────────────────────────────────────────────
(limn/timer:reset-all-timers)
(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failures)~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
