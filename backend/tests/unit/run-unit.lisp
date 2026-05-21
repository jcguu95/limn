;;;; Pure-Lisp unit test runner
;;;;
;;;; Runs all tests in backend/tests/unit/ without needing a running Limn.
;;;; Tests target the backend modules (limn-keys, limn-undo, etc.) — most
;;;; will fail until those modules are implemented. That's TDD by design.
;;;;
;;;; Usage:
;;;;   sbcl --script backend/tests/unit/run-unit.lisp

(in-package #:cl-user)

(defparameter *unit-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil))

(defun rel (p)
  (namestring (merge-pathnames p *unit-dir*)))

;; Framework
(load (rel "unit-framework.lisp"))

;; All unit-test files
(dolist (file '("bridge-client.lisp"
                "keymap.lisp"
                "undo.lisp"
                "hooks.lisp"
                "buffer-registry.lisp"
                "search.lisp"))
  (format t "[loading unit] ~a~%" file)
  (handler-case (load (rel file))
    (error (e) (format t "  !! ~a: ~a~%" file e))))

(in-package #:limn/unit-test)

(let ((ok (run-suite)))
  (sb-ext:exit :code (if ok 0 1)))
