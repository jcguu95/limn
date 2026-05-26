;;;; load-limn-system.lisp — bring up the full Limn backend via ASDF.
;;;;
;;;; v0.37 Phase F (driver-B1): used by OS-tier drivers that previously
;;;; rolled their own `(dolist (f '(...)) (load (b/ f)))` bring-up.  Those
;;;; per-driver load lists rotted: every time a new module (e.g. v0.27
;;;; limn-pdf-mode, v0.28 limn-which-key / limn-map-macro, v0.34 limn-regex
;;;; → cl-ppcre) was added, every driver had to be updated by hand or it
;;;; would crash with "Package LIMN/XYZ does not exist" at READ time.
;;;;
;;;; This file replaces that pattern with the same ASDF bring-up that
;;;; backend/repl.lisp uses in production — single source of truth.
;;;;
;;;; Usage from a driver:
;;;;
;;;;   (in-package :cl-user)
;;;;   (require :sb-posix)
;;;;   (defparameter *bdir*
;;;;     (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
;;;;   (load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))
;;;;
;;;;   ;; LIMN, LIMN/*, CL-PPCRE, SB-BSD-SOCKETS now all resolvable at READ
;;;;   ;; time, so subsequent defuns can reference limn:start etc. directly.

(in-package :cl-user)

(require :asdf)
(require :sb-bsd-sockets)

;; nix's sbcl-with-packages wrapper sets CL_SOURCE_REGISTRY with a `//`
;; recursive glob that registers each contrib's .asd at two paths.  ASDF
;; warns about the duplicates ("found several entries for sb-aclrepl
;; ... picking X over Y") — 18 warnings/process.  Same muffler as
;; backend/repl.lisp uses.
(defvar *load-limn-muffle*
  (lambda (w)
    (let ((m (princ-to-string w)))
      (when (and (search "found several entries" m)
                 (search "lib/sbcl" m))
        (muffle-warning w)))))

(handler-bind ((warning *load-limn-muffle*))
  (pushnew (truename cl-user::*bdir*)
           asdf:*central-registry*
           :test #'equal)
  (asdf:initialize-source-registry)
  (asdf:load-system :limn))
