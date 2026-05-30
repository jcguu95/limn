;;;; limn-log — *Messages* ring + hierarchical-ns verbosity + wire mirror.
;;;;
;;;; Pure Lisp. Thread-safe. v0.23 §E + v0.37 hierarchical extension.
;;;;
;;;; The ring always records every message regardless of effective level;
;;;; the level only controls whether event/message fires and whether
;;;; *log-wire-sender* is invoked (so frontend subscribers can be quieter
;;;; while the in-buffer *Messages* trail remains complete for post-mortem
;;;; inspection).
;;;;
;;;; Namespace verbosity (v0.37):
;;;;   ns is any symbol whose name encodes a dotted hierarchy, e.g.
;;;;     'pdf-mode             — root
;;;;     'pdf-mode.annotation  — child
;;;;     'pdf-mode.annotation.edit — grandchild
;;;;   effective-level walks leaf → root → *default-log-level*.
;;;;   set-level / unset-level / get-level operate on exact bindings.
;;;;   Canonical key is SYMBOL-NAME (uppercase string), so the user can
;;;;   write 'pdf-mode in any package and it resolves the same.

(defpackage #:limn/log
  (:use #:cl)
  (:export #:message
           #:*messages-ring-size*
           #:get-messages
           #:get-records
           #:clear-messages
           #:log-record
           #:log-record-p
           #:make-log-record
           #:log-record-time
           #:log-record-level
           #:log-record-ns
           #:log-record-text
           #:*log-level*
           #:*default-log-level*
           #:*log-levels*
           #:set-level
           #:unset-level
           #:get-level
           #:effective-level
           #:with-log-level
           #:with-log-levels
           #:*log-wire-sender*
           #:level>=))

(in-package #:limn/log)

(defvar *messages-ring-size* 1000
  "Maximum number of messages retained in the *Messages* ring.")

(defvar *log-level* :info
  "DEPRECATED in favour of *default-log-level*. Retained as alias for
   v0.23 callers; set/with-log-level continues to update it.")

(defvar *default-log-level* :info
  "Fallback level when a message's ns has no explicit binding in
   *log-levels*. One of :debug :info :warn :error.")

(defvar *log-levels* (make-hash-table :test 'equal)
  "Hash from canonical ns key (uppercase SYMBOL-NAME string) → level.
   Use set-level / unset-level rather than mutating directly.")

(defvar *log-wire-sender* nil
  "(function (log-record) → ignored) called once per message that passes
   its ns's effective level. NIL = no wire side effect (unit tests,
   pre-session bring-up). Session install hooks this up to mirror each
   log line into the C++ *messages* GapBuffer via the message/log wire
   command. Errors in the sender are swallowed: a misbehaving wire must
   not corrupt the ring.")

(defvar *messages* '()
  "Ring of log-record structs — newest first. Length capped at
   *messages-ring-size*.")

(defvar *lock* (sb-thread:make-mutex :name "limn/log"))

;;; ─── log-record ──────────────────────────────────────────────────────

(defstruct log-record
  (time  (get-universal-time) :type integer)
  (level :info                :type keyword)
  (ns    :default)
  (text  ""                   :type string))

;;; ─── Level comparison ────────────────────────────────────────────────

(defparameter *level-rank*
  '((:debug . 0) (:info . 1) (:warn . 2) (:error . 3)))

(defun %rank (lv)
  (or (cdr (assoc lv *level-rank*)) 1))

(defun level>= (a b)
  "True if level A is at least as severe as level B."
  (>= (%rank a) (%rank b)))

;;; ─── Namespace plumbing ──────────────────────────────────────────────

(defun %ns-key (ns)
  "Canonicalise NS to its uppercase symbol-name. Accepts symbols,
   keywords, or strings (so callers can pass 'pdf-mode, :pdf-mode, or
   \"pdf-mode\" interchangeably)."
  (string-upcase
   (cond ((stringp ns) ns)
         ((symbolp ns) (symbol-name ns))
         (t (error "ns must be a symbol or string, got ~S" ns)))))

(defun %ns-chain (ns)
  "Leaf-to-root inclusive chain of ns keys.
   e.g. 'pdf-mode.annotation.edit → (\"PDF-MODE.ANNOTATION.EDIT\"
                                     \"PDF-MODE.ANNOTATION\"
                                     \"PDF-MODE\")."
  (loop for s = (%ns-key ns) then (subseq s 0 dot)
        for dot = (position #\. s :from-end t)
        collect s
        while dot))

(defun set-level (ns level)
  "Bind NS to LEVEL. NS is a symbol/keyword/string; LEVEL is one of
   :debug :info :warn :error. Returns LEVEL."
  (setf (gethash (%ns-key ns) *log-levels*) level)
  level)

(defun unset-level (ns)
  "Remove NS's explicit binding (effective-level falls back to
   nearest ancestor or *default-log-level*). Returns T if a binding
   was removed, NIL otherwise."
  (remhash (%ns-key ns) *log-levels*))

(defun get-level (ns)
  "Return the level explicitly bound to NS, or NIL if NS only inherits.
   Use effective-level for the resolved-with-inheritance answer."
  (gethash (%ns-key ns) *log-levels*))

(defun effective-level (ns)
  "Resolve NS's effective level: walk the dotted hierarchy leaf-to-root,
   returning the first explicit binding; fall back to *default-log-level*."
  (or (loop for k in (%ns-chain ns)
            for lv = (gethash k *log-levels*)
            when lv return lv)
      *default-log-level*))

(defmacro with-log-levels (bindings &body body)
  "Dynamically rebind several ns levels for the extent of BODY.
   BINDINGS is a list of (NS LEVEL) pairs. Original values are restored
   on unwind (including for ns's that had no prior binding)."
  (let ((saved (gensym "SAVED"))
        (b     (gensym "B")))
    `(let ((,saved (loop for ,b in ',bindings
                         collect (cons (%ns-key (first ,b))
                                       (gethash (%ns-key (first ,b))
                                                *log-levels*
                                                'unbound)))))
       (unwind-protect
            (progn
              ,@(loop for (ns lv) in bindings
                      collect `(set-level ',ns ,lv))
              ,@body)
         (dolist (,b ,saved)
           (if (eq (cdr ,b) 'unbound)
               (remhash (car ,b) *log-levels*)
               (setf (gethash (car ,b) *log-levels*) (cdr ,b))))))))

;;; ─── Message API ─────────────────────────────────────────────────────

(defun %trim ()
  (let ((excess (- (length *messages*) *messages-ring-size*)))
    (when (plusp excess)
      (setf *messages* (subseq *messages* 0 *messages-ring-size*)))))

(defun %parse-message-args (fmt-or-key args)
  "Decode message's three accepted call shapes into (level ns fmt more):
     (message \"x\" ...)                     ; :info :default
     (message :warn \"x\" ...)               ; :warn  :default
     (message :level L :ns N :: \"x\" ...)   ; explicit
   Returns (values level ns fmt more-args)."
  (cond
    ;; Shape 1: first arg is a format string → :info / :default.
    ((stringp fmt-or-key)
     (values :info :default fmt-or-key args))
    ;; Shape 3: explicit keyword form — :level and/or :ns precede fmt.
    ((and (keywordp fmt-or-key)
          (member fmt-or-key '(:level :ns)))
     (let ((level :info) (ns :default) (rest (cons fmt-or-key args)))
       (loop while (and (consp rest)
                        (keywordp (first rest))
                        (member (first rest) '(:level :ns)))
             do (case (first rest)
                  (:level (setf level (second rest)))
                  (:ns    (setf ns    (second rest))))
                (setf rest (cddr rest)))
       (values level ns (first rest) (rest rest))))
    ;; Shape 2: bare level keyword shorthand.
    ((keywordp fmt-or-key)
     (values fmt-or-key :default (first args) (rest args)))
    (t
     (error "message: first arg must be a format string or keyword, got ~S"
            fmt-or-key))))

(defun message (fmt-or-key &rest args)
  "Push a message into the *Messages* ring.

   Three call shapes:
     (message \"x = ~A\" value)                       ; :info :default
     (message :warn \"x = ~A\" value)                 ; :warn  :default
     (message :level :warn :ns 'pdf-mode \"x\" 1)     ; explicit

   Always records to the ring. Fires event/message and calls
   *log-wire-sender* only when the effective level for NS meets
   the threshold."
  (multiple-value-bind (level ns fmt more)
      (%parse-message-args fmt-or-key args)
    (let* ((text   (handler-case (apply #'format nil fmt more)
                     (error (e) (format nil "<log format error: ~A>" e))))
           (record (make-log-record :level level :ns ns :text text)))
      (sb-thread:with-mutex (*lock*)
        (push record *messages*)
        (%trim))
      (when (level>= level (effective-level ns))
        (let ((hooks (find-package '#:limn/hooks)))
          (when hooks
            (funcall (find-symbol "RUN-HOOK" hooks)
                     :event/message
                     (list :level level :ns ns :text text))))
        (when *log-wire-sender*
          (handler-case (funcall *log-wire-sender* record)
            (error () nil))))
      text)))

(defun get-messages (&optional count)
  "Return formatted message strings, newest-first.
   If COUNT is given, return at most that many.
   This is the v0.23 API — callers wanting the structured records
   should use get-records."
  (sb-thread:with-mutex (*lock*)
    (let ((recs (if count
                    (subseq *messages* 0 (min count (length *messages*)))
                    (copy-list *messages*))))
      (mapcar #'log-record-text recs))))

(defun get-records (&optional count)
  "Return log-record structs newest-first. If COUNT is given, at most
   that many."
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
  "Dynamically set the global default log level for BODY.
   Updates BOTH *default-log-level* (v0.37) and *log-level* (v0.23 alias)
   so old callers continue to observe the override."
  `(let ((*default-log-level* ,level)
         (*log-level*         ,level))
     ,@body))
