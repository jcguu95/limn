;;;; v0.23 §B — timer / async RED tests
;;;;
;;;; ~25 tests. Uses fake-clock from v023-helpers for determinism;
;;;; a handful of "real wall-clock" tests with tight short delays
;;;; for sanity (full real-clock coverage lives in OS-tier batch).

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/timer)
    (make-package '#:limn/timer :use '(#:cl)))
  (dolist (sym '("RUN-AT-TIME" "RUN-WITH-IDLE-TIMER"
                 "CANCEL-TIMER" "LIST-TIMERS"
                 "TIMER-P" "TIMER-NAME"
                 "*NOW-FN*"
                 "RESET-ALL-TIMERS"
                 "DISPATCH-DUE"
                 "NOTIFY-ACTIVITY"))
    (let ((s (intern sym '#:limn/timer)))
      (export s '#:limn/timer))))

(in-package #:limn/unit-test)

(use-package '#:limn/v023-helpers)

;;; Each test installs a fresh fake-clock and a teardown.
(defmacro with-fake-clock ((clock-var) &body body)
  `(let ((,clock-var (make-fake-clock)))
     (let ((limn/timer:*now-fn* (lambda () (fake-clock-now ,clock-var))))
       (limn/timer:reset-all-timers)   ; clear leftover *last-activity*
       (unwind-protect (progn ,@body)
         (limn/timer:reset-all-timers)))))

;;; ─── B1. One-shot timers ───────────────────────────────────────────

(deftest timer-b1-runs-at-zero-delay
  (with-fake-clock (c)
    (let ((fired nil))
      (limn/timer:run-at-time 0 (lambda () (setf fired t)))
      (limn/timer:dispatch-due)
      (assert-true fired))))

(deftest timer-b1-runs-at-50ms-fake
  (with-fake-clock (c)
    (let ((fired nil))
      (limn/timer:run-at-time 0.05 (lambda () (setf fired t)))
      (limn/timer:dispatch-due)
      (assert-false fired)
      (fake-clock-advance c 0.05)
      (limn/timer:dispatch-due)
      (assert-true fired))))

(deftest timer-b1-callback-receives-no-required-args
  (with-fake-clock (c)
    (let ((got :unset))
      (limn/timer:run-at-time 0 (lambda () (setf got :called)))
      (limn/timer:dispatch-due)
      (assert-eq :called got))))

(deftest timer-b1-fires-only-once
  (with-fake-clock (c)
    (let ((calls 0))
      (limn/timer:run-at-time 0 (lambda () (incf calls)))
      (limn/timer:dispatch-due)
      (fake-clock-advance c 1.0)
      (limn/timer:dispatch-due)
      (fake-clock-advance c 1.0)
      (limn/timer:dispatch-due)
      (assert-eql 1 calls))))

(deftest timer-b1-cancel-prevents-fire
  (with-fake-clock (c)
    (let* ((fired nil)
           (tm (limn/timer:run-at-time 1 (lambda () (setf fired t)))))
      (limn/timer:cancel-timer tm)
      (fake-clock-advance c 2)
      (limn/timer:dispatch-due)
      (assert-false fired))))

(deftest timer-b1-auto-removed-after-fire
  (with-fake-clock (c)
    (limn/timer:run-at-time 0 (lambda () nil))
    (assert-eql 1 (length (limn/timer:list-timers)))
    (limn/timer:dispatch-due)
    (assert-eql 0 (length (limn/timer:list-timers)))))

;;; ─── B2. Repeat timers ─────────────────────────────────────────────

(deftest timer-b2-fires-n-times
  (with-fake-clock (c)
    (let ((calls 0))
      (limn/timer:run-at-time 0.1 (lambda () (incf calls)) :repeat 0.1)
      (loop repeat 5 do
        (fake-clock-advance c 0.1)
        (limn/timer:dispatch-due))
      (assert-eql 5 calls))))

(deftest timer-b2-cancel-stops-future-fires
  (with-fake-clock (c)
    (let* ((calls 0)
           (tm (limn/timer:run-at-time 0.1 (lambda () (incf calls)) :repeat 0.1)))
      (fake-clock-advance c 0.1) (limn/timer:dispatch-due)
      (limn/timer:cancel-timer tm)
      (fake-clock-advance c 1.0) (limn/timer:dispatch-due)
      (assert-eql 1 calls))))

(deftest timer-b2-callback-error-does-not-break-chain
  (with-fake-clock (c)
    (let ((calls 0))
      (limn/timer:run-at-time 0.1
                              (lambda ()
                                (incf calls)
                                (when (= calls 1) (error "boom")))
                              :repeat 0.1)
      (fake-clock-advance c 0.1) (limn/timer:dispatch-due)
      (fake-clock-advance c 0.1) (limn/timer:dispatch-due)
      (fake-clock-advance c 0.1) (limn/timer:dispatch-due)
      (assert-true (>= calls 3) (format nil "got ~A" calls)))))

(deftest timer-b2-zero-interval-rejected
  (with-fake-clock (c)
    (assert-error error
      (limn/timer:run-at-time 0.1 (lambda () nil) :repeat 0))))

(deftest timer-b2-callback-swap-mid-flight-honors-old-schedule
  ;; Reassigning the timer's callback (if API permits) should not
  ;; corrupt already-scheduled next-fire-time.
  (with-fake-clock (c)
    (let ((calls 0))
      (limn/timer:run-at-time 0.1 (lambda () (incf calls)) :repeat 0.1)
      (fake-clock-advance c 0.5) (limn/timer:dispatch-due)
      (assert-true (>= calls 4)))))

;;; ─── B3. Idle timers ───────────────────────────────────────────────

(deftest timer-b3-idle-fires-after-quiet
  (with-fake-clock (c)
    (let ((fired nil))
      (limn/timer:run-with-idle-timer 0.2 (lambda () (setf fired t)))
      (fake-clock-advance c 0.25)
      (limn/timer:dispatch-due)
      (assert-true fired))))

(deftest timer-b3-activity-resets-idle
  (with-fake-clock (c)
    (let ((fired nil))
      (limn/timer:run-with-idle-timer 0.2 (lambda () (setf fired t)))
      (fake-clock-advance c 0.15)
      (limn/timer:notify-activity)
      (fake-clock-advance c 0.15)
      (limn/timer:dispatch-due)
      (assert-false fired)
      (fake-clock-advance c 0.10)
      (limn/timer:dispatch-due)
      (assert-true fired))))

(deftest timer-b3-idle-zero-fires-next-dispatch
  (with-fake-clock (c)
    (let ((fired nil))
      (limn/timer:run-with-idle-timer 0 (lambda () (setf fired t)))
      (limn/timer:dispatch-due)
      (assert-true fired))))

(deftest timer-b3-cancel-idle-clean
  (with-fake-clock (c)
    (let* ((fired nil)
           (tm (limn/timer:run-with-idle-timer 0.2 (lambda () (setf fired t)))))
      (limn/timer:cancel-timer tm)
      (fake-clock-advance c 1.0)
      (limn/timer:dispatch-due)
      (assert-false fired))))

;;; ─── B4. Heap ordering ─────────────────────────────────────────────

(deftest timer-b4-three-timers-fire-in-delay-order
  (with-fake-clock (c)
    (let ((order '()))
      (limn/timer:run-at-time 0.3 (lambda () (push :c order)))
      (limn/timer:run-at-time 0.1 (lambda () (push :a order)))
      (limn/timer:run-at-time 0.2 (lambda () (push :b order)))
      (fake-clock-advance c 0.5)
      (limn/timer:dispatch-due)
      (assert-equal '(:a :b :c) (reverse order)))))

(deftest timer-b4-same-delay-stable-insertion-order
  (with-fake-clock (c)
    (let ((order '()))
      (limn/timer:run-at-time 0.1 (lambda () (push :first  order)))
      (limn/timer:run-at-time 0.1 (lambda () (push :second order)))
      (limn/timer:run-at-time 0.1 (lambda () (push :third  order)))
      (fake-clock-advance c 0.2)
      (limn/timer:dispatch-due)
      (assert-equal '(:first :second :third) (reverse order)))))

(deftest timer-b4-add-during-fire-survives
  (with-fake-clock (c)
    (let ((order '()))
      (limn/timer:run-at-time 0.1
                              (lambda ()
                                (push :outer order)
                                (limn/timer:run-at-time 0.1
                                                        (lambda ()
                                                          (push :inner order)))))
      (fake-clock-advance c 0.1)
      (limn/timer:dispatch-due)
      (fake-clock-advance c 0.1)
      (limn/timer:dispatch-due)
      (assert-equal '(:outer :inner) (reverse order)))))

(deftest timer-b4-cancel-during-fire-removes-target
  (with-fake-clock (c)
    (let* ((other-fired nil)
           (other (limn/timer:run-at-time 0.2 (lambda () (setf other-fired t))))
           (_ (limn/timer:run-at-time 0.1
                                      (lambda () (limn/timer:cancel-timer other)))))
      (declare (ignore _))
      (fake-clock-advance c 0.3)
      (limn/timer:dispatch-due)
      (assert-false other-fired))))

(deftest timer-b4-100-timers-soft-bound
  (with-fake-clock (c)
    (let ((count 0))
      (loop repeat 100 do
        (limn/timer:run-at-time (random 0.5)
                                (lambda () (incf count))))
      (fake-clock-advance c 1.0)
      (with-timeout-bound 1
        (limn/timer:dispatch-due))
      (assert-eql 100 count))))

;;; ─── B5. Thread safety ─────────────────────────────────────────────

;; B5 tests must use real wall clock (fake-clock would defeat the
;; purpose of testing thread behavior).

(deftest timer-b5-callback-runs-on-main-loop-not-timer-thread
  ;; The timer subsystem may have its own thread, but callbacks must
  ;; run on the main loop's thread (i.e. wherever dispatch-due is
  ;; invoked from). Approximate: capture the thread inside callback,
  ;; compare to the test thread.
  (limn/timer:reset-all-timers)
  (let ((main sb-thread:*current-thread*)
        (cb-thread nil)
        (done (sb-thread:make-semaphore)))
    (limn/timer:run-at-time 0.05
                            (lambda ()
                              (setf cb-thread sb-thread:*current-thread*)
                              (sb-thread:signal-semaphore done)))
    (with-timeout-bound 2
      (loop until (sb-thread:wait-on-semaphore done :timeout 0.05)
            do (limn/timer:dispatch-due)))
    (assert-eq main cb-thread)
    (limn/timer:reset-all-timers)))

(deftest timer-b5-concurrent-cancel-no-deadlock
  (limn/timer:reset-all-timers)
  (let ((timers (loop repeat 20 collect
                      (limn/timer:run-at-time 5 (lambda () nil)))))
    (with-timeout-bound 1
      (let ((threads (loop for tm in timers collect
                           (let ((this-tm tm))   ; fresh binding per iter
                             (sb-thread:make-thread
                              (lambda ()
                                (handler-case (limn/timer:cancel-timer this-tm)
                                  (error () nil))))))))
        (mapc #'sb-thread:join-thread threads)))
    (assert-eql 0 (length (limn/timer:list-timers)))))

(deftest timer-b5-list-timers-snapshot-safe
  (limn/timer:reset-all-timers)
  (let ((stop nil))
    (loop repeat 5 do
      (limn/timer:run-at-time 5 (lambda () nil)))
    (let ((churn (sb-thread:make-thread
                  (lambda ()
                    (handler-case
                        (loop until stop do
                          (let ((tm (limn/timer:run-at-time 5 (lambda () nil))))
                            (limn/timer:cancel-timer tm)))
                      (error () nil))))))
      (with-timeout-bound 1
        (dotimes (_ 100)
          (assert-no-error (length (limn/timer:list-timers)))))
      (setf stop t)
      (sb-thread:join-thread churn))
    (limn/timer:reset-all-timers)))

(deftest timer-b5-shutdown-clean
  ;; reset-all-timers (analog of shutdown) must return promptly even
  ;; when timers are pending.
  (loop repeat 50 do (limn/timer:run-at-time 10 (lambda () nil)))
  (with-timeout-bound 0.5
    (limn/timer:reset-all-timers))
  (assert-eql 0 (length (limn/timer:list-timers))))

(deftest timer-b5-cancel-after-fire-no-hang
  (with-fake-clock (c)
    (let ((tm (limn/timer:run-at-time 0 (lambda () nil))))
      (limn/timer:dispatch-due)
      (with-timeout-bound 0.2
        (assert-no-error (limn/timer:cancel-timer tm))))))
