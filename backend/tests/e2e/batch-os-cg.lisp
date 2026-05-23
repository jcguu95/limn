;;;; OS-level end-to-end test of C-g cancel.
;;;;
;;;; Designed to run INSIDE a Linux container with Xvfb + xdotool. This
;;;; is the OS-level counterpart to batch8-cg-qt.lisp — same scenario,
;;;; but the keystrokes come from `xdotool key` (real X11 input event
;;;; injection) instead of `test/inject-qt-key` (Qt-internal sendEvent).
;;;;
;;;; The chain that gets exercised on top of what Qt-level already tests:
;;;;
;;;;   xdotool → X server (Xvfb) → XInput event → QApplication
;;;;   ↑ (this whole layer is new — Qt-level skipped it)
;;;;
;;;; Will fail on macOS host because:
;;;;   - xdotool not installed
;;;;   - DISPLAY not set
;;;; That's the "red". Batch 2+ build the container that makes it green.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      "/limn/backend/"))               ; container path
(defun b/ (f) (concatenate 'string *bdir* f))

(defun xdotool (&rest args)
  "Shell out to xdotool. Errors if xdotool isn't on PATH."
  (let ((p (sb-ext:run-program "xdotool" args :search t
                                :wait t :output t :error t)))
    (unless (zerop (sb-ext:process-exit-code p))
      (error "xdotool ~{~a~^ ~} exited non-zero" args))))

(defun wait-for-window-by-name (name &key (timeout 5))
  "Block until xdotool finds a window with NAME, or TIMEOUT seconds elapse."
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((p (sb-ext:run-program "xdotool"
                                    (list "search" "--name" name)
                                    :search t :wait t :output nil)))
        (when (zerop (sb-ext:process-exit-code p))
          (return t)))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

;; Stash dev init.lisp so it doesn't redefine our test command.
(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-os"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter cl-user::*cg-result* :pending)

(let* ((sock (format nil "/tmp/limn-e2e-oscg-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     "/limn/sioyek/limn"))     ; Linux build target name
       (proc (sb-ext:run-program
              limn-bin
              ;; OS-level: NO --headless, NO QT_QPA_PLATFORM=minimal —
              ;; we want a real Qt xcb window on the Xvfb server so
              ;; xdotool has something to inject into.
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-cg.log"
              :if-output-exists :supersede
              :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)

  ;; Wait for the window to appear on X (xdotool needs a real window)
  (wait-for-window-by-name "Limn" :timeout 5)

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

  ;; Real X11 keystroke through xdotool — this is the moment OS-level
  ;; differs from Qt-level. The keystroke goes through the X server,
  ;; AppKit-equivalent layer, then Qt picks it up via xcb.
  (format t "~%── xdotool key z (trigger) ──~%")
  (xdotool "key" "--clearmodifiers" "z")
  (sleep 0.5)
  (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
    (format t "  minibuffer after z: open=~a prompt=~s~%"
            (getf d :|open|) (getf d :|prompt|)))

  (format t "~%── xdotool key ctrl+g (cancel) ──~%")
  (xdotool "key" "--clearmodifiers" "ctrl+g")
  (sleep 0.7)

  (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get")))
         (open-after (getf d :|open|))
         (ok (and (eq open-after :false)
                  (eq cl-user::*cg-result* :cancelled))))
    (format t "  minibuffer after C-g: open=~a~%" open-after)
    (format t "  *cg-result*: ~s~%" cl-user::*cg-result*)
    (format t "~%── VERDICT: ~a ──~%"
            (if ok "✓ PASS — OS-level C-g aborted defcommand"
                   (format nil "✗ FAIL — open=~a result=~s"
                           open-after cl-user::*cg-result*)))
    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (when (probe-file "/tmp/.limn/init.lisp.stash-os")
      (rename-file "/tmp/.limn/init.lisp.stash-os" "/tmp/.limn/init.lisp"))
    (sb-ext:exit :code (if ok 0 1))))
