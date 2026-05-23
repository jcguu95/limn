;;;; Batch 23: multi-byte (CJK) char 進 minibuffer。
;;;;
;;;; batch-os-cjk-path 證了 CJK 走 engine-load 路徑 (Lisp→JSON→C++→
;;;; mupdf) 不 mojibake。但 *minibuffer* 那條 path 不一樣：
;;;;
;;;;   xdotool type "你好"
;;;;     → Xvfb fake-input synthesises Unicode KeyPress events
;;;;     → QKeyEvent.text() (應該) 帶 UTF-8 "你好"
;;;;     → LimnInputFilter::eventFilter → minibuffer_handle_key
;;;;     → text_buffers["*minibuffer*"].insert(cur, to_append)
;;;;     → push_event("minibuffer-input", { text: "你好", cursor: 2 })
;;;;
;;;; 任一步 truncate 成單 byte、locale 假設 ASCII、或 cursor unit 算錯
;;;; (byte vs codepoint) 都會看見。v0.12 batch 20 把 cursor logic 改成
;;;; per-codepoint (QString.length() 是 UTF-16 code units 不是 bytes、
;;;; 但 BMP 內中文每字一個 unit、cursor 應該對)。先寫測、看真實狀況。

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-cjkmb"))

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

(let* ((sock (format nil "/tmp/limn-e2e-cjkmb-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-cjkmb.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

;;; ── Case 1: 純 CJK 輸入 ─────────────────────────────────────────

    (format t "~%── A6/CJK Case 1: pure CJK input '你好世界' ──~%")
    (limn:call "minibuffer/open" :|prompt| "中文: ")
    (sleep 0.2)
    (xdotool "type" "--delay" "30" "你好世界")
    (sleep 0.6)
    (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get")))
           (got (getf d :|text|))
           (cur (getf d :|cursor|)))
      (check (format nil "Case 1 — text == '你好世界' (got ~s)" got)
             (equal got "你好世界"))
      (check (format nil "Case 1 — cursor == 4 codepoints (got ~a)" cur)
             (eql cur 4)))
    (limn:call "minibuffer/close")
    (sleep 0.2)

;;; ── Case 2: CJK + ASCII 混排 ───────────────────────────────────

    (format t "~%── A6/CJK Case 2: mixed 'hi你好' ──~%")
    (limn:call "minibuffer/open" :|prompt| "mix: ")
    (sleep 0.2)
    (xdotool "type" "--delay" "30" "hi你好")
    (sleep 0.6)
    (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get")))
           (got (getf d :|text|))
           (cur (getf d :|cursor|)))
      (check (format nil "Case 2 — text == 'hi你好' (got ~s)" got)
             (equal got "hi你好"))
      (check (format nil "Case 2 — cursor == 4 (2 ASCII + 2 CJK; got ~a)" cur)
             (eql cur 4)))

;;; ── Case 3: BS 退 CJK ─────────────────────────────────────────

    (format t "~%── A6/CJK Case 3: BS deletes one CJK char ──~%")
    ;; State from Case 2: "hi你好" cursor=4
    (xdotool "key" "--clearmodifiers" "BackSpace")
    (sleep 0.3)
    (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get")))
           (got (getf d :|text|))
           (cur (getf d :|cursor|)))
      (check (format nil "Case 3 — after BS == 'hi你' (got ~s)" got)
             (equal got "hi你"))
      (check (format nil "Case 3 — cursor == 3 (got ~a)" cur)
             (eql cur 3)))

;;; ── Case 4: Left/Right 跨 CJK 字 ──────────────────────────────

    (format t "~%── A6/CJK Case 4: Left/Right step by codepoint, not byte ──~%")
    ;; State: "hi你" cursor=3. Left → cursor=2 (between i and 你).
    (xdotool "key" "--clearmodifiers" "Left")
    (sleep 0.2)
    (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get")))
           (cur (getf d :|cursor|)))
      (check (format nil "Case 4 — Left moved cursor 3→2 (got ~a)" cur)
             (eql cur 2)))
    ;; Now insert "X" between i and 你. Should become "hiX你" cursor=3.
    (xdotool "type" "--delay" "30" "X")
    (sleep 0.3)
    (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get")))
           (got (getf d :|text|)))
      (check (format nil "Case 4 — insert at codepoint boundary 'hiX你' (got ~s)" got)
             (equal got "hiX你")))

;;; ── Case 5: defcommand :interactive "sP: " 收到 CJK ──────────────

    (format t "~%── A6/CJK Case 5: defcommand callback receives CJK ──~%")
    (limn:call "minibuffer/close")
    (sleep 0.2)
    (defparameter cl-user::*cjk-saw* nil)
    (limn/cmd:defcommand cjk-recv (:interactive "sP: ")
      (lambda (q) (setf cl-user::*cjk-saw* q)))
    (limn:bind "x" 'cjk-recv)
    (sleep 0.2)
    (xdotool "key" "--clearmodifiers" "x")
    (sleep 0.3)
    (xdotool "type" "--delay" "30" "貓")
    (sleep 0.4)
    (xdotool "key" "--clearmodifiers" "Return")
    (sleep 0.3)
    (check (format nil "Case 5 — callback received '貓' (got ~s)" cl-user::*cjk-saw*)
           (equal cl-user::*cjk-saw* "貓"))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 23 CJK minibuffer green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-cjkmb")
        (rename-file "/tmp/.limn/init.lisp.stash-cjkmb" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
