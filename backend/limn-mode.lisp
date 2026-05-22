;;;; limn-mode — Mode system (skeleton, will be implemented in v0.7).
;;;;
;;;; Mode 是 Backend 端的物件，per SPEC §1.1 + §9.1:
;;;;   - 名稱 (symbol or string)
;;;;   - type:  :major | :minor
;;;;   - keymap (optional parent)
;;;;   - :on-enter / :on-exit hooks
;;;;   - :modeline-name
;;;;
;;;; Buffers carry: one major mode, ordered list of minors.
;;;; Keymap lookup walks minors (newest-first) → major → global.
;;;;
;;;; This file is presently a SKELETON: package + signatures exist so unit
;;;; tests can load, but every function signals an "unimplemented" error.
;;;; The tests in backend/tests/unit/mode.lisp pin the contract — they
;;;; will all be red until each function gets a real body.

(defpackage #:limn/mode
  (:use #:cl)
  (:export #:define-mode #:find-mode #:list-modes
           #:make-mode-buffer
           #:major-mode #:minor-modes
           #:activate #:deactivate
           #:lookup-key
           #:mode-keymap #:mode-name #:mode-type #:mode-modeline-name))

(in-package #:limn/mode)

(define-condition unimplemented (error)
  ((symbol-name :initarg :symbol-name :reader unimplemented-symbol-name))
  (:report (lambda (c s)
             (format s "limn/mode:~a is not yet implemented (v0.7 work)"
                     (unimplemented-symbol-name c)))))

(defun %todo (name) (error 'unimplemented :symbol-name name))

(defun define-mode      (name &key type parent modeline on-enter on-exit)
  (declare (ignore name type parent modeline on-enter on-exit))
  (%todo 'define-mode))
(defun find-mode        (name) (declare (ignore name)) (%todo 'find-mode))
(defun list-modes       ()                              (%todo 'list-modes))
(defun make-mode-buffer ()                              (%todo 'make-mode-buffer))
(defun major-mode       (buf) (declare (ignore buf))    (%todo 'major-mode))
(defun minor-modes      (buf) (declare (ignore buf))    (%todo 'minor-modes))
(defun activate         (buf mode) (declare (ignore buf mode)) (%todo 'activate))
(defun deactivate       (buf mode) (declare (ignore buf mode)) (%todo 'deactivate))
(defun lookup-key       (buf spec) (declare (ignore buf spec)) (%todo 'lookup-key))
(defun mode-keymap        (m) (declare (ignore m)) (%todo 'mode-keymap))
(defun mode-name          (m) (declare (ignore m)) (%todo 'mode-name))
(defun mode-type          (m) (declare (ignore m)) (%todo 'mode-type))
(defun mode-modeline-name (m) (declare (ignore m)) (%todo 'mode-modeline-name))
