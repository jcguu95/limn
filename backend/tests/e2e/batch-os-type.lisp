;;;; OS-level e2e: 連續字串輸入透過 xdotool type。
;;;;
;;;; v0.9 既有的 OS-level driver 都只測「單鍵」injection。Limn 使用者
;;;; 最常用的動作其實是「打字」——例如 / 後輸入 search query。這個
;;;; driver 驗證該路徑：
;;;;
;;;;   xdotool key slash      → open minibuffer (prompt "/")
;;;;   xdotool type "hello"   → 每個字 → minibuffer-input event
;;;;                            → reader text 累積
;;;;   xdotool key Return     → minibuffer-submit event
;;;;                            → reader 收到 query
;;;;                            → defcommand body 設 *captured-query*
;;;;
;;;; 驗證 *captured-query* = "hello world".

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

;; Stash any dev /tmp/.limn/init.lisp so it doesn't interfere.
(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-type"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter cl-user::*captured-query* nil
  "Set by query-capture defcommand body when minibuffer submits.")

(let* ((sock (format nil "/tmp/limn-e2e-ostype-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-type.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window-by-name "Limn" :timeout 5)

  ;; Define a command that captures whatever the user typed.
  (limn/cmd:defcommand query-capture (:interactive "sQuery: ")
    (lambda (q)
      (setf cl-user::*captured-query* q)))

  ;; Bind / to trigger it (mirrors demo init.lisp pattern).
  (limn:bind "/" 'query-capture)

  (format t "~%── xdotool key slash → open minibuffer ──~%")
  (xdotool "key" "--clearmodifiers" "slash")
  (sleep 0.4)
  (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
    (format t "  open=~a prompt=~s~%"
            (getf d :|open|) (getf d :|prompt|)))

  ;; This is the headline test: connected typing via xdotool type.
  ;; Each character generates an X11 KeyPress, Qt translates to QKeyEvent,
  ;; our LimnInputFilter sees printable + minibuffer open → minibuffer-input
  ;; event accumulates text. reader sees nothing yet (it's waiting for submit).
  (format t "~%── xdotool type \"hello world\" → connected input ──~%")
  (xdotool "type" "--delay" "30" "hello world")
  (sleep 0.5)
  (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
    (format t "  minibuffer text=~s~%" (getf d :|text|)))

  (format t "~%── xdotool key Return → submit ──~%")
  (xdotool "key" "--clearmodifiers" "Return")
  (sleep 0.5)

  (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get")))
         (minibuffer-closed (eq (getf d :|open|) :false))
         (got-query (equal cl-user::*captured-query* "hello world"))
         (ok (and minibuffer-closed got-query)))
    (format t "  minibuffer.open=~a~%" (getf d :|open|))
    (format t "  *captured-query* = ~s~%" cl-user::*captured-query*)
    (format t "~%── VERDICT: ~a ──~%"
            (if ok "✓ PASS — OS-level connected typing reached defcommand"
                   (format nil "✗ FAIL — closed=~a captured=~s"
                           minibuffer-closed cl-user::*captured-query*)))
    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (when (probe-file "/tmp/.limn/init.lisp.stash-type")
      (rename-file "/tmp/.limn/init.lisp.stash-type" "/tmp/.limn/init.lisp"))
    (sb-ext:exit :code (if ok 0 1))))
