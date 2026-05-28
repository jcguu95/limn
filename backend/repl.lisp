;;;; repl.lisp — bring up a live limn process + drop into an SBCL prompt.
;;;;
;;;; Usage:  sbcl --load backend/repl.lisp
;;;;         (typically via backend/run-repl.sh which sets up nix env)
;;;;
;;;; Env vars:
;;;;   HEADLESS=0       open a visible Qt window (default: 1, offscreen)
;;;;   LIMN_BIN         override binary path
;;;;   LIMN_NO_SPAWN=1  load all modules then exit cleanly — no binary needed
;;;;                    (used by smoke tests and CI)
;;;;
;;;; run-repl.sh forwards any extra args to sbcl AFTER this file loads,
;;;; so you can chain --eval to drive the live limn from the shell:
;;;;
;;;;   HEADLESS=0 ./backend/run-repl.sh --eval '(o "/tmp/m.pdf")'
;;;;
;;;; → launches visible Qt, opens the PDF via (o ...) (defined in
;;;;   repl-helpers.lisp), then drops to the interactive prompt.
;;;;
;;;; To open a PDF, use (o "/path/to.pdf") at the REPL prompt. The old
;;;; LIMN_INITIAL env var was removed in v0.39 because it routed through
;;;; the legacy MainWidget::open_document instead of the bridge's
;;;; buffer/open path — no buffer-opened event ever fired, so pdf-mode
;;;; was never installed for the window and j/k did nothing.

(in-package #:cl-user)

(require :sb-posix)
(require :sb-bsd-sockets)

;;; ── locate files relative to this script ──────────────────────────────

(defparameter *backend-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil))

(defun b/ (p) (namestring (merge-pathnames p *backend-dir*)))

;;; ── load all backend modules via ASDF (v0.37 A2) ─────────────────────
;;; Replaces a dolist that LOAD'd 51 .lisp files in dependency order.
;;; ASDF compiles each component to FASL in topological order, so
;;; forward references resolve at load time — no STYLE-WARNING noise
;;; from undefined functions during compile.  cl-ppcre is declared in
;;; the system's :depends-on, no manual (require :cl-ppcre) needed.
;;;
;;; FASLs cache under ASDF's user output cache (~/.cache/common-lisp/),
;;; so subsequent loads after the first compile are essentially free.

;; nix's sbcl-with-packages wrapper sets CL_SOURCE_REGISTRY to include
;; the SBCL contrib dir via a `//` recursive glob; that dir registers
;; each contrib's .asd at TWO paths (top-level + subdir/), and ASDF
;; warns about duplicates ("found several entries for sb-aclrepl ...
;; picking X over Y") — 18 warnings/process.  Harmless, not our code's
;; fault, but pure noise.  Muffle exactly that warning text; everything
;; else propagates.  Split into two handler-binds so the reader doesn't
;; choke on asdf:* symbols before asdf has loaded.
(defvar *muffle-asd-dup*
  (lambda (w)
    (let ((msg (princ-to-string w)))
      (when (and (search "found several entries" msg)
                 (search "lib/sbcl" msg))
        (muffle-warning w)))))

(handler-bind ((warning *muffle-asd-dup*))
  (require :asdf)
  (require :sb-bsd-sockets))

(handler-bind ((warning *muffle-asd-dup*))
  (push *backend-dir* asdf:*central-registry*)
  ;; Force the source-registry scan now so warnings emit INSIDE this
  ;; muffler — without it the scan is lazy and the first ASDF call
  ;; from user-code (or tests) triggers it post-muffler.
  (asdf:initialize-source-registry)
  (asdf:load-system :limn))

;;; ── spawn a limn subprocess ───────────────────────────────────────────

(defvar *limn-process*     nil)
(defvar *limn-socket-path* nil)

(defun default-limn-bin ()
  (or (sb-ext:posix-getenv "LIMN_BIN")
      (b/ "../sioyek/limn.app/Contents/MacOS/limn")
      (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek")))

(defun headless-p ()
  (let ((v (sb-ext:posix-getenv "HEADLESS")))
    (cond ((null v) t)
          ((string= v "0") nil)
          ((string= v "")  t)
          (t t))))

(defun spawn-limn ()
  ;; The 'offscreen' Qt platform still tries to drive QOpenGLWidget paint
  ;; which under recursive event hooks (key event → hook → view-set →
  ;; another paint) can disconnect the bridge socket. 'minimal' skips
  ;; painting entirely, which is fine for the REPL since we don't need
  ;; grab() here. Users who DO want grab can pass QT_QPA_PLATFORM=offscreen.
  (when (and (headless-p) (null (sb-ext:posix-getenv "QT_QPA_PLATFORM")))
    (sb-posix:setenv "QT_QPA_PLATFORM" "minimal" 1))
  (let* ((sock    (format nil "/tmp/limn-repl-~a" (sb-posix:getpid)))
         (bin     (default-limn-bin))
         (args    (append (when (headless-p) (list "--headless"))
                          (list "--test-mode" "--socket" sock))))
    (unless (probe-file bin)
      (format *error-output* "✗ limn binary not found: ~a~%" bin)
      (sb-ext:exit :code 2))
    (ignore-errors (delete-file sock))
    (setf *limn-socket-path* sock)
    (format t "→ launching ~a~%" bin)
    (format t "  args: ~{~a ~}~%" args)
    (setf *limn-process*
          (sb-ext:run-program bin args
                              :wait nil :search nil
                              :output (b/ "../limn-repl.log")
                              :if-output-exists :supersede
                              :error :output))
    (unless *limn-process*
      (format *error-output* "✗ failed to spawn limn~%")
      (sb-ext:exit :code 3))
    ;; Wait for the socket file to appear (limn binds it shortly after start).
    (loop repeat 80
          until (probe-file sock)
          do (sleep 0.05)
          finally (unless (probe-file sock)
                    (format *error-output*
                            "✗ socket ~a never appeared (limn pid ~a)~%"
                            sock (sb-ext:process-pid *limn-process*))
                    (sb-ext:exit :code 4)))
    sock))

;;; ── connect & install REPL helpers ────────────────────────────────────

(unless (string= (or (sb-ext:posix-getenv "LIMN_NO_SPAWN") "") "1")
  (spawn-limn)
  (limn:start *limn-socket-path*)
  (load (b/ "repl-helpers.lisp"))
  (banner)
  ;; Ensure cleanup if the user just hits Ctrl-D instead of (q)
  (push (lambda ()
          (handler-case (limn:stop) (error () nil))
          (when (and *limn-process*
                     (sb-ext:process-alive-p *limn-process*))
            (sb-ext:process-kill *limn-process* 15)))
        sb-ext:*exit-hooks*))
