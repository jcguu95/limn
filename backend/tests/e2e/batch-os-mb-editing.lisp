;;;; Batch 20: minibuffer editing — A2 BS、A4 arrow / home / end.
;;;;
;;;; v0.10/v0.11 把 A2 / A4 推遲為 feature-blocked。今晚加 ~30 行 C++
;;;; 實作 + 同 batch 寫 OS-level test 釘住。
;;;;
;;;; A2 BS in minibuffer 刪 cursor 前一字 + cursor 跟著回退
;;;; A4 arrow keys 在 minibuffer 移 cursor、不動 text
;;;; A4 Home / End 跳起始 / 結尾

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-mbe"))

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

(defun mb-state ()
  "Return (text . cursor)."
  (let ((tx (getf (limn/bridge:response-data (limn:call "minibuffer/get"))
                  :|text|))
        (cu (getf (limn/bridge:response-data
                   (limn:call "buffer/cursor-get"
                              :|buffer-id| "*minibuffer*"))
                  :|offset|)))
    (cons tx cu)))

(let* ((sock (format nil "/tmp/limn-e2e-mbe-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-mbe.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

;;; ── A2: BS deletes char before cursor + cursor retreats ──────────

    (format t "~%── A2: BackSpace in minibuffer ──~%")
    (limn:call "minibuffer/open" :|prompt| "edit: ")
    (sleep 0.2)
    (xdotool "type" "--delay" "20" "hello")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "A2 setup — text='hello' cursor=5 (got ~s)" s)
             (equal s '("hello" . 5))))

    (xdotool "key" "--clearmodifiers" "BackSpace")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "A2 — BS deletes 'o', text='hell' cursor=4 (got ~s)" s)
             (equal s '("hell" . 4))))

    (xdotool "key" "--clearmodifiers" "BackSpace")
    (xdotool "key" "--clearmodifiers" "BackSpace")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "A2 — BS×2 more, text='he' cursor=2 (got ~s)" s)
             (equal s '("he" . 2))))

    ;; BS at offset 0 should be noop (no underflow)
    (xdotool "key" "--clearmodifiers" "BackSpace")
    (xdotool "key" "--clearmodifiers" "BackSpace")
    (xdotool "key" "--clearmodifiers" "BackSpace")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "A2 — BS to empty + extra BS is noop (got ~s)" s)
             (equal s '("" . 0))))

;;; ── A4: arrow keys move cursor without changing text ─────────────

    (format t "~%── A4: arrow keys + Home/End in minibuffer ──~%")
    (xdotool "type" "--delay" "20" "abcde")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "A4 setup — text='abcde' cursor=5 (got ~s)" s)
             (equal s '("abcde" . 5))))

    ;; Left twice → cursor 3
    (xdotool "key" "--clearmodifiers" "Left")
    (xdotool "key" "--clearmodifiers" "Left")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "A4 — Left×2: cursor=3, text unchanged (got ~s)" s)
             (equal s '("abcde" . 3))))

    ;; Right once → cursor 4
    (xdotool "key" "--clearmodifiers" "Right")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "A4 — Right: cursor=4 (got ~s)" s)
             (equal s '("abcde" . 4))))

    ;; Home → cursor 0
    (xdotool "key" "--clearmodifiers" "Home")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "A4 — Home: cursor=0 (got ~s)" s)
             (equal s '("abcde" . 0))))

    ;; End → cursor 5
    (xdotool "key" "--clearmodifiers" "End")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "A4 — End: cursor=5 (got ~s)" s)
             (equal s '("abcde" . 5))))

    ;; Left underflow at 0
    (xdotool "key" "--clearmodifiers" "Home")
    (xdotool "key" "--clearmodifiers" "Left")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "A4 — Left at cursor 0 is noop (got ~s)" s)
             (equal s '("abcde" . 0))))

;;; ── Bonus: typing in middle inserts at cursor ───────────────────

    (format t "~%── bonus: typing 'X' at cursor 2 inserts 'X' there ──~%")
    ;; cursor is at 0 from Home above; move to 2
    (xdotool "key" "--clearmodifiers" "Right")
    (xdotool "key" "--clearmodifiers" "Right")
    (sleep 0.2)
    (xdotool "type" "--delay" "20" "X")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "bonus — typing 'X' at offset 2 → 'abXcde' cursor=3 (got ~s)" s)
             (equal s '("abXcde" . 3))))

    ;; BS at offset 3 should delete 'X'
    (xdotool "key" "--clearmodifiers" "BackSpace")
    (sleep 0.3)
    (let ((s (mb-state)))
      (check (format nil "bonus — BS deletes X → 'abcde' cursor=2 (got ~s)" s)
             (equal s '("abcde" . 2))))

    (limn:call "minibuffer/close")
    (sleep 0.2)

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 20 minibuffer editing green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-mbe")
        (rename-file "/tmp/.limn/init.lisp.stash-mbe" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
