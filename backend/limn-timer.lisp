;;;; limn-timer — run-at-time / run-with-idle-timer.
;;;;
;;;; Pure Lisp. Thread-safe. v0.23 §B.
;;;;
;;;; Design notes:
;;;; - *now-fn* is a parameterized clock so tests can inject a fake
;;;;   monotonic clock and drive timers deterministically.
;;;; - dispatch-due pops every timer whose due-time has passed and
;;;;   invokes its callback (wrapped with limn/error:with-error-
;;;;   protection so a throw doesn't poison the chain).
;;;; - Idle timers fire when (now - *last-activity*) ≥ idle-secs.
;;;;   notify-activity is what bumps the activity stamp; tests call
;;;;   it directly, real dispatch wires it to event arrival.
;;;; - No background thread is mandatory — the dispatch model is
;;;;   "call dispatch-due from the main event loop". This keeps tests
;;;;   deterministic; a future patch can add a wakeup-thread that
;;;;   calls dispatch-due on a schedule for "real" idle use.

(defpackage #:limn/timer
  (:use #:cl)
  (:export #:run-at-time #:run-with-idle-timer
           #:cancel-timer
           #:list-timers
           #:timer-p #:timer-name
           #:*now-fn*
           #:reset-all-timers
           #:dispatch-due
           #:notify-activity))

(in-package #:limn/timer)

(defun %real-now ()
  (/ (get-internal-real-time)
     (coerce internal-time-units-per-second 'double-float)))

(defvar *now-fn* #'%real-now
  "Returns current monotonic time in seconds (double-float). Override
   for deterministic tests via let-bind.")

(defvar *last-activity* 0.0d0)

(defstruct timer
  name
  due-time           ; absolute time-seconds at which to fire
  callback
  repeat             ; nil for one-shot; positive seconds for repeat
  idle               ; nil for absolute; non-nil = "idle for this long"
  (cancelled nil)
  (insertion 0))     ; stable tie-breaker for same due-time

(defvar *timers* '())
(defvar *insertion-counter* 0)
(defvar *lock* (sb-thread:make-mutex :name "limn/timer"))

(defun notify-activity ()
  (sb-thread:with-mutex (*lock*)
    (setf *last-activity* (funcall *now-fn*))))

(defun %insert-sorted (timer)
  ;; Sort by (due-time, insertion). Linear insertion is plenty for
  ;; the dozens-to-hundreds of timers we expect.
  (incf *insertion-counter*)
  (setf (timer-insertion timer) *insertion-counter*)
  (setf *timers*
        (merge 'list (list timer)
               (copy-list *timers*)
               (lambda (a b)
                 (cond ((< (timer-due-time a) (timer-due-time b)) t)
                       ((> (timer-due-time a) (timer-due-time b)) nil)
                       (t (< (timer-insertion a) (timer-insertion b))))))))

(defun run-at-time (delay-secs callback &key repeat name)
  "Schedule CALLBACK to fire after DELAY-SECS. If :REPEAT is a positive
   number, refires every that many seconds. Returns the timer."
  (when (and repeat (not (and (numberp repeat) (plusp repeat))))
    (error "run-at-time: :repeat must be a positive number, got ~S" repeat))
  (let* ((now (funcall *now-fn*))
         (tm  (make-timer :name name
                          :due-time (+ now (coerce delay-secs 'double-float))
                          :callback callback
                          :repeat (when repeat (coerce repeat 'double-float))
                          :idle nil)))
    (sb-thread:with-mutex (*lock*) (%insert-sorted tm))
    tm))

(defun run-with-idle-timer (idle-secs callback &key name)
  "Schedule CALLBACK to fire when idle for at least IDLE-SECS."
  (let* ((tm (make-timer :name name
                         :due-time 0.0d0  ; recomputed in dispatch
                         :callback callback
                         :repeat nil
                         :idle (coerce idle-secs 'double-float))))
    (sb-thread:with-mutex (*lock*) (%insert-sorted tm))
    tm))

(defun cancel-timer (tm)
  (when (timer-p tm)
    (sb-thread:with-mutex (*lock*)
      (setf (timer-cancelled tm) t)
      (setf *timers* (remove tm *timers* :test #'eq))))
  nil)

(defun list-timers ()
  (sb-thread:with-mutex (*lock*)
    (remove-if #'timer-cancelled (copy-list *timers*))))

(defun reset-all-timers ()
  (sb-thread:with-mutex (*lock*)
    (dolist (tm *timers*) (setf (timer-cancelled tm) t))
    (setf *timers* '()
          *insertion-counter* 0
          *last-activity* (funcall *now-fn*))))

;;; ─── Dispatch ────────────────────────────────────────────────────────

(defun %take-due (now)
  ;; Collect timers due now, leaving idle ones for separate handling.
  (let ((due '())
        (kept '()))
    (dolist (tm *timers*)
      (cond ((timer-cancelled tm) nil)
            ((timer-idle tm)
             (let ((quiet (- now *last-activity*)))
               (if (>= quiet (timer-idle tm))
                   (push tm due)
                   (push tm kept))))
            ((<= (timer-due-time tm) now)
             (push tm due))
            (t (push tm kept))))
    (setf *timers* (nreverse kept))
    ;; Preserve due-time ordering (we pushed; reverse to restore).
    (nreverse due)))

(defun dispatch-due ()
  "Invoke every timer whose due-time has passed. Reschedule repeat
   timers in drift-free mode (due += interval) so a repeat timer that
   missed several ticks catches up in one dispatch. Loops until no
   more due timers. Callbacks wrapped with limn/error:%call-with-
   protection so a throw doesn't break the chain.

   Idle timers are removed after firing (idle is not a repeating
   concept; the user can re-register from inside their callback)."
  (let ((total 0)
        (err (find-package '#:limn/error)))
    (loop
      (let ((batch nil)
            (now nil))
        (sb-thread:with-mutex (*lock*)
          (setf now (funcall *now-fn*))
          (setf batch (%take-due now)))
        (unless batch (return total))
        (dolist (tm batch)
          (when (and tm (not (timer-cancelled tm)))
            (if err
                (funcall (find-symbol "%CALL-WITH-PROTECTION" err)
                         (timer-callback tm))
                (handler-case (funcall (timer-callback tm))
                  (error () nil)))
            (when (timer-repeat tm)
              (sb-thread:with-mutex (*lock*)
                (setf (timer-due-time tm)
                      (+ (timer-due-time tm) (timer-repeat tm)))
                (%insert-sorted tm)))
            (incf total)))))))

;;; Helper indirection: limn/error currently exposes a macro
;;; (with-error-protection), not a function. Provide a callable
;;; shim there. We inline a fallback here for the case where the
;;; module isn't loaded yet (during early boot or pure-unit tests
;;; that load timer before error).
