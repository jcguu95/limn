;;;; End-to-end test of batch 8: C-g cancels an in-flight defcommand "s".
;;;;
;;;; Drives the FULL chain using Qt-level key injection:
;;;;
;;;;   inject 'z'         → %dispatch-key → binding lambda →
;;;;     call-interactively 'cg-test-cmd (:interactive "sCG-PROMPT: ") →
;;;;       reader: minibuffer/open + dynamic-bind canceller + wait-for-event
;;;;   inject C-g         → %dispatch-key → keyboard-quit →
;;;;     funcall canceller → submitted := :cancel → wait unblocks
;;;;     unwind-protect → minibuffer/close
;;;;     signal MINIBUFFER-CANCELLED
;;;;   binding's handler-case catches → *cg-result* := :cancelled
;;;;
;;;; Verifies: minibuffer is closed AND *cg-result* = :cancelled.
;;;;
;;;; Qt-level only — does NOT exercise macOS HID → AppKit → QApplication.
;;;; For OS-level testing see batch8-cg-os.lisp (gated on Accessibility).

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      "/Users/jin/data/local/projects/sioyek-core/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defparameter *init-path*  "/tmp/.limn/init.lisp")
(defparameter *init-stash* "/tmp/.limn/init.lisp.e2e-stash8")

;; Stash any /tmp/.limn/init.lisp so it doesn't redefine our test command.
(when (probe-file *init-path*)
  (rename-file *init-path* *init-stash*))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter cl-user::*cg-result* :pending
  "Set by the trigger-key binding's handler-case — proof the cancel
   propagated all the way up.")

(sb-posix:setenv "QT_QPA_PLATFORM" "minimal" 1)

(let* ((sock (format nil "/tmp/limn-e2e-cg-~a" (sb-posix:getpid)))
       (proc (sb-ext:run-program
              (b/ "../sioyek/limn.app/Contents/MacOS/limn")
              (list "--headless" "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-e2e-cg.log"
              :if-output-exists :supersede
              :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)

  (limn/cmd:defcommand cg-test-cmd (:interactive "sCG-PROMPT: ")
    (lambda (s) (format nil "got: ~a" s)))

  (limn:bind "z"
             (lambda (ev)
               (declare (ignore ev))
               (handler-case
                   (setf cl-user::*cg-result*
                         (limn/cmd:call-interactively 'cg-test-cmd))
                 (limn/runtime:minibuffer-cancelled ()
                   (setf cl-user::*cg-result* :cancelled))
                 (error (e)
                   (setf cl-user::*cg-result* (format nil "ERR: ~a" e))))))

  (format t "~%── inject 'z' (trigger) ──~%")
  (limn:call "test/inject-qt-key" :|key| "z")
  (sleep 0.3)
  (let* ((g (limn:call "minibuffer/get"))
         (d (limn/bridge:response-data g)))
    (format t "  minibuffer: open=~a prompt=~s~%"
            (getf d :|open|) (getf d :|prompt|)))

  (format t "~%── inject C-g ──~%")
  (limn:call "test/inject-qt-key" :|key| "g" :|mods| (list "ctrl"))
  (sleep 0.5)

  (let* ((g (limn:call "minibuffer/get"))
         (d (limn/bridge:response-data g))
         (open-after (getf d :|open|))
         ;; The bridge decodes JSON false → :false (not cl:nil), see
         ;; limn-bridge.lisp lines ~22/100.
         (ok (and (eq open-after :false)
                  (eq cl-user::*cg-result* :cancelled))))
    (format t "  minibuffer: open=~a~%" open-after)
    (format t "  *cg-result*: ~s~%" cl-user::*cg-result*)
    (format t "~%── VERDICT: ~a ──~%"
            (if ok "✓ PASS — C-g aborted the in-flight defcommand"
                   (format nil "✗ FAIL — open=~a result=~s"
                           open-after cl-user::*cg-result*)))
    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (when (probe-file *init-stash*)
      (rename-file *init-stash* *init-path*))
    (sb-ext:exit :code (if ok 0 1))))
