;;;; v0.22 Phase A/B — OS-tier driver
;;;;
;;;; 驗整條鏈：xdotool 真的按鍵 → bridge 收 key event → Lisp text-mode
;;;; dispatch → buffer/insert / delete / save → 磁碟檔案有對應內容。
;;;;
;;;; 不驗畫面（Phase C visual 走 batch-os-text-display.lisp）。
;;;;
;;;; 所有測試 v0.22 Phase A + B 實作前全紅。

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

(defun read-file-string (path)
  (with-open-file (s path :direction :input :external-format :utf-8)
    (with-output-to-string (out)
      (loop for ch = (read-char s nil nil) while ch do (write-char ch out)))))

(defun write-file-string (path content)
  (with-open-file (s path :direction :output
                          :if-exists :supersede
                          :external-format :utf-8)
    (write-string content s)))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v022e"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp"
             "limn-text-mode.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(let* ((sock (format nil "/tmp/limn-e2e-v022e-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v022e.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

;;; ── §A 直接 wire：load-file / save round-trip ───────────────────────

    (format t "~%── A: load-file / save wire round-trip ──~%")

    (let* ((tmp (format nil "/tmp/limn-v022-edit-~a.txt" (sb-posix:getpid))))
      (write-file-string tmp "hello world")

      ;; Open a text buffer in w1
      (let* ((r (limn:call "bridge/engine-load"
                            :|win-id| "w1" :|engine| "text" :|path| ""))
             (d (limn/bridge:response-data r))
             (buf (getf d :|buffer-id|)))
        (check "engine-load text returns buffer-id"
               (and buf (stringp buf)))

        ;; load-file
        (let ((r (limn:call "buffer/load-file"
                            :|buffer-id| buf :|path| tmp)))
          (check "buffer/load-file returns ok" (eq (getf r :|ok|) t)
                 (format nil "got ~s" r)))

        ;; buffer/text matches file
        (let* ((r (limn:call "buffer/text" :|buffer-id| buf))
               (d (limn/bridge:response-data r)))
          (check "buffer/text matches file contents"
                 (equal (getf d :|text|) "hello world")
                 (format nil "got ~s" (getf d :|text|))))

        ;; Insert via wire → save → disk has new content
        (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 11)
        (limn:call "buffer/insert" :|buffer-id| buf :|text| " ✓")
        (let ((r (limn:call "buffer/save" :|buffer-id| buf)))
          (check "buffer/save returns ok" (eq (getf r :|ok|) t)
                 (format nil "got ~s" r)))
        (check "disk content matches buffer after save"
               (equal "hello world ✓" (read-file-string tmp))
               (format nil "got ~s" (read-file-string tmp)))))

;;; ── §B1 xdotool 打字 → text-mode self-insert ───────────────────────

    (format t "~%── B1: xdotool typing routes through text-mode ──~%")

    (let* ((tmp (format nil "/tmp/limn-v022-type-~a.txt" (sb-posix:getpid))))
      (write-file-string tmp "")
      ;; Re-use w1: load empty file
      (let* ((r (limn:call "bridge/engine-load"
                            :|win-id| "w1" :|engine| "text" :|path| ""))
             (buf (getf (limn/bridge:response-data r) :|buffer-id|)))
        (limn:call "buffer/load-file" :|buffer-id| buf :|path| tmp)
        ;; engine=text default mode should be text-mode (B7 contract)
        (sleep 0.2)

        ;; Now type — text-mode's self-insert should drive buffer/insert
        (xdotool "type" "--delay" "20" "abc")
        (sleep 0.3)

        (let* ((r (limn:call "buffer/text" :|buffer-id| buf))
               (got (getf (limn/bridge:response-data r) :|text|)))
          (check "after xdotool type 'abc', buffer text is 'abc'"
                 (equal got "abc")
                 (format nil "got ~s" got)))

        ;; Backspace via xdotool → text-mode delete-backward-char
        (xdotool "key" "BackSpace")
        (sleep 0.2)
        (let* ((r (limn:call "buffer/text" :|buffer-id| buf))
               (got (getf (limn/bridge:response-data r) :|text|)))
          (check "after BackSpace, buffer text is 'ab'"
                 (equal got "ab")
                 (format nil "got ~s" got)))

        ;; Arrow Left → cursor moves left, insert goes in middle
        (xdotool "key" "Left")
        (sleep 0.15)
        (xdotool "type" "--delay" "20" "X")
        (sleep 0.2)
        (let* ((r (limn:call "buffer/text" :|buffer-id| buf))
               (got (getf (limn/bridge:response-data r) :|text|)))
          (check "Left then 'X' inserts mid-buffer (aXb)"
                 (equal got "aXb")
                 (format nil "got ~s" got)))))

