;;;; A1: 全鍵盤打字 sweep — letters / digits / symbols via xdotool type.
;;;;
;;;; v0.9.1 抓到 SPC 從 minibuffer 漏失的 bug。同樣的 char-mapping bug
;;;; 可能藏在其它任何字元上：backtick、tilde、特殊 punctuation、shifted
;;;; symbol 等。這個 driver 一次掃整套 ASCII printable、要求 minibuffer
;;;; 收到的 text 跟我們打進去的完全一致。
;;;;
;;;; 三段：lowercase letters、uppercase letters、digits、symbols。
;;;; 每段分開驗證、報哪段失敗。

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-keys"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (unless ok (push msg *failures*)))

(defun mb-text ()
  (getf (limn/bridge:response-data (limn:call "minibuffer/get")) :|text|))

(defun open-fresh-minibuffer ()
  ;; close if open, then open
  (ignore-errors (limn:call "minibuffer/close"))
  (limn:call "minibuffer/open" :|prompt| "type: "))

(defun type-and-verify (label expected)
  (open-fresh-minibuffer)
  (xdotool "type" "--delay" "20" expected)
  (sleep 0.3)
  (let ((got (mb-text)))
    (check (format nil "~a: ~s" label expected)
           (equal got expected))
    (unless (equal got expected)
      (format t "    (got ~s)~%" got))))

(let* ((sock (format nil "/tmp/limn-e2e-keys-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-keys.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window-by-name "Limn" :timeout 5)

  (format t "~%── A1: keyboard sweep ──~%")

  ;; 1. lowercase letters
  (type-and-verify "lowercase" "abcdefghijklmnopqrstuvwxyz")

  ;; 2. UPPERCASE letters (xdotool sends shift+letter)
  (type-and-verify "uppercase" "ABCDEFGHIJKLMNOPQRSTUVWXYZ")

  ;; 3. digits
  (type-and-verify "digits" "0123456789")

  ;; 4. unshifted symbols
  (type-and-verify "unshifted-symbols" "`-=[]\\;',./")

  ;; 5. shifted symbols (each requires shift modifier)
  (type-and-verify "shifted-symbols" "~!@#$%^&*()_+{}|:\"<>?")

  ;; 6. mixed real-world string with space
  (type-and-verify "mixed" "Hello, World! (test 42)")

  (let ((ok (null *failures*)))
    (format t "~%── VERDICT: ~a ──~%"
            (if ok "✓ PASS — A1 keyboard sweep clean"
                   (format nil "✗ FAIL: ~{~%    ~a~}" *failures*)))
    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (when (probe-file "/tmp/.limn/init.lisp.stash-keys")
      (rename-file "/tmp/.limn/init.lisp.stash-keys" "/tmp/.limn/init.lisp"))
    (sb-ext:exit :code (if ok 0 1))))
