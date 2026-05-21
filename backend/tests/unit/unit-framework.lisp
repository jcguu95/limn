;;;; Pure-Lisp Unit Test Framework
;;;;
;;;; A lightweight framework for tests that don't need a running Limn process.
;;;; Used for testing pure-logic modules: keymap, undo-tree, hooks, etc.
;;;;
;;;; Separate package from limn/test so we can run unit tests without setting
;;;; up the socket framework.

(defpackage #:limn/unit-test
  (:use #:cl)
  (:export #:deftest #:run-suite
           #:assert-equal #:assert-true #:assert-false
           #:assert-eq #:assert-eql #:assert-type
           #:assert-error #:assert-no-error
           #:check
           #:*pass* #:*fail*))

(in-package #:limn/unit-test)

(defvar *pass* 0)
(defvar *fail* 0)
(defvar *errors* '())
(defvar *current* nil)
(defvar *tests* '())

(defun check (ok msg &optional fmt &rest args)
  (if ok
      (progn (incf *pass*)
             (format t "  ✓ ~a~%" msg))
      (progn (incf *fail*)
             (push (cons *current* msg) *errors*)
             (format t "  ✗ ~a~%" msg)
             (when fmt
               (format t "      → ~?~%" fmt args)))))

(defmacro assert-equal (expected actual &optional msg)
  (let ((e (gensym)) (a (gensym)))
    `(let ((,e ,expected) (,a ,actual))
       (check (equal ,e ,a) (or ,msg (format nil "~s = ~s" ',actual ',expected))
              "expected ~s, got ~s" ,e ,a))))

(defmacro assert-eq (expected actual &optional msg)
  (let ((e (gensym)) (a (gensym)))
    `(let ((,e ,expected) (,a ,actual))
       (check (eq ,e ,a) (or ,msg (format nil "(eq ~s ~s)" ',actual ',expected))
              "got ~s vs ~s" ,a ,e))))

(defmacro assert-eql (expected actual &optional msg)
  (let ((e (gensym)) (a (gensym)))
    `(let ((,e ,expected) (,a ,actual))
       (check (eql ,e ,a) (or ,msg (format nil "(eql ~s ~s)" ',actual ',expected))
              "got ~s vs ~s" ,a ,e))))

(defmacro assert-true (form &optional msg)
  (let ((v (gensym)))
    `(let ((,v ,form))
       (check ,v (or ,msg (format nil "~s is true" ',form))
              "got ~s" ,v))))

(defmacro assert-false (form &optional msg)
  (let ((v (gensym)))
    `(let ((,v ,form))
       (check (not ,v) (or ,msg (format nil "~s is false" ',form))
              "got ~s" ,v))))

(defmacro assert-type (value type &optional msg)
  (let ((v (gensym)))
    `(let ((,v ,value))
       (check (typep ,v ',type)
              (or ,msg (format nil "~s : ~s" ',value ',type))
              "got ~s of type ~s" ,v (type-of ,v)))))

(defmacro assert-error (error-type form &optional msg)
  `(check (handler-case (progn ,form nil)
            (,error-type () t)
            (error (e)
              (format t "      → expected ~s, got ~s~%" ',error-type (type-of e))
              nil))
          (or ,msg (format nil "~s signals ~s" ',form ',error-type))))

(defmacro assert-no-error (form &optional msg)
  `(check (handler-case (progn ,form t)
            (error (e) (format t "      → unexpected error: ~a~%" e) nil))
          (or ,msg (format nil "~s does not signal" ',form))))

(defmacro deftest (name &body body)
  `(progn
     (defun ,name ()
       (let ((*current* ',name)
             (p0 *pass*) (f0 *fail*))
         (format t "~%┌─ ~a~%" ',name)
         (handler-case (progn ,@body)
           (error (e)
             (incf *fail*)
             (push (cons ',name (format nil "ERROR: ~a" e)) *errors*)
             (format t "  ✗ test threw: ~a~%" e)))
         (format t "└─ ~a passed, ~a failed~%" (- *pass* p0) (- *fail* f0))))
     (pushnew ',name *tests*)))

(defun run-suite (&optional (tests (reverse *tests*)))
  (setf *pass* 0 *fail* 0 *errors* '())
  (dolist (test tests)
    (funcall test))
  (format t "~%━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
  (format t "  ~a passed, ~a failed (~a total)~%"
          *pass* *fail* (+ *pass* *fail*))
  (when *errors*
    (format t "~%  Failures:~%")
    (dolist (e (reverse *errors*))
      (format t "    [~a] ~a~%" (car e) (cdr e))))
  (format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
  (zerop *fail*))
