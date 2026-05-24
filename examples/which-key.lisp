;;;; examples/which-key.lisp — dogfood v0.19 β *key-prefix* + hook.
;;;;
;;;; When the user types a multi-key prefix (like "C-x"), this displays
;;;; the next-key candidates via message/echo. Exactly the popcorn-popup
;;;; behaviour Emacs's which-key.el offers, in ~30 lines of user-land
;;;; Lisp — proving the v0.19 primitive is enough.
;;;;
;;;; Usage (in ~/.limn/init.lisp or via sbcl --script after limn:start):
;;;;
;;;;   (load "examples/which-key.lisp")
;;;;   (limn.examples.which-key:enable!)
;;;;
;;;; Then type a prefix like C-x — message area shows "C-x: f s c-s".

(defpackage #:limn.examples.which-key
  (:use #:cl)
  (:export #:enable! #:disable! #:format-candidates))

(in-package #:limn.examples.which-key)

(defun format-candidates (prefix-keys)
  "Given the current prefix sequence (list of key strings), look up
   that prefix in the current frame's keymap stack and format the
   sub-keymap's bindings as 'C-x: f s c-s' style."
  (let* ((session (and (find-package :limn)
                       (symbol-value (find-symbol "*SESSION*" :limn)))))
    (unless (and prefix-keys session) (return-from format-candidates nil))
    ;; Look in the global keymap for the prefix → sub-keymap.
    (let* ((gkm (symbol-value (find-symbol "*GLOBAL-KEYMAP*" :limn/mode)))
           (lookup-seq (find-symbol "LOOKUP-SEQUENCE" :limn/keys))
           (describe   (find-symbol "DESCRIBE-BINDINGS" :limn/keys))
           (sub (and gkm lookup-seq (funcall lookup-seq gkm prefix-keys))))
      (cond
        ((and sub (funcall (find-symbol "KEYMAP-P" :limn/keys) sub))
         (let* ((bindings (funcall describe sub))
                (keys (mapcar #'car bindings)))
           (format nil "~{~a~^ ~}: ~{~a~^ ~}" prefix-keys keys)))
        (t nil)))))

(defun on-key-prefix-changed (info)
  "Hook handler — render which-key panel when prefix is non-empty."
  (let* ((new  (getf info :|new|))
         (text (and new (format-candidates new))))
    (when text
      (let ((call (and (find-package :limn/dispatch)
                       (find-symbol "CALL" :limn/dispatch)))
            (session (symbol-value (find-symbol "*SESSION*" :limn))))
        (when (and call session)
          (handler-case
              (funcall call session "message/echo" :|text| text)
            (error () nil)))))))

(defun enable! ()
  (let ((add (find-symbol "ADD-HOOK" :limn/hooks)))
    (when add
      (funcall add "event/key-prefix-changed" #'on-key-prefix-changed))
    (format t "which-key enabled. Try pressing a prefix key.~%")))

(defun disable! ()
  (let ((rem (find-symbol "REMOVE-HOOK" :limn/hooks)))
    (when rem
      (funcall rem "event/key-prefix-changed" #'on-key-prefix-changed))
    (format t "which-key disabled.~%")))

;;; Self-test (loaded standalone, no limn session needed): format-
;;; candidates with no global keymap returns nil gracefully.
(when (member "--self-test" sb-ext:*posix-argv* :test #'string=)
  (assert (null (format-candidates '("C-x"))))
  (format t "which-key self-test ok~%"))
