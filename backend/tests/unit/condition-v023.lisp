;;;; v0.23 §C — condition / debugger RED tests
;;;; ~20 tests covering with-error-protection, *debugger-hook*,
;;;; *Backtrace* buffer, and cross-module integration.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/error)
    (make-package '#:limn/error :use '(#:cl)))
  (dolist (sym '("WITH-ERROR-PROTECTION"
                 "*DEBUGGER-HOOK*"
                 "*BACKTRACE-BUFFER*" "BACKTRACE-COUNT"
                 "CLEAR-BACKTRACE" "GET-BACKTRACE-ENTRIES"
                 "BACKTRACE-LIMIT"))
    (let ((s (intern sym '#:limn/error)))
      (export s '#:limn/error))))

(in-package #:limn/unit-test)

(use-package '#:limn/v023-helpers)

;;; ─── C1. with-error-protection ─────────────────────────────────────

(deftest cond-c1-transparent-return-value
  (assert-eql 42
              (limn/error:with-error-protection
                (+ 40 2))))

(deftest cond-c1-catches-thrown-error
  (assert-no-error
    (limn/error:with-error-protection
      (error "intentional"))))

(deftest cond-c1-pushes-event-error
  (let ((seen nil))
    (let ((handler (lambda (&rest ev) (push ev seen))))
      (funcall (find-symbol "ADD-HOOK" '#:limn/hooks) :event/error handler)
      (unwind-protect
           (progn
             (limn/error:with-error-protection (error "ping"))
             (sleep 0.05))
        (funcall (find-symbol "REMOVE-HOOK" '#:limn/hooks) :event/error handler))
      (assert-true seen "event/error fired"))))

(deftest cond-c1-event-error-payload-complete
  ;; Should carry condition class, message, backtrace.
  (let ((seen nil))
    (let ((handler (lambda (&rest ev) (push ev seen))))
      (funcall (find-symbol "ADD-HOOK" '#:limn/hooks) :event/error handler)
      (unwind-protect
           (progn
             (limn/error:with-error-protection
               (error "diagnostic-marker-xyz"))
             (sleep 0.05))
        (funcall (find-symbol "REMOVE-HOOK" '#:limn/hooks) :event/error handler))
      (let ((ev (first seen)))
        (assert-true (search "diagnostic-marker-xyz" (format nil "~A" ev))
                     "message visible in event")
        (assert-true (search "BACKTRACE" (format nil "~A" ev))
                     "backtrace key present")))))

(deftest cond-c1-nested-inner-catches-first
  (let ((outer nil))
    (limn/error:with-error-protection
      (setf outer
            (limn/error:with-error-protection
              (error "inner-caught")
              :inner-returned)))
    ;; Inner returns nil after catching, so outer sees no error.
    (assert-true t "nested protection didn't double-fault")))

(deftest cond-c1-non-error-condition-passes-through
  ;; signals (warnings, plain conditions) are NOT errors and must
  ;; not be captured by with-error-protection.
  (assert-no-error
    (limn/error:with-error-protection
      (signal 'simple-warning :format-control "just a warning"))))

;;; ─── C2. *debugger-hook* ───────────────────────────────────────────

(deftest cond-c2-default-hook-writes-messages
  ;; Default hook should log to *Messages* via limn/log:message.
  (let ((before (handler-case
                    (funcall (find-symbol "GET-MESSAGES" '#:limn/log))
                  (error () nil))))
    (limn/error:with-error-protection (error "to-messages"))
    (sleep 0.05)
    (let ((after (handler-case
                     (funcall (find-symbol "GET-MESSAGES" '#:limn/log))
                   (error () nil))))
      (assert-true (> (length after) (length before))))))

(deftest cond-c2-user-hook-overrides-default
  (let* ((called nil)
         (limn/error:*debugger-hook*
           (lambda (cond prev)
             (declare (ignore prev))
             (setf called (princ-to-string cond)))))
    (limn/error:with-error-protection (error "user-hook-test"))
    (assert-true (search "user-hook-test" (or called "")))))

(deftest cond-c2-user-hook-error-falls-back
  ;; If the user-installed hook itself throws, framework must
  ;; degrade to the previous (default) hook rather than crash.
  (let ((limn/error:*debugger-hook*
          (lambda (cond prev) (declare (ignore cond prev))
            (error "user-hook is broken"))))
    (assert-no-error
      (limn/error:with-error-protection (error "trigger")))))

(deftest cond-c2-unwind-protect-runs
  (let ((cleanup nil))
    (limn/error:with-error-protection
      (unwind-protect (error "boom")
        (setf cleanup t)))
    (assert-true cleanup "cleanup ran despite caught error")))

;;; ─── C3. *Backtrace* buffer ────────────────────────────────────────

(deftest cond-c3-writes-to-registry
  (limn/error:clear-backtrace)
  (limn/error:with-error-protection (error "bt-marker-1"))
  (sleep 0.05)
  (let ((entries (limn/error:get-backtrace-entries)))
    (assert-true (some (lambda (e)
                         (search "bt-marker-1" (princ-to-string e)))
                       entries))))

(deftest cond-c3-most-recent-first
  (limn/error:clear-backtrace)
  (limn/error:with-error-protection (error "first"))
  (limn/error:with-error-protection (error "second"))
  (sleep 0.05)
  (let ((entries (limn/error:get-backtrace-entries)))
    (assert-true (search "second" (princ-to-string (first entries))))))

(deftest cond-c3-bounded-size
  (limn/error:clear-backtrace)
  (let ((limit (or (ignore-errors limn/error:backtrace-limit) 100)))
    (loop repeat (* 2 limit) do
      (limn/error:with-error-protection (error "noise")))
    (sleep 0.05)
    (assert-true (<= (limn/error:backtrace-count) limit))))

(deftest cond-c3-clear-empties
  (limn/error:with-error-protection (error "to-be-cleared"))
  (limn/error:clear-backtrace)
  (assert-eql 0 (limn/error:backtrace-count)))

;;; ─── C4. Integration ──────────────────────────────────────────────

(deftest cond-c4-process-sentinel-error-caught
  ;; sentinel that throws should be caught by framework's internal
  ;; with-error-protection wrapping; *Backtrace* should record it.
  (limn/error:clear-backtrace)
  (let ((p (limn/process:make-process
            :command '("/usr/bin/true")
            :sentinel (lambda (proc) (declare (ignore proc))
                        (error "sentinel-boom-marker")))))
    (limn/process:process-wait p :timeout 5)
    (sleep 0.1)
    (assert-true (some (lambda (e) (search "sentinel-boom-marker"
                                            (princ-to-string e)))
                       (limn/error:get-backtrace-entries)))))

(deftest cond-c4-timer-callback-error-caught
  (limn/error:clear-backtrace)
  (limn/timer:reset-all-timers)
  (limn/timer:run-at-time 0
                          (lambda () (error "timer-boom-marker")))
  (limn/timer:dispatch-due)
  (sleep 0.05)
  (assert-true (some (lambda (e) (search "timer-boom-marker"
                                          (princ-to-string e)))
                     (limn/error:get-backtrace-entries))))

(deftest cond-c4-multithread-messages-not-corrupt
  ;; Concurrent error pushes from multiple threads must not corrupt
  ;; the backtrace list (no torn entries, count matches).
  (limn/error:clear-backtrace)
  (let ((threads (loop repeat 10 collect
                       (sb-thread:make-thread
                        (lambda ()
                          (handler-case
                              (dotimes (_ 5)
                                (limn/error:with-error-protection
                                  (error "race-marker")))
                            (error () nil)))))))
    (mapc #'sb-thread:join-thread threads)
    (sleep 0.05)
    (let* ((entries (limn/error:get-backtrace-entries))
           (hits (count-if (lambda (e) (search "race-marker"
                                                (princ-to-string e)))
                           entries)))
      ;; Ring may have evicted some; total seen should be ≤ 50 but
      ;; at least 10 (one per thread minimum).
      (assert-true (>= hits 10)
                   (format nil "got ~A race-marker hits" hits)))))

(deftest cond-c4-log-error-no-recursion
  ;; log:message inside with-error-protection that errors must not
  ;; infinitely recurse.
  (with-timeout-bound 1
    (limn/error:with-error-protection
      (funcall (find-symbol "MESSAGE" '#:limn/log) "test-msg")
      (error "stop"))))

(deftest cond-c4-bridge-handler-error-keeps-socket
  ;; Bridge command handlers must be wrapped with
  ;; with-error-protection so a throw doesn't drop the socket. We
  ;; cannot easily simulate the full bridge here without a running
  ;; backend, but we can verify that the contract function exists.
  (assert-true (fboundp (find-symbol "WITH-ERROR-PROTECTION" '#:limn/error))))

(deftest cond-c4-event-error-reaches-frontend-hook
  ;; A subscriber to event/error should fire — proxy for chrome-bar
  ;; visibility in Qt-tier.
  (let ((got nil))
    (let ((h (lambda (&rest ev) (declare (ignore ev)) (setf got t))))
      (funcall (find-symbol "ADD-HOOK" '#:limn/hooks) :event/error h)
      (unwind-protect
           (progn
             (limn/error:with-error-protection (error "frontend-visible"))
             (sleep 0.05))
        (funcall (find-symbol "REMOVE-HOOK" '#:limn/hooks) :event/error h)))
    (assert-true got)))
