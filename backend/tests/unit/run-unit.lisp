;;;; Pure-Lisp unit test runner
;;;;
;;;; Runs all tests in backend/tests/unit/ without needing a running Limn.
;;;; Tests target the backend modules (limn-keys, limn-undo, etc.) — most
;;;; will fail until those modules are implemented. That's TDD by design.
;;;;
;;;; Usage:
;;;;   sbcl --script backend/tests/unit/run-unit.lisp

(in-package #:cl-user)

;; limn-runtime uses sb-posix:getenv for init-file lookup; load before
;; importing it. (The integration runner gets this via repl.lisp.)
(require :sb-posix)

(defparameter *unit-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil))

(defun rel (p)
  (namestring (merge-pathnames p *unit-dir*)))

;; Framework
(load (rel "unit-framework.lisp"))

;; Backend implementation modules (loaded BEFORE tests so the unit-test
;; package-stubs are replaced by real packages).
(dolist (impl '("limn-hooks.lisp"
                "limn-buffer.lisp"
                "limn-bridge.lisp"
                "limn-undo.lisp"
                "limn-keys.lisp"
                "limn-search.lisp"
                "limn-client.lisp"
                "limn-dispatch.lisp"
                "limn-mode.lisp"
                "limn-cmd.lisp"
                "limn-runtime.lisp"
                "limn-introspect.lisp"))
  (let ((p (namestring (merge-pathnames (concatenate 'string "../../" impl)
                                         *unit-dir*))))
    (format t "[loading impl] ~a~%" impl)
    (handler-case (load p)
      (error (e) (format t "  !! ~a: ~a~%" impl e)))))

;; All unit-test files
(dolist (file '("bridge-client.lisp"
                "keymap.lisp"
                "keymap-v019.lisp"
                "undo.lisp"
                "hooks.lisp"
                "buffer-registry.lisp"
                "search.lisp"
                "dispatch.lisp"
                "mode.lisp"
                "defcommand.lisp"
                "runtime.lisp"
                "minibuffer-read.lisp"
                "keyboard-quit.lisp"
                "init-load.lisp"
                "introspect.lisp"))
  (format t "[loading unit] ~a~%" file)
  (handler-case (load (rel file))
    (error (e) (format t "  !! ~a: ~a~%" file e))))

(in-package #:limn/unit-test)

(let ((ok (run-suite)))
  (sb-ext:exit :code (if ok 0 1)))
