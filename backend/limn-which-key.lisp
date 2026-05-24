;;;; limn-which-key — which-key minor mode (v0.28 §C).
;;;;
;;;; Listens to event/key-prefix-changed; when a prefix is active and
;;;; the user idles for *idle-delay* seconds, echoes the available next
;;;; keys in the minibuffer / echo area.
;;;;
;;;; I/O is via *echo-fn* and *timer-fn* dynvars so unit tests can swap
;;;; in mocks.  At runtime, install wires:
;;;;   *echo-fn*  → limn:call "message/echo"
;;;;   *timer-fn* → limn/timer:run-at (or similar)

(defpackage #:limn/which-key
  (:use #:cl)
  (:export #:which-key-mode #:*which-key-mode*
           #:*idle-delay* #:*max-display*
           #:format-which-key
           #:*echo-fn* #:*timer-fn*
           #:install))

(in-package #:limn/which-key)

;;; ── state ─────────────────────────────────────────────────────────────────

(defvar *which-key-mode* nil
  "Non-nil when which-key is enabled.  Toggle via (which-key-mode).")

(defvar *idle-delay* 0.5
  "Seconds of prefix-key idleness before the popup appears.")

(defvar *max-display* 20
  "Maximum number of bindings to render in the popup at once.")

;;; ── I/O vtable ────────────────────────────────────────────────────────────

(defvar *echo-fn*
  (lambda (str) (declare (ignore str)))
  "Display STR in the echo area.  Runtime wires this to message/echo.")

(defvar *timer-fn*
  (lambda (delay cb) (declare (ignore delay cb)))
  "Schedule CB to run after DELAY seconds.  Runtime wires to limn/timer.")

;;; ── internal — track the latest pending prefix ───────────────────────────

(defvar *current-prefix* nil
  "The most recent prefix from event/key-prefix-changed; used by timer
   callbacks to skip stale firings after a newer prefix change.")

;;; ── format-which-key ─────────────────────────────────────────────────────

(defun %action-name (action)
  "Render ACTION as a display string for the popup."
  (let ((keys-pkg (find-package '#:limn/keys)))
    (cond
      ;; Sub-keymap → "+prefix"
      ((and keys-pkg
            (let ((kmap-p (find-symbol "KEYMAP-P" keys-pkg)))
              (and kmap-p (funcall (symbol-function kmap-p) action))))
       "+prefix")
      ((functionp action)
       (let ((name (nth-value 2 (function-lambda-expression action))))
         (cond ((null name) "lambda")
               ((symbolp name) (string-downcase (symbol-name name)))
               (t (format nil "~a" name)))))
      ((symbolp action)
       (string-downcase (symbol-name action)))
      (t (format nil "~a" action)))))

(defun format-which-key (km prefix)
  "Format KM's bindings as a single-line display string.  PREFIX is the
   current key prefix string (for context; not currently displayed)."
  (declare (ignore prefix))
  (let ((keys-pkg (find-package '#:limn/keys)))
    (unless keys-pkg
      (return-from format-which-key ""))
    (let* ((bindings-accessor (find-symbol "KEYMAP-BINDINGS" keys-pkg))
           (entries '()))
      ;; KEYMAP-BINDINGS is the defstruct accessor; not exported but
      ;; accessible as an internal symbol.
      (when (and bindings-accessor (fboundp bindings-accessor))
        (let ((bindings (funcall (symbol-function bindings-accessor) km)))
          (when (hash-table-p bindings)
            (maphash (lambda (k v) (push (cons k v) entries)) bindings))))
      (setf entries (sort entries #'string< :key #'car))
      (when (> (length entries) *max-display*)
        (setf entries (subseq entries 0 *max-display*)))
      (with-output-to-string (s)
        (loop for (key . action) in entries
              for first = t then nil
              do (unless first (write-string "  " s))
                 (format s "~a → ~a" key (%action-name action)))))))

;;; ── event handler — prefix-changed dispatch ──────────────────────────────

(defun %extract-prefix (ev)
  "The event/key-prefix-changed payload has been shaped differently by
   different producers:
     - limn/keys:set-key-prefix uses (:|old| OLD :|new| NEW)
     - test fixtures often use (:|prefix| VALUE)
   Accept both."
  (cond ((not (listp ev)) nil)
        ((getf ev :|prefix|))
        (t (getf ev :|new|))))

(defun %prefix-empty-p (prefix)
  (or (null prefix)
      (and (stringp prefix) (zerop (length prefix)))
      (and (listp prefix) (null prefix))))

(defun %on-prefix-changed (ev)
  "Hook callback for event/key-prefix-changed.  Schedules a deferred
   echo of the available next keys, or skips entirely if mode is off
   or the prefix is empty."
  (let ((prefix (%extract-prefix ev)))
    (setf *current-prefix* prefix)
    (when (and *which-key-mode*
               (not (%prefix-empty-p prefix)))
      (funcall *timer-fn* *idle-delay*
               (lambda ()
                 ;; Skip if mode disabled or prefix changed since scheduling.
                 (when (and *which-key-mode*
                            (equal *current-prefix* prefix)
                            (not (%prefix-empty-p prefix)))
                   (funcall *echo-fn*
                            (format nil "~a" prefix))))))))

;;; ── which-key-mode toggle ────────────────────────────────────────────────

(defun which-key-mode ()
  "Enable which-key minor mode.  Idempotent."
  (setf *which-key-mode* t)
  t)

;;; ── install ──────────────────────────────────────────────────────────────

(defvar *hook-installed* nil)

(defun install ()
  "Subscribe %on-prefix-changed to event/key-prefix-changed.  Idempotent."
  (unless *hook-installed*
    (let* ((hooks-pkg (find-package '#:limn/hooks))
           (add (and hooks-pkg (find-symbol "ADD-HOOK" hooks-pkg))))
      (when (and add (fboundp add))
        (funcall (symbol-function add)
                 "event/key-prefix-changed"
                 #'%on-prefix-changed)
        (setf *hook-installed* t))))
  t)

(install)
