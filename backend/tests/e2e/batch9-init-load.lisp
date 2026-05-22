;;;; End-to-end test of batch 9: init.lisp auto-load.
;;;;
;;;; Verifies that load-init-file actually runs when limn:start is
;;;; called, by writing a real /tmp/.limn/init.lisp with three
;;;; independent observable side effects:
;;;;
;;;;   1. cl-user::*init-marker* gets bound to :loaded
;;;;   2. a defcommand named MARKER-CMD-7Q9 lands in the registry
;;;;   3. a line is written to /tmp/limn-init-marker.log
;;;;
;;;; We check all three are NIL before limn:start and T after — proving
;;;; it's start, not module load, that triggers the side effects.
;;;;
;;;; Exits 0 on pass, 1 on fail.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      "/Users/jin/data/local/projects/sioyek-core/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defparameter *init-path*    "/tmp/.limn/init.lisp")
(defparameter *init-log*     "/tmp/limn-init-marker.log")
(defparameter *init-stash*   "/tmp/.limn/init.lisp.e2e-stash")

;;; ── fixture: install our marker init, stashing any existing one ──

(ensure-directories-exist "/tmp/.limn/")
(when (probe-file *init-path*)
  (rename-file *init-path* *init-stash*))
(with-open-file (s *init-path* :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create)
  (format s "~a"
          ";;; e2e fixture — observable side effects
(defparameter cl-user::*init-marker* :loaded)
(limn/cmd:defcommand marker-cmd-7q9 ()
  (lambda () \"marker-cmd-7q9 was here\"))
(with-open-file (s \"/tmp/limn-init-marker.log\"
                   :direction :output :if-exists :supersede
                   :if-does-not-exist :create)
  (format s \"init loaded at ~~a~~%\" (get-universal-time)))"))

(ignore-errors (delete-file *init-log*))

;;; ── load modules MANUALLY (don't trigger repl.lisp's auto-start) ──

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn.lisp"))
  (load (b/ f)))

(defun snapshot ()
  (list :marker (and (boundp 'cl-user::*init-marker*)
                     (symbol-value 'cl-user::*init-marker*))
        :cmd    (not (null (limn/cmd:find-command 'marker-cmd-7q9)))
        :log    (not (null (probe-file *init-log*)))))

(format t "~%── PHASE 1: modules loaded, limn:start NOT yet called ──~%")
(let ((p1 (snapshot)))
  (format t "  ~a~%" p1)

  ;; PHASE 2: real session
  (format t "~%── PHASE 2: spawning limn + limn:start ──~%")
  (sb-posix:setenv "QT_QPA_PLATFORM" "minimal" 1)
  (let* ((sock (format nil "/tmp/limn-e2e-init-~a" (sb-posix:getpid)))
         (proc (sb-ext:run-program
                (b/ "../sioyek/limn.app/Contents/MacOS/limn")
                (list "--headless" "--test-mode" "--socket" sock)
                :wait nil :search nil
                :output "/tmp/limn-e2e-init.log"
                :if-output-exists :supersede
                :error :output)))
    (loop repeat 100 until (probe-file sock) do (sleep 0.05))
    (limn:start sock)

    (let ((p2 (snapshot)))
      (format t "  ~a~%" p2)
      (let ((ok (and (null (getf p1 :marker)) (not (getf p1 :cmd))
                     (not (getf p1 :log))
                     (eq :loaded (getf p2 :marker))
                     (getf p2 :cmd) (getf p2 :log))))
        (format t "~%── VERDICT: ~a ──~%"
                (if ok "✓ PASS" "✗ FAIL"))
        (limn:stop)
        (handler-case (sb-ext:process-kill proc 15) (error () nil))
        ;; restore any stashed init
        (ignore-errors (delete-file *init-path*))
        (when (probe-file *init-stash*)
          (rename-file *init-stash* *init-path*))
        (sb-ext:exit :code (if ok 0 1))))))
