;;;; limn-help — describe-* / apropos, Emacs-compatible.
;;;;
;;;; Pure Lisp. v0.25 §E.
;;;; Produces string output (callers may display in *Help* buffer).
;;;; describe-key queries limn/keys when loaded; degrades gracefully otherwise.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require 'sb-introspect))

(defpackage #:limn/help
  (:use #:cl)
  (:shadow #:apropos)                   ; shadow cl:apropos to avoid package lock
  (:export #:describe-function #:describe-variable
           #:describe-key #:describe-mode
           #:apropos #:apropos-command #:apropos-variable
           #:help-buffer-contents))

(in-package #:limn/help)

;;; Last *Help* buffer content (tests can read it via help-buffer-contents).
(defvar *last-help* "")

(defun %store (str)
  (setf *last-help* str)
  str)

;;; ─── describe-function ────────────────────────────────────────────

(defun describe-function (sym)
  (unless (fboundp sym)
    (error "~a is not a function" sym))
  (let* ((fn (fdefinition sym))
         (doc (documentation fn 'function))
         (args (when (typep fn 'function)
                 (sb-introspect:function-lambda-list fn)))
         (output (with-output-to-string (s)
                   (format s "~a" sym)
                   (when args
                     (format s " ~a" args))
                   (terpri s)
                   (if doc
                       (format s "~%~a~%" doc)
                       (format s "~%Not documented.~%")))))
    (%store output)))

;;; ─── describe-variable ────────────────────────────────────────────

(defun describe-variable (sym)
  (let* ((val (if (boundp sym) (symbol-value sym) :unbound))
         (doc (documentation sym 'variable))
         (output (with-output-to-string (s)
                   (format s "~a~%" sym)
                   (format s "  Value: ~s~%" val)
                   (if doc
                       (format s "  ~a~%" doc)
                       (format s "  Not documented.~%")))))
    (%store output)))

;;; ─── describe-key ─────────────────────────────────────────────────

(defun describe-key (keyseq)
  "Return a description string for KEYSEQ (a string like \"C-x C-f\")."
  (let ((binding (when (find-package '#:limn/keys)
                   (ignore-errors
                    (funcall (find-symbol "LOOKUP-KEY" '#:limn/keys)
                             keyseq)))))
    (%store
     (if binding
         (format nil "~a runs the command ~a" keyseq binding)
         (format nil "~a is not defined" keyseq)))))

;;; ─── describe-mode ────────────────────────────────────────────────

(defun describe-mode ()
  (let* ((major (when (find-package '#:limn/mode)
                  (ignore-errors
                   (funcall (find-symbol "CURRENT-MAJOR-MODE" '#:limn/mode)))))
         (minors (when (find-package '#:limn/mode)
                   (ignore-errors
                    (funcall (find-symbol "ACTIVE-MINOR-MODES" '#:limn/mode)))))
         (output (with-output-to-string (s)
                   (format s "Major mode: ~a~%" (or major "fundamental-mode"))
                   (when minors
                     (format s "Minor modes: ~{~a~^, ~}~%" minors)))))
    (%store output)))

;;; ─── apropos ──────────────────────────────────────────────────────

(defun %apropos-all (pattern)
  "Return all symbols in all packages matching PATTERN (regex or substring)."
  (let ((results '()))
    (do-all-symbols (sym)
      (let ((name (symbol-name sym)))
        (when (search (string-upcase pattern) (string-upcase name))
          (when (or (fboundp sym) (boundp sym))
            (pushnew sym results)))))
    (sort results #'string< :key #'symbol-name)))

(defun apropos (pattern)
  (%apropos-all pattern))

(defun apropos-command (pattern)
  "Like apropos but return only interactive commands."
  (remove-if-not
   (lambda (sym)
     (and (fboundp sym)
          (when (find-package '#:limn/cmd)
            (ignore-errors
             (funcall (find-symbol "COMMANDP" '#:limn/cmd) sym)))))
   (%apropos-all pattern)))

(defun apropos-variable (pattern)
  "Like apropos but return only bound variables."
  (remove-if-not #'boundp (%apropos-all pattern)))

;;; ─── help-buffer-contents ─────────────────────────────────────────

(defun help-buffer-contents ()
  *last-help*)