;;; ── §B2 C-x C-s saves the current text-mode buffer ─────────────────

    (format t "~%── B2: C-x C-s saves to disk ──~%")

    (let* ((tmp (format nil "/tmp/limn-v022-save-~a.txt" (sb-posix:getpid))))
      (write-file-string tmp "before")
      (let* ((r (limn:call "bridge/engine-load"
                            :|win-id| "w1" :|engine| "text" :|path| ""))
             (buf (getf (limn/bridge:response-data r) :|buffer-id|)))
        (limn:call "buffer/load-file" :|buffer-id| buf :|path| tmp)
        (sleep 0.2)

        ;; Move cursor to end of buffer first (SPEC: load-file resets
        ;; cursor to 0, so typing without move would insert at start).
        (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 6)
        ;; Type new content
        (xdotool "type" "--delay" "20" " edited")
        (sleep 0.3)

        ;; C-x C-s
        (xdotool "key" "--clearmodifiers" "ctrl+x") (sleep 0.15)
        (xdotool "key" "--clearmodifiers" "ctrl+s") (sleep 0.4)

        (check "C-x C-s wrote 'before edited' to disk"
               (equal "before edited" (read-file-string tmp))
               (format nil "got ~s" (read-file-string tmp)))))

;;; ── §B3 C-x C-f find-file via key sequence ──────────────────────────

    (format t "~%── B3: C-x C-f opens a file via minibuffer ──~%")

    (let* ((tmp (format nil "/tmp/limn-v022-ff-~a.txt" (sb-posix:getpid))))
      (write-file-string tmp "loaded via find-file")

      ;; Start from a fresh non-text state — focus w1's current buffer
      ;; (may be PDF or text from previous). C-x C-f should be global
      ;; (or fundamental-mode level) so it works regardless.
      (xdotool "key" "--clearmodifiers" "ctrl+x") (sleep 0.15)
      (xdotool "key" "--clearmodifiers" "ctrl+f") (sleep 0.25)

      ;; Minibuffer should now be open with prompt for path. Type path.
      (xdotool "type" "--delay" "20" tmp)
      (sleep 0.15)
      (xdotool "key" "Return")
      (sleep 0.5)

      ;; The new buffer should have the file's content. Find it via
      ;; view/get → buffer-id → buffer/text.
      (let* ((vg  (limn:call "view/get" :|win-id| "w1"))
             (d   (limn/bridge:response-data vg))
             (buf (getf d :|buffer-id|)))
        (check "view/get returns a buffer-id after find-file"
               (and buf (stringp buf) (plusp (length buf)))
               (format nil "got ~s" buf))
        (when (and buf (stringp buf) (plusp (length buf)))
          (let* ((tr  (limn:call "buffer/text" :|buffer-id| buf))
                 (got (getf (limn/bridge:response-data tr) :|text|)))
            (check "buffer content matches file contents"
                   (equal got "loaded via find-file")
                   (format nil "got ~s" got))))))

;;; ── §B4 find-file on a new path → empty buffer + 'New file' echo ───

    (format t "~%── B4: find-file new-path → empty + echo 'New file' ──~%")

    (let* ((new-path (format nil "/tmp/limn-v022-new-~a.txt" (sb-posix:getpid))))
      ;; Ensure the path does not exist
      (when (probe-file new-path) (delete-file new-path))
      (xdotool "key" "--clearmodifiers" "ctrl+x") (sleep 0.15)
      (xdotool "key" "--clearmodifiers" "ctrl+f") (sleep 0.25)
      (xdotool "type" "--delay" "20" new-path)
      (sleep 0.15)
      (xdotool "key" "Return")
      (sleep 0.4)
      ;; Buffer should be empty
      (let* ((vg  (limn:call "view/get" :|win-id| "w1"))
             (buf (getf (limn/bridge:response-data vg) :|buffer-id|)))
        (when (and buf (stringp buf))
          (let* ((tr (limn:call "buffer/text" :|buffer-id| buf))
                 (got (or (getf (limn/bridge:response-data tr) :|text|) "")))
            (check "new-path buffer starts empty"
                   (zerop (length got))
                   (format nil "got ~s" got)))))
      ;; Echo area should have "New file"
      (let* ((er  (limn:call "buffer/text" :|buffer-id| "*echo-area*"))
             (eot (or (getf (limn/bridge:response-data er) :|text|) "")))
        (check "echo area mentions 'New file'"
               (search "New file" eot)
               (format nil "got ~s" eot))))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — v0.22 A/B text-edit driver green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-v022e")
        (rename-file "/tmp/.limn/init.lisp.stash-v022e" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
