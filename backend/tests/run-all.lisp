;;;; Limn Test Runner
;;;;
;;;; Loads framework + all suites, then runs them.
;;;;
;;;; Usage from project root:
;;;;   sbcl --script backend/tests/run-all.lisp
;;;;
;;;; Environment variables:
;;;;   LIMN_SOCKET   socket path  (default: /tmp/limn-test)
;;;;   LIMN_FIXTURE  PDF fixture  (default: backend/tests/fixtures/test.pdf)
;;;;   LIMN_VERBOSE  if set, log every wire message

(in-package #:cl-user)

(require 'sb-bsd-sockets)
;; limn-runtime uses sb-posix:getenv; load before ASDF compiles it.
(require :sb-posix)

;;; Resolve paths relative to this file
(defparameter *test-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil))

(defun rel (relpath)
  (namestring (merge-pathnames relpath *test-dir*)))

;;; v0.37 G6: load backend via ASDF, same as run-unit.lisp / e2e drivers
;;; (Phase F #B1).  Without this, individual suite files' ad-hoc
;;; `(load "limn-regex.lisp")` etc. fail at READ time when cl-ppcre
;;; isn't yet required — suite handler-case swallows it silently,
;;; later the suite's tests fail with "function LIMN/REGEX:* is
;;; undefined" without any indication WHY.  ASDF brings cl-ppcre +
;;; every limn/* package up cleanly before any suite is read.
(defvar *muffle-asd-dup*
  (lambda (w)
    (let ((msg (princ-to-string w)))
      (when (and (search "found several entries" msg)
                 (search "lib/sbcl" msg))
        (muffle-warning w)))))

(handler-bind ((warning *muffle-asd-dup*))
  (require :asdf))

(handler-bind ((warning *muffle-asd-dup*))
  (let ((backend-dir (namestring (merge-pathnames "../" *test-dir*))))
    (push backend-dir asdf:*central-registry*))
  (asdf:initialize-source-registry)
  (asdf:load-system :limn))

;;; Load framework first
(load (rel "framework.lisp"))

(in-package #:limn/test)

;;; Apply env overrides BEFORE loading test files (so *fixture-pdf* etc. resolve)
(let ((sock (sb-ext:posix-getenv "LIMN_SOCKET"))
      (fixture (sb-ext:posix-getenv "LIMN_FIXTURE"))
      (verbose (sb-ext:posix-getenv "LIMN_VERBOSE")))
  (when sock (setf *socket-path* sock))
  (when fixture (setf *fixture-pdf* fixture))
  (when verbose (setf *verbose* t)))

;;; Load all suites (order matters for the *tests* list — smoke first)
(in-package #:cl-user)

(dolist (suite '("suites/smoke.lisp"
                 "suites/protocol.lisp"
                 "suites/bridge.lisp"
                 "suites/view.lisp"
                 "suites/overlays.lisp"
                 "suites/overlays-paint.lisp"
                 "suites/per-window.lisp"
                 "suites/cjk.lisp"
                 "suites/bookmark.lisp"
                 "suites/frame-v018.lisp"
                 "suites/frame-routing.lisp"
                 "suites/buffer.lisp"
                 "suites/events.lisp"
                 "suites/test-mode.lisp"
                 "suites/engine-spec.lisp"
                 "suites/mupdf-engine.lisp"
                 "suites/integration.lisp"
                 "suites/stress.lisp"
                 "suites/visual.lisp"
                 "suites/paint.lisp"
                 "suites/text-engine.lisp"
                 "suites/chrome.lisp"
                 "suites/minibuffer.lisp"
                 "suites/buffer-edit.lisp"
                 "suites/buffer-undo-wire.lisp"
                 "suites/gap-buffer.lisp"
                 "suites/text-engine-v022.lisp"
                 "suites/mouse-coord.lisp"
                 "suites/robust.lisp"
                 "suites/lifecycle.lisp"
                 "suites/i18n.lisp"
                 "suites/async.lisp"
                 ;; v0.25 face/theme
                 "suites/defface-v025.lisp"
                 ;; v0.27 pdf-mode
                 "suites/pdf-mode-v027.lisp"
                 ;; v0.30 markers + buffer-local (wire round-trip)
                 "suites/marker-v030.lisp"
                 ;; v0.31 syntax tables + coding systems (wire round-trip)
                 "suites/syntax-coding-v031.lisp"
                 ;; v0.32 current-buffer / save-excursion / narrow
                 "suites/excursion-v032.lisp"
                 ;; v0.33 視覺系統：overlays + face wire + region
                 "suites/overlays-v033.lisp"
                 ;; v0.33b: buffer/codepoint-rects + text-range layer
                 "suites/overlays-v033b.lisp"
                 ;; v0.34 regex engine (cl-ppcre + Emacs-style API)
                 "suites/regex-v034.lisp"
                 ;; v0.35 file-notify + auto-revert + process-coding
                 "suites/file-notify-v035.lisp"
                 ;; v0.36 indent + query-replace (wire round-trip)
                 "suites/indent-v036.lisp"
                 "suites/query-replace-v036.lisp"))
  (let ((path (rel suite)))
    (format t "[loading] ~a~%" suite)
    (handler-case (load path)
      (error (e)
        (format t "  !! failed to load ~a: ~a~%" suite e)))))

(in-package #:limn/test)

(format t "~%Connecting to ~a~%" *socket-path*)
(format t "Using fixture: ~a~%~%" *fixture-pdf*)

(let ((ok (run-suite)))
  (sb-ext:exit :code (if ok 0 1)))
