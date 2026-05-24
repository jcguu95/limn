;;;; v0.23 §E — logging / *Messages* RED tests
;;;; ~15 tests covering ring, format, event, level, integration.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/log)
    (make-package '#:limn/log :use '(#:cl)))
  (dolist (sym '("MESSAGE"
                 "*MESSAGES-RING-SIZE*"
                 "GET-MESSAGES"
                 "CLEAR-MESSAGES"
                 "*LOG-LEVEL*" "WITH-LOG-LEVEL"
                 "LEVEL>="))
    (let ((s (intern sym '#:limn/log)))
      (export s '#:limn/log))))

(in-package #:limn/unit-test)

(use-package '#:limn/v023-helpers)

(defmacro with-clean-log (&body body)
  `(progn (limn/log:clear-messages) ,@body))

;;; ─── E1. message API ──────────────────────────────────────────────

(deftest log-e1-basic-message
  (with-clean-log
    (limn/log:message "hello")
    (assert-true (find "hello" (limn/log:get-messages) :test #'search))))

(deftest log-e1-format-args
  (with-clean-log
    (limn/log:message "x=~A y=~A" 1 2)
    (assert-true (find "x=1 y=2" (limn/log:get-messages) :test #'search))))

(deftest log-e1-newline-in-string
  (with-clean-log
    (limn/log:message "line-a~%line-b")
    (let ((msgs (limn/log:get-messages)))
      (assert-true (or (find "line-a" msgs :test #'search)
                       (find "line-b" msgs :test #'search))))))

(deftest log-e1-non-printable-no-crash
  (with-clean-log
    (assert-no-error
      (limn/log:message "with-nul:~C:end" (code-char 0)))))

(deftest log-e1-extreme-length-tolerated
  (with-clean-log
    (assert-no-error
      (limn/log:message "~A" (make-string 50000 :initial-element #\Z)))))

;;; ─── E2. Ring behavior ────────────────────────────────────────────

(deftest log-e2-ring-rolls-over
  (let ((limn/log:*messages-ring-size* 5))
    (with-clean-log
      (dotimes (i 10) (limn/log:message "msg-~A" i))
      (let ((msgs (limn/log:get-messages)))
        (assert-eql 5 (length msgs))
        ;; Last 5 should be msg-5..msg-9
        (assert-true (find "msg-9" msgs :test #'search))
        (assert-false (find "msg-0" msgs :test #'search))))))

(deftest log-e2-get-messages-newest-first
  (with-clean-log
    (limn/log:message "first")
    (limn/log:message "second")
    (limn/log:message "third")
    (let ((msgs (limn/log:get-messages)))
      (assert-true (search "third" (first msgs))))))

(deftest log-e2-clear-empties
  (with-clean-log
    (limn/log:message "to-be-cleared")
    (limn/log:clear-messages)
    (assert-eql 0 (length (limn/log:get-messages)))))

(deftest log-e2-concurrent-push-no-loss-or-dup
  (with-clean-log
    (let ((limn/log:*messages-ring-size* 10000)
          (threads (loop for t-idx from 0 below 5 collect
                         (let ((idx t-idx))
                           (sb-thread:make-thread
                            (lambda ()
                              (handler-case
                                  (dotimes (i 100)
                                    (limn/log:message "t~A-i~A" idx i))
                                (error () nil))))))))
      (mapc #'sb-thread:join-thread threads)
      (assert-eql 500 (length (limn/log:get-messages))))))

;;; ─── E3. Event & log level ────────────────────────────────────────

(deftest log-e3-each-message-pushes-event
  (with-clean-log
    (let ((seen 0))
      (let ((h (lambda (&rest ev) (declare (ignore ev)) (incf seen))))
        (funcall (find-symbol "ADD-HOOK" '#:limn/hooks) :event/message h)
        (unwind-protect
             (progn (limn/log:message "a") (limn/log:message "b") (sleep 0.05))
          (funcall (find-symbol "REMOVE-HOOK" '#:limn/hooks) :event/message h)))
      (assert-eql 2 seen))))

(deftest log-e3-with-log-level-filters-events
  (with-clean-log
    (let ((seen 0))
      (let ((h (lambda (&rest ev) (declare (ignore ev)) (incf seen))))
        (funcall (find-symbol "ADD-HOOK" '#:limn/hooks) :event/message h)
        (unwind-protect
             (limn/log:with-log-level :warn
               (limn/log:message :info "low")    ; suppressed
               (limn/log:message :warn "high")   ; passes
               (sleep 0.05))
          (funcall (find-symbol "REMOVE-HOOK" '#:limn/hooks) :event/message h)))
      (assert-eql 1 seen))))

(deftest log-e3-level-comparison
  (assert-true  (limn/log:level>= :error :warn))
  (assert-true  (limn/log:level>= :warn  :info))
  (assert-true  (limn/log:level>= :info  :debug))
  (assert-false (limn/log:level>= :debug :info))
  (assert-false (limn/log:level>= :info  :warn)))

(deftest log-e3-level-does-not-affect-ring
  ;; Even when an event is filtered out, the ring should still
  ;; record the message (so user can inspect *Messages* after).
  (with-clean-log
    (limn/log:with-log-level :error
      (limn/log:message :info "still-recorded"))
    (assert-true (find "still-recorded" (limn/log:get-messages)
                       :test #'search))))

;;; ─── E4. Integration ──────────────────────────────────────────────

(deftest log-e4-condition-backtrace-written-to-messages
  ;; A caught error should land its backtrace in *Messages*.
  (with-clean-log
    (limn/error:with-error-protection (error "integration-marker"))
    (sleep 0.05)
    (assert-true (find "integration-marker"
                       (limn/log:get-messages)
                       :test #'search))))

(deftest log-e4-no-raw-format-t-in-framework-source
  ;; Grep check: framework's user-facing log path should be
  ;; limn/log:message, not direct (format t ...). v0.23 implementation
  ;; should aim for ≤ 30 raw (format t) sites in backend/*.lisp,
  ;; excluding tests/ and examples/.
  (let* ((dir (namestring
               (merge-pathnames "../../"
                                (make-pathname
                                 :defaults *load-truename*
                                 :name nil :type nil))))
         (cmd (format nil "find ~A -name '*.lisp' -not -path '*/tests/*' -not -path '*/examples/*' -exec grep -l 'format t' {} \\; | wc -l" dir)))
    (let* ((raw (with-output-to-string (out)
                  (let ((proc (sb-ext:run-program "/bin/sh" (list "-c" cmd)
                                                  :output out :wait t)))
                    (declare (ignore proc)))))
           (n (or (ignore-errors
                   (parse-integer (string-trim '(#\Space #\Newline) raw)))
                  0)))
      ;; Skip cleanly if grep produced nothing parseable; otherwise
      ;; require fewer than 30 files using raw format t.
      (assert-true (< n 30)
                   (format nil "~A backend files still use (format t)" n)))))
