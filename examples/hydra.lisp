;;;; examples/hydra.lisp — dogfood v0.19 β set-transient-map.
;;;;
;;;; Implements a tiny version of Emacs's hydra: bind a "stem" key
;;;; (e.g. C-c +) that activates a transient keymap; while active,
;;;; single-letter keys repeat the operation until ESC / q exits.
;;;;
;;;; Usage:
;;;;   (load "examples/hydra.lisp")
;;;;   (limn.examples.hydra:defhydra zoom-cycle
;;;;     "+" 'zoom-in
;;;;     "-" 'zoom-out
;;;;     "0" 'zoom-reset)
;;;;   (limn:bind "C-c z" (limn.examples.hydra:hydra-launcher 'zoom-cycle))
;;;;
;;;; Now: C-c z → zoom hydra active → +/-/0 repeat without re-pressing
;;;;       C-c z, ESC or q exits.

(defpackage #:limn.examples.hydra
  (:use #:cl)
  (:export #:defhydra #:hydra-launcher #:*hydras*))

(in-package #:limn.examples.hydra)

(defvar *hydras* (make-hash-table :test #'eq)
  "Registry: hydra-name symbol → built keymap.")

(defmacro defhydra (name &body key-action-pairs)
  "Build a transient keymap binding each (key action) pair.
   q and ESC always exit (no binding → user can clear via :on-exit).
   Plus chain: every bound action re-installs the keymap so the
   hydra persists across multiple keystrokes (the 'hydra' behavior)."
  (let ((km (gensym "KM"))
        (km-sym (gensym "KMSYM")))
    `(let ((,km   (limn/keys:make-keymap))
           (,km-sym (intern (string ',name) :limn.examples.hydra)))
       ,@(loop for (k action) on key-action-pairs by #'cddr
               collect `(limn/keys:define-key
                          ,km ,k
                          (lambda (ev)
                            (declare (ignore ev))
                            ;; run the user action
                            (when (fboundp ',action) (funcall ',action))
                            ;; reinstall self so next keystroke also fires
                            (limn/keys:set-transient-map
                              (gethash ',name *hydras*)))))
       (setf (gethash ',name *hydras*) ,km)
       ',name)))

(defun hydra-launcher (hydra-name)
  "Return a thunk suitable for binding (e.g. via limn:bind) that, when
   invoked, activates the named hydra as the current transient keymap."
  (lambda (ev)
    (declare (ignore ev))
    (let ((km (gethash hydra-name *hydras*)))
      (when km
        (limn/keys:set-transient-map
          km
          :on-exit (lambda ()
                     (format t "hydra ~a exited~%" hydra-name)))))))

;;; Self-test (no session required).
(when (member "--self-test" sb-ext:*posix-argv* :test #'string=)
  ;; Define a hydra
  (defun test-up () (format t "up~%"))
  (defun test-dn () (format t "dn~%"))
  (defhydra h-test "j" test-dn "k" test-up)
  (assert (gethash 'h-test *hydras*) () "hydra registered")
  (let ((km (gethash 'h-test *hydras*)))
    (assert (limn/keys:lookup km "j") () "j bound")
    (assert (limn/keys:lookup km "k") () "k bound"))
  ;; Launcher returns a thunk
  (assert (functionp (hydra-launcher 'h-test)) "launcher is fn")
  (format t "hydra self-test ok~%"))
