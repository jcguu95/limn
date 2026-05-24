;;;; v0.23 shared test helpers
;;;;
;;;; - with-timeout-bound : fail the current test if a body hangs past
;;;;   N seconds (uses sb-ext:with-timeout; turns the timeout into a
;;;;   normal assertion fail rather than letting the suite stall)
;;;; - wait-for-event     : block until a predicate matches a pushed
;;;;   event or timeout fires (used by tests that exercise event/*
;;;;   delivery)
;;;; - fake-clock         : a controllable monotonic clock for timer
;;;;   unit tests; replaces limn/timer:*now-fn*
;;;; - mock-buffer        : minimal in-memory buffer used by undo unit
;;;;   tests to simulate event/buffer-modified emission without
;;;;   needing the real gap buffer

(defpackage #:limn/v023-helpers
  (:use #:cl)
  (:export #:with-timeout-bound
           #:wait-for-event
           #:make-fake-clock #:fake-clock-now #:fake-clock-advance
           #:make-mock-buffer #:mock-buffer-text #:mock-buffer-events
           #:mock-insert #:mock-delete #:mock-replace
           #:register-mock-buffer #:unregister-mock-buffer
           #:install-mock-inverse-handler
           #:portable-true #:portable-false #:portable-echo
           #:portable-cat #:portable-sh #:portable-pwd
           #:portable-yes #:portable-head #:portable-printf))

(in-package #:limn/v023-helpers)

;; sb-ext and sb-thread are built into SBCL — no require needed.

;;; ─── with-timeout-bound ────────────────────────────────────────────
;;; Wrap any potentially-hanging body. On timeout: signal a regular
;;; condition that the test framework records as a fail (instead of
;;; letting the test suite hang forever).

(define-condition hang-timeout (error)
  ((seconds :initarg :seconds :reader hang-timeout-seconds)
   (body    :initarg :body    :reader hang-timeout-body))
  (:report (lambda (c s)
             (format s "BODY hung past ~A seconds: ~S"
                     (hang-timeout-seconds c)
                     (hang-timeout-body c)))))

(defmacro with-timeout-bound (seconds &body body)
  `(handler-case
       (sb-ext:with-timeout ,seconds
         (progn ,@body))
     (sb-ext:timeout ()
       (error 'hang-timeout :seconds ,seconds :body ',body))))

;;; ─── wait-for-event ────────────────────────────────────────────────
;;; Subscribe transiently to a hook, return as soon as predicate fires
;;; once, or signal hang-timeout. The integration with limn/hooks is
;;; lazy — if the hook package isn't loaded (pure unit run with no
;;; bridge), this falls back to polling a user-supplied callback.

(defun wait-for-event (hook-name predicate &key (timeout 2.0))
  "Wait until PREDICATE returns true for an event pushed via
   HOOK-NAME, or signal HANG-TIMEOUT after TIMEOUT seconds.
   HOOK-NAME is a symbol matching the event-name keyword the
   producer uses with limn/hooks:run-hook (e.g. 'event/process-exit)."
  (let* ((seen   nil)
         (lock   (sb-thread:make-mutex))
         (cvar   (sb-thread:make-waitqueue))
         (handler (lambda (&rest ev)
                    (when (apply predicate ev)
                      (sb-thread:with-mutex (lock)
                        (setf seen ev)
                        (sb-thread:condition-notify cvar))))))
    (unless (find-package '#:limn/hooks)
      (error "wait-for-event needs limn/hooks loaded"))
    (funcall (find-symbol "ADD-HOOK" '#:limn/hooks) hook-name handler)
    (unwind-protect
         (sb-thread:with-mutex (lock)
           (loop until seen do
             (unless (sb-thread:condition-wait cvar lock :timeout timeout)
               (error 'hang-timeout :seconds timeout :body hook-name)))
           seen)
      (funcall (find-symbol "REMOVE-HOOK" '#:limn/hooks)
               hook-name handler))))

;;; ─── fake-clock ────────────────────────────────────────────────────
;;; Used by timer unit tests. Replace limn/timer:*now-fn* with
;;; (lambda () (fake-clock-now c)) and advance via fake-clock-advance.

(defstruct fake-clock
  (now 0.0d0 :type double-float))

(defun fake-clock-advance (c seconds)
  (incf (fake-clock-now c) (coerce seconds 'double-float))
  (fake-clock-now c))

;;; ─── mock-buffer ───────────────────────────────────────────────────
;;; Lightweight stand-in for the real gap buffer. Operations append to
;;; an EVENTS list shaped like event/buffer-modified payloads, which
;;; the undo subsystem subscribes to. Cursor / point semantics are
;;; intentionally absent — undo only cares about positions/lengths.

(defstruct mock-buffer
  (id    nil)
  (text  "" :type string)
  (events '()))

(defun %emit (buf op pos len before after)
  (let ((ev (list :buf-id (mock-buffer-id buf)
                  :op op :pos pos :len len
                  :before before :after after)))
    (push ev (mock-buffer-events buf))
    ;; If limn/hooks is loaded, fan out as the real wire event too.
    (let ((hooks (find-package '#:limn/hooks)))
      (when hooks
        (funcall (find-symbol "RUN-HOOK" hooks) :event/buffer-modified ev)))
    ev))

(defun mock-insert (buf pos s)
  (let ((before (subseq (mock-buffer-text buf) 0 pos))
        (after  (subseq (mock-buffer-text buf) pos)))
    (setf (mock-buffer-text buf) (concatenate 'string before s after)))
  (%emit buf :insert pos (length s) "" s))

(defun mock-delete (buf pos len)
  (let* ((txt (mock-buffer-text buf))
         (removed (subseq txt pos (+ pos len))))
    (setf (mock-buffer-text buf)
          (concatenate 'string (subseq txt 0 pos) (subseq txt (+ pos len))))
    (%emit buf :delete pos len removed "")))

(defun mock-replace (buf pos len new-str)
  (let* ((txt (mock-buffer-text buf))
         (removed (subseq txt pos (+ pos len))))
    (setf (mock-buffer-text buf)
          (concatenate 'string (subseq txt 0 pos) new-str (subseq txt (+ pos len))))
    (%emit buf :replace pos len removed new-str)))

;;; ─── mock-buffer registry + inverse-op subscriber ────────────────
;;;
;;; The undo system fires `buffer-undo/apply-inverse` events whose
;;; payload describes how to reverse an edit. To make mock-buffer
;;; tests realistic, install a hook that mutates the registered
;;; mock-buffer's text WITHOUT re-emitting event/buffer-modified
;;; (which would recursively record the inverse as a new edit).

(defvar *mock-registry* (make-hash-table :test 'equal))
(defvar *mock-inverse-installed* nil)

(defun register-mock-buffer (buf)
  (setf (gethash (mock-buffer-id buf) *mock-registry*) buf))

(defun unregister-mock-buffer (buf-id)
  (remhash buf-id *mock-registry*))

(defun %apply-to-mock (buf inv)
  (let ((text (mock-buffer-text buf))
        (op (getf inv :op)))
    (case op
      (:insert
       (let ((pos (getf inv :pos))
             (s (or (getf inv :text) (getf inv :after))))
         (setf (mock-buffer-text buf)
               (concatenate 'string (subseq text 0 pos) s (subseq text pos)))))
      (:delete
       (let ((pos (getf inv :pos))
             (len (getf inv :len)))
         (setf (mock-buffer-text buf)
               (concatenate 'string (subseq text 0 pos)
                            (subseq text (+ pos len))))))
      (:replace
       (let ((pos (getf inv :pos))
             (len (getf inv :len))
             (after (getf inv :after)))
         (setf (mock-buffer-text buf)
               (concatenate 'string (subseq text 0 pos) after
                            (subseq text (+ pos len)))))))))

(defun install-mock-inverse-handler ()
  (unless *mock-inverse-installed*
    (let ((hooks (find-package '#:limn/hooks)))
      (when hooks
        (funcall (find-symbol "ADD-HOOK" hooks)
                 :buffer-undo/apply-inverse
                 (lambda (buf-id inv)
                   (let ((buf (gethash buf-id *mock-registry*)))
                     (when buf (%apply-to-mock buf inv)))))
        (setf *mock-inverse-installed* t))))
  t)

;;; ─── Portable Unix command paths ─────────────────────────────────
;;; macOS keeps coreutils in /usr/bin; many Linux distros use /bin.
;;; Pick at load time so tests aren't tied to a single layout.

(defun %first-exists (paths)
  (loop for p in paths when (probe-file p) return p))

(defparameter portable-true    (%first-exists '("/bin/true"    "/usr/bin/true")))
(defparameter portable-false   (%first-exists '("/bin/false"   "/usr/bin/false")))
(defparameter portable-echo    (%first-exists '("/bin/echo"    "/usr/bin/echo")))
(defparameter portable-cat     (%first-exists '("/bin/cat"     "/usr/bin/cat")))
(defparameter portable-sh      (%first-exists '("/bin/sh"      "/usr/bin/sh")))
(defparameter portable-pwd     (%first-exists '("/bin/pwd"     "/usr/bin/pwd")))
(defparameter portable-yes     (%first-exists '("/usr/bin/yes" "/bin/yes")))
(defparameter portable-head    (%first-exists '("/usr/bin/head" "/bin/head")))
(defparameter portable-printf  (%first-exists '("/usr/bin/printf" "/bin/printf")))
