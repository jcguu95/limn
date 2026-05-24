;;;; repl.lisp — bring up a live limn process + drop into an SBCL prompt.
;;;;
;;;; Usage:  sbcl --load backend/repl.lisp
;;;;         (typically via backend/run-repl.sh which sets up nix env)
;;;;
;;;; Env vars:
;;;;   HEADLESS=0       open a visible Qt window (default: 1, offscreen)
;;;;   LIMN_BIN         override binary path
;;;;   LIMN_INITIAL     initial PDF/file to open on launch
;;;;   LIMN_NO_SPAWN=1  load all modules then exit cleanly — no binary needed
;;;;                    (used by smoke tests and CI)

(in-package #:cl-user)

(require :sb-posix)
(require :sb-bsd-sockets)

;;; ── locate files relative to this script ──────────────────────────────

(defparameter *backend-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil))

(defun b/ (p) (namestring (merge-pathnames p *backend-dir*)))

;;; ── v0.34: vendor cl-ppcre ────────────────────────────────────────────
;;; Loaded before backend modules so limn-regex.lisp can resolve cl-ppcre
;;; at compile time. Soft-load: missing submodule is RED for §A but does
;;; not crash repl bring-up.

(handler-case (load (b/ "../vendor/cl-ppcre-load.lisp"))
  (error (e) (format t "  !! skipped vendor cl-ppcre: ~A~%" e)))

;;; ── load all backend modules in dependency order ──────────────────────

(dolist (file '(;; v0.7-v0.22 core
                "limn-hooks.lisp"
                "limn-log.lisp"               ; v0.23
                "limn-error.lisp"             ; v0.23
                "limn-timer.lisp"             ; v0.23 — must precede which-key
                "limn-process.lisp"           ; v0.23 — must precede buffer
                "limn-buffer.lisp"
                "limn-bridge.lisp"
                "limn-undo.lisp"
                "limn-buffer-undo.lisp"       ; v0.23.1
                "limn-keys.lisp"
                "limn-search.lisp"
                "limn-client.lisp"
                "limn-dispatch.lisp"
                "limn-mode.lisp"
                "limn-cmd.lisp"
                "limn-runtime.lisp"
                "limn-introspect.lisp"
                "limn-text-mode.lisp"
                ;; v0.24 edit model
                "limn-kill.lisp"
                "limn-mark.lisp"
                "limn-register.lisp"
                "limn-kmacro.lisp"
                "limn-file.lisp"
                "limn-auto-save.lisp"
                "limn-backup.lisp"
                "limn-recentf.lisp"
                ;; v0.25 interaction
                "limn-history.lisp"
                "limn-custom.lisp"
                "limn-advice.lisp"
                "limn-face.lisp"
                "limn-text-props.lisp"
                "limn-help.lisp"
                "limn-completion.lisp"
                ;; v0.26 search UI
                "limn-isearch.lisp"
                "limn-occur.lisp"
                ;; v0.27 pdf-mode (depends on v0.25 + v0.26)
                "limn-pdf-mode.lisp"
                ;; v0.28 keymap + nav (text-nav needs kill; which-key needs timer)
                "limn-text-nav.lisp"
                "limn-map-macro.lisp"
                "limn-which-key.lisp"
                ;; v0.30 markers + buffer-local vars (foundation for v0.32)
                "limn-marker.lisp"
                "limn-local.lisp"
                ;; v0.31 syntax tables + coding systems
                "limn-syntax.lisp"
                "limn-coding.lisp"
                ;; v0.32 current-buffer / save-excursion / narrow
                "limn-excursion.lisp"
                ;; v0.34 regex engine (depends on cl-ppcre vendor + v0.32)
                "limn-regex.lisp"
                ;; bootstrap (last)
                "limn.lisp"))
  (load (b/ file)))

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
         (initial (sb-ext:posix-getenv "LIMN_INITIAL"))
         (args    (append (when (headless-p) (list "--headless"))
                          (list "--test-mode" "--socket" sock)
                          (when initial (list initial)))))
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
