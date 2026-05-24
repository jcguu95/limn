;;;; vendor/cl-ppcre-load.lisp
;;;;
;;;; Bare-bones serial loader for cl-ppcre — avoids ASDF / Quicklisp setup.
;;;; Mirrors the :components list in cl-ppcre.asd in load order.
;;;;
;;;; Lives at vendor/cl-ppcre-load.lisp (NOT inside the submodule) so it's
;;;; tracked by the super-repo. The cl-ppcre sources live in the sibling
;;;; vendor/cl-ppcre/ submodule.
;;;;
;;;; Usage:
;;;;   (load "vendor/cl-ppcre-load.lisp")
;;;; → :cl-ppcre package is interned with SCAN / ALL-MATCHES / REGEX-REPLACE
;;;; etc. exported.

(in-package #:cl-user)

(defparameter *cl-ppcre-dir*
  (merge-pathnames "cl-ppcre/"
                   (make-pathname :defaults (or *load-pathname*
                                                  *default-pathname-defaults*)
                                  :name nil :type nil))
  "Directory containing the cl-ppcre sources (the submodule's workdir).")

(defun %ppcre/ (name)
  (namestring (merge-pathnames (concatenate 'string name ".lisp")
                                *cl-ppcre-dir*)))

;; Skip if already loaded (idempotent).
(unless (find-package '#:cl-ppcre)
  (dolist (f '("packages"
               "specials"
               "util"
               "errors"
               "charset"
               "charmap"
               "chartest"
               "lexer"
               "parser"
               "regex-class"
               "regex-class-util"
               "convert"
               "optimize"
               "closures"
               "repetition-closures"
               "scanner"
               "api"))
    (load (%ppcre/ f))))
