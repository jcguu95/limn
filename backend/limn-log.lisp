;;;; limn-log — *Messages* ring + level-filtered event/message stream.
;;;;
;;;; Pure Lisp. Thread-safe. v0.23 §E.
;;;;
;;;; The ring always records every message regardless of *log-level*;
;;;; the level only controls whether event/message fires (so frontend
;;;; subscribers can be quieter while the in-buffer *Messages* trail
;;;; remains complete for post-mortem inspection).

(defpackage #:limn/log
  (:use #:cl)
  (:export #:message
           #:*messages-ring-size*
           #:get-messages
           #:clear-messages
           #:*log-level*
           #:with-log-level
           #:level>=))

(in-package #:limn/log)

(defvar *messages-ring-size* 1000
  "Maximum number of messages retained in the *Messages* ring.")

(defvar *log-level* :info
  "Minimum level for event/message to fire. One of :debug :info :warn :error.")

(defvar *messages* '()
  "Ring contents — newest first. Length capped at *messages-ring-size*.")

(defvar *lock* (sb-thread:make-mutex :name "limn/log"))

;;; ─── Level comparison ────────────────────────────────────────────────

(defparameter *level-rank*
  '((:debug . 0) (:info . 1) (:warn . 2) (:error . 3)))

(defun %rank (lv)
  (or (cdr (assoc lv *level-rank*)) 1))

(defun level>= (a b)
  "True if level A is at least as severe as level B."
  (>= (%rank a) (%rank b)))

;;; ─── Message API ─────────────────────────────────────────────────────

(defun %trim ()
  (let ((excess (- (length *messages*) *messages-ring-size*)))
    (when (plusp excess)
      (setf *messages* (subseq *messages* 0 *messages-ring-size*)))))

(defun message (fmt-or-level &rest args)
  "Push a message into the *Messages* ring.

   Two call shapes:
     (message \"x = ~A\" value)              ; level defaults to :info
     (message :warn \"x = ~A\" value)        ; explicit level

   Always records to the ring. Fires event/message only when the
   effective level meets *log-level*."
  (let* ((level (if (keywordp fmt-or-level) fmt-or-level :info))
         (fmt   (if (keywordp fmt-or-level) (first args) fmt-or-level))
         (more  (if (keywordp fmt-or-level) (rest args) args))
         (text  (handler-case (apply #'format nil fmt more)
                  (error (e) (format nil "<log format error: ~A>" e)))))
    (sb-thread:with-mutex (*lock*)
      (push text *messages*)
      (%trim))
    (when (level>= level *log-level*)
      (let ((hooks (find-package '#:limn/hooks)))
        (when hooks
          (funcall (find-symbol "RUN-HOOK" hooks)
                   :event/message
                   (list :level level :text text)))))
    text))

(defun get-messages (&optional count)
  "Return messages newest-first. If COUNT is given, return at most that many."
  (sb-thread:with-mutex (*lock*)
    (if count
        (subseq *messages* 0 (min count (length *messages*)))
        (copy-list *messages*))))

(defun clear-messages ()
  (sb-thread:with-mutex (*lock*)
    (setf *messages* '()))
  nil)

;;; ─── with-log-level ──────────────────────────────────────────────────

(defmacro with-log-level (level &body body)
  `(let ((*log-level* ,level)) ,@body))
