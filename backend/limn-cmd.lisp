;;;; limn-cmd — defcommand + interactive spec (skeleton).
;;;;
;;;; SPEC §9.2: every command declares the input it needs via an
;;;; interactive spec. The framework auto-prompts (via minibuffer) and
;;;; routes the result to the command's body.
;;;;
;;;; Spec chars (Emacs convention):
;;;;   s   string from minibuffer
;;;;   f   file path (minibuffer with completion, future)
;;;;   p   numeric prefix arg (e.g. the "5" in "5g")
;;;;   r   region (future)
;;;;
;;;; Skeleton: package + signatures so the unit tests in
;;;; backend/tests/unit/defcommand.lisp can load. Each call signals
;;;; unimplemented until v0.7 lands.

(defpackage #:limn/cmd
  (:use #:cl)
  (:export #:defcommand #:find-command #:call-interactively
           #:command-name #:command-spec #:command-mode #:command-body))

(in-package #:limn/cmd)

(define-condition unimplemented (error)
  ((symbol-name :initarg :symbol-name :reader unimplemented-symbol-name))
  (:report (lambda (c s)
             (format s "limn/cmd:~a is not yet implemented (v0.7 work)"
                     (unimplemented-symbol-name c)))))

(defun %todo (name) (error 'unimplemented :symbol-name name))

(defmacro defcommand (name (&key interactive mode) &body body)
  (declare (ignore name interactive mode body))
  `(error "limn/cmd:defcommand is not yet implemented (v0.7 work)"))

(defun find-command       (name)       (declare (ignore name)) (%todo 'find-command))
(defun call-interactively (name)       (declare (ignore name)) (%todo 'call-interactively))
(defun command-name       (c)          (declare (ignore c))    (%todo 'command-name))
(defun command-spec       (c)          (declare (ignore c))    (%todo 'command-spec))
(defun command-mode       (c)          (declare (ignore c))    (%todo 'command-mode))
(defun command-body       (c)          (declare (ignore c))    (%todo 'command-body))
