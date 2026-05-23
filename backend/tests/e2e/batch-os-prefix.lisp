;;;; A6: C-x C-f real Emacs-style multi-key prefix with modifiers.
;;;;
;;;; v0.9.1 demo init.lisp 測過 =g g=（無 modifier 兩鍵 prefix）。但
;;;; 真正 Emacs convention 的 prefix 是 =C-x= 之類「modifier + 鍵」當
;;;; prefix、然後第二鍵也可能帶 modifier。lookup-sequence 在 limn/keys
;;;; 應該已 handle、沒實測過 OS-level。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defun xdotool (&rest args)
  (let ((p (sb-ext:run-program "xdotool" args :search t
                                :wait t :output t :error t)))
    (unless (zerop (sb-ext:process-exit-code p))
      (error "xdotool ~{~a~^ ~} exited non-zero" args))))

(defun wait-for-window-by-name (name &key (timeout 5))
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

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-prefix"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter cl-user::*cx-cf-fired* 0)

(let* ((sock (format nil "/tmp/limn-e2e-prefix-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-prefix.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window-by-name "Limn" :timeout 5)

  (limn/cmd:defcommand find-file-test ()
    (lambda () (incf cl-user::*cx-cf-fired*)))

  (limn:bind "C-x C-f" 'find-file-test)

  (format t "~%── A6: C-x C-f real Emacs prefix ──~%")

  ;; Step 1: just C-x — should commit to prefix (not yet fire)
  (xdotool "key" "--clearmodifiers" "ctrl+x")
  (sleep 0.2)
  (format t "  after C-x: *cx-cf-fired* = ~a (expect 0)~%"
          cl-user::*cx-cf-fired*)

  ;; Step 2: C-f — completes the sequence, command should fire
  (xdotool "key" "--clearmodifiers" "ctrl+f")
  (sleep 0.3)
  (format t "  after C-f: *cx-cf-fired* = ~a (expect 1)~%"
          cl-user::*cx-cf-fired*)

  ;; Step 3: do it again — verify state cleared and second invocation works
  (xdotool "key" "--clearmodifiers" "ctrl+x") (sleep 0.15)
  (xdotool "key" "--clearmodifiers" "ctrl+f") (sleep 0.3)
  (format t "  after second sequence: *cx-cf-fired* = ~a (expect 2)~%"
          cl-user::*cx-cf-fired*)

  (let ((ok (eql cl-user::*cx-cf-fired* 2)))
    (format t "~%── VERDICT: ~a ──~%"
            (if ok "✓ PASS — C-x C-f multi-key prefix with modifiers works"
                   (format nil "✗ FAIL — fired ~a times, expected 2"
                           cl-user::*cx-cf-fired*)))
    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (when (probe-file "/tmp/.limn/init.lisp.stash-prefix")
      (rename-file "/tmp/.limn/init.lisp.stash-prefix" "/tmp/.limn/init.lisp"))
    (sb-ext:exit :code (if ok 0 1))))
