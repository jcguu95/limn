;;;; repl.lisp — bring up a live limn process + drop into an SBCL prompt.
;;;;
;;;; Usage:  sbcl --load backend/repl.lisp
;;;;         (typically via backend/run-repl.sh which sets up nix env)
;;;;
;;;; Env vars:
;;;;   HEADLESS=0       open a visible Qt window (default: 1, offscreen)
;;;;   LIMN_BIN         override binary path
;;;;   LIMN_INITIAL     initial PDF/file to open on launch

(in-package #:cl-user)

(require :sb-posix)
(require :sb-bsd-sockets)

;;; ── locate files relative to this script ──────────────────────────────

(defparameter *backend-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil))

(defun b/ (p) (namestring (merge-pathnames p *backend-dir*)))

;;; ── load all backend modules in dependency order ──────────────────────

(dolist (file '("limn-hooks.lisp"
                "limn-buffer.lisp"
                "limn-bridge.lisp"
                "limn-keys.lisp"
                "limn-undo.lisp"
                "limn-search.lisp"
                "limn-client.lisp"
                "limn-dispatch.lisp"
                "limn-mode.lisp"
                "limn-cmd.lisp"
                "limn-runtime.lisp"
                "limn-introspect.lisp"
                "limn-text-mode.lisp"
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

(spawn-limn)
(limn:start *limn-socket-path*)

(load (b/ "repl-helpers.lisp"))
(banner)

;;; Ensure cleanup if the user just hits Ctrl-D instead of (q)
(push (lambda ()
        (handler-case (limn:stop) (error () nil))
        (when (and *limn-process*
                   (sb-ext:process-alive-p *limn-process*))
          (sb-ext:process-kill *limn-process* 15)))
      sb-ext:*exit-hooks*)
