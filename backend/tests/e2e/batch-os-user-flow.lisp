;;;; Batch 12: multi-step user scenarios — G1 / G2.
;;;;
;;;; 「真實使用者一條 user story」整條走通。串連多個 wire 命令 +
;;;; 多個 OS-level 操作。
;;;;
;;;; G1 開 PDF → j 翻 5 頁 → / search → 打字 → submit → message echoed
;;;; G2 init.lisp 定義 cmd → bind → inject → 動作 → introspect 找得到

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

(defun xdotool-stdout (&rest args)
  (with-output-to-string (s)
    (let ((p (sb-ext:run-program "xdotool" args :search t
                                  :wait t :output s :error t)))
      (unless (zerop (sb-ext:process-exit-code p))
        (error "xdotool ~{~a~^ ~} exited non-zero" args)))))

(defun wait-for-window-by-name (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((s (string-trim '(#\Space #\Newline #\Tab)
                             (handler-case
                                 (xdotool-stdout "search" "--name" name)
                               (error () "")))))
        (unless (zerop (length s))
          (return (parse-integer
                   (subseq s 0 (or (position #\Newline s) (length s)))))))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-uf"))

;; G1 + G2 both want the demo init.lisp pre-loaded.
(sb-posix:setenv "LIMN_INIT" (b/ "init.lisp.example") 1)

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun current-page ()
  (getf (limn/bridge:response-data (limn:call "view/get" :|win-id| "w1"))
        :|page|))

(let* ((sock (format nil "/tmp/limn-e2e-uf-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-uf.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

;;; ── G1: 翻頁 → 搜尋 → message echo ───────────────────────────────

    (format t "~%── G1: open PDF → j×5 → / → type query → RET → message ──~%")

    (check "G1 setup — demo init.lisp loaded (next-page exists)"
           (limn/cmd:find-command 'next-page))
    (check "G1 setup — page starts at 0"
           (= (current-page) 0))

    ;; j × 5 → page 5 (last page)
    (dotimes (i 5)
      (xdotool "key" "--clearmodifiers" "j")
      (sleep 0.15))
    (sleep 0.2)
    (check (format nil "G1 — page 5 after j×5 (got ~a)" (current-page))
           (= (current-page) 5))

    ;; / opens minibuffer
    (xdotool "key" "--clearmodifiers" "slash")
    (sleep 0.3)
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "G1 — minibuffer open after /"
             (eq (getf d :|open|) t))
      (check "G1 — prompt is /"
             (equal (getf d :|prompt|) "/")))

    ;; type "hello"
    (xdotool "type" "--delay" "20" "hello")
    (sleep 0.3)
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "G1 — minibuffer accumulates 'hello'"
             (equal (getf d :|text|) "hello")))

    ;; RET submit → search-here echoes to *messages*
    (xdotool "key" "--clearmodifiers" "Return")
    (sleep 0.4)
    ;; Verify message landed in *messages* buffer
    (let* ((r (limn:call "buffer/text" :|buffer-id| "*messages*"))
           (d (limn/bridge:response-data r))
           (text (getf d :|text|)))
      (check "G1 — *messages* contains 'Searching for: hello'"
             (and (stringp text)
                  (search "Searching for: hello" text))
             (format nil "got text=~s" text)))

;;; ── G2: init.lisp define → bind → inject → introspect ───────────

    (format t "~%── G2: define + bind + inject + introspect chain ──~%")

    (defparameter cl-user::*g2-fired* 0)
    (limn/cmd:defcommand g2-test-cmd ()
      (lambda () (incf cl-user::*g2-fired*)))
    (limn:bind "z" 'g2-test-cmd)
    (sleep 0.2)

    (check "G2 — command registered"
           (limn/cmd:find-command 'g2-test-cmd))

    (xdotool "key" "--clearmodifiers" "z")
    (sleep 0.3)
    (check "G2 — z inject fires bound command"
           (= cl-user::*g2-fired* 1))

    ;; describe-command finds it
    (let ((d (limn/introspect:describe-command 'g2-test-cmd)))
      (check "G2 — describe-command returns plist"
             d
             (format nil "got ~s" d))
      (when d
        (check "G2 — describe-command :name = g2-test-cmd"
               (eq (getf d :name) 'g2-test-cmd))))

    ;; where-is-command finds the binding
    (let ((keys (limn/introspect:where-is-command 'g2-test-cmd)))
      (check "G2 — where-is-command finds 'z' binding"
             (find "z" keys :test #'string=)
             (format nil "got keys=~s" keys)))

    ;; describe-key locates it the other direction
    (let ((d (limn/introspect:describe-key "z"
                                            :global-keymap limn:*global-keymap*)))
      (check "G2 — describe-key returns plist with action"
             (and d (getf d :action))
             (format nil "got ~s" d)))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 12 user flow green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (sb-posix:setenv "LIMN_INIT" "" 1)
      (when (probe-file "/tmp/.limn/init.lisp.stash-uf")
        (rename-file "/tmp/.limn/init.lisp.stash-uf" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
