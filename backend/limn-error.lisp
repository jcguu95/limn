;;;; limn-error — protected-call wrapper + debugger hook + *Backtrace*.
;;;;
;;;; Pure Lisp. Thread-safe. v0.23 §C.
;;;;
;;;; Philosophy: in a long-running event-driven runtime, an uncaught
;;;; error in a user callback (sentinel, timer, hook handler) must
;;;; never take down the dispatch loop. with-error-protection wraps
;;;; bodies, captures conditions, invokes *debugger-hook*, records to
;;;; the *Backtrace* ring, and fires event/error.

(defpackage #:limn/error
  (:use #:cl)
  (:shadow #:*debugger-hook*)
  (:export #:with-error-protection
           #:%call-with-protection
           #:*debugger-hook*
           #:*backtrace-buffer*
           #:backtrace-limit
           #:backtrace-count
           #:get-backtrace-entries
           #:clear-backtrace))

(in-package #:limn/error)

(defvar *backtrace-buffer* '()
  "Ring of recent caught errors, newest first.")

(defvar backtrace-limit 100
  "Maximum number of error entries retained.")

(defvar *lock* (sb-thread:make-mutex :name "limn/error"))

;;; ─── Recording ───────────────────────────────────────────────────────

(defun %capture-backtrace ()
  (handler-case
      (with-output-to-string (s)
        (sb-debug:print-backtrace :stream s :count 30))
    (error () "<backtrace unavailable>")))

(defun %record (condition)
  (let ((entry (list :class (type-of condition)
                     :message (princ-to-string condition)
                     :backtrace (%capture-backtrace)
                     :time (get-universal-time))))
    (sb-thread:with-mutex (*lock*)
      (push entry *backtrace-buffer*)
      (let ((excess (- (length *backtrace-buffer*) backtrace-limit)))
        (when (plusp excess)
          (setf *backtrace-buffer*
                (subseq *backtrace-buffer* 0 backtrace-limit)))))
    entry))

(defun get-backtrace-entries ()
  (sb-thread:with-mutex (*lock*) (copy-list *backtrace-buffer*)))

(defun backtrace-count ()
  (sb-thread:with-mutex (*lock*) (length *backtrace-buffer*)))

(defun clear-backtrace ()
  (sb-thread:with-mutex (*lock*) (setf *backtrace-buffer* '()))
  nil)

;;; ─── Default debugger hook ───────────────────────────────────────────

(defun %default-debugger-hook (condition prev-hook)
  "Records the condition to *Backtrace*, logs to *Messages*, and fires
   event/error. Never re-throws."
  (declare (ignore prev-hook))
  (let ((entry (%record condition)))
    (let ((log (find-package '#:limn/log)))
      (when log
        (handler-case
            (funcall (find-symbol "MESSAGE" log)
                     :error
                     "[error] ~A~%~A"
                     (getf entry :message)
                     (getf entry :backtrace))
          (error () nil))))
    (let ((hooks (find-package '#:limn/hooks)))
      (when hooks
        (handler-case
            (funcall (find-symbol "RUN-HOOK" hooks) :event/error entry)
          (error () nil))))
    nil))

(defvar *debugger-hook* #'%default-debugger-hook
  "Function (condition prev-hook) called for caught errors. Bind or
   setf to override. If user hook signals, falls back to the default.")

;;; ─── with-error-protection ───────────────────────────────────────────

(defun %call-with-protection (fn &rest args)
  "Function form of with-error-protection — useful for other modules
   to invoke as `(funcall (find-symbol \"%CALL-WITH-PROTECTION\" ...))`
   on a callback they don't want to expand at compile time."
  (handler-case (apply fn args)
    (error (e)
      (let ((hook *debugger-hook*))
        (handler-case (funcall hook e nil)
          (error ()
            (handler-case (%default-debugger-hook e nil)
              (error () nil)))))
      nil)))

(defmacro with-error-protection (&body body)
  "Run BODY, catching any ERROR. On error: invoke *debugger-hook*
   (with safe fallback to default if the user hook itself errors) and
   return NIL. Non-error conditions (warnings, signals) pass through."
  `(handler-case (progn ,@body)
     (error (e)
       (let ((hook *debugger-hook*))
         (handler-case (funcall hook e nil)
           (error ()
             ;; User hook itself blew up — fall back to default.
             (handler-case (%default-debugger-hook e nil)
               (error () nil)))))
       nil)))
