;;;; examples/cjk-ime-demo.lisp — dogfood v0.16.0/.1 IME pipeline.
;;;;
;;;; Observes ime-preedit / ime-commit events and prints what the IME
;;;; is currently composing. Useful for debugging your fcitx / OS IME
;;;; setup OR for building a custom preedit overlay in user-land.
;;;;
;;;; Usage:
;;;;   (load "examples/cjk-ime-demo.lisp")
;;;;   (limn.examples.cjk-ime:enable!)
;;;;   ;; now open a minibuffer, switch to IM, type — see preedit
;;;;   ;; lines in stdout / stderr.

(defpackage #:limn.examples.cjk-ime
  (:use #:cl)
  (:export #:enable! #:disable! #:format-state))

(in-package #:limn.examples.cjk-ime)

(defvar *current-preedit* "")
(defvar *last-commit*     "")
(defvar *log-stream*      *standard-output*)

(defun format-state ()
  (format nil "[ime preedit=~s last-commit=~s]"
          *current-preedit* *last-commit*))

(defun on-preedit (ev)
  (let ((text (getf ev :|text|)))
    (setf *current-preedit* (or text ""))
    (format *log-stream* "~a ime-preedit: ~s~%"
            (format-state) text)
    (force-output *log-stream*)))

(defun on-commit (ev)
  (let ((text (getf ev :|text|)))
    (setf *last-commit*     (or text "")
          *current-preedit* "")   ; commit clears in-progress preedit
    (format *log-stream* "~a ime-commit: ~s → minibuffer~%"
            (format-state) text)
    (force-output *log-stream*)))

(defun enable! (&key (stream *standard-output*))
  (setf *log-stream* stream)
  (let ((add (find-symbol "ADD-HOOK" :limn/hooks)))
    (when add
      (funcall add "event/ime-preedit" #'on-preedit)
      (funcall add "event/ime-commit"  #'on-commit)))
  (format t "cjk-ime demo: subscribing to ime-preedit / ime-commit.~%~
             Open minibuffer and switch to your IM (Ctrl+Space or ~
             Cmd+Space on macOS).~%"))

(defun disable! ()
  (let ((rem (find-symbol "REMOVE-HOOK" :limn/hooks)))
    (when rem
      (funcall rem "event/ime-preedit" #'on-preedit)
      (funcall rem "event/ime-commit"  #'on-commit))))

;;; Self-test: format-state works statically.
(when (member "--self-test" sb-ext:*posix-argv* :test #'string=)
  (setf *current-preedit* "に" *last-commit* "日本")
  (assert (search "preedit=\"に\"" (format-state))
          "preedit visible in state string")
  (assert (search "last-commit=\"日本\"" (format-state))
          "commit visible in state string")
  (format t "cjk-ime-demo self-test ok~%"))
