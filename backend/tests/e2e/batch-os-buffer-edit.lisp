;;;; Batch 19: buffer edit primitives (SPEC §5.3 後段).
;;;;
;;;; v0.8 batch 3 寫了 cursor-get / cursor-set / insert / delete 4 個
;;;; wire 命令、有 integration test。OS-level 沒釘住「真使用者在 minibuffer
;;;; 內打字 → 這些 primitive 真的有跑」這條鏈。

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-be"))

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

(let* ((sock (format nil "/tmp/limn-e2e-be-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-be.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

;;; ── §5.3 cursor-get / cursor-set / insert / delete 經 OS 路徑 ─

    (format t "~%── buffer-edit primitives on *minibuffer* ──~%")
    (limn:call "minibuffer/open" :|prompt| "edit: ")
    (sleep 0.2)

    ;; cursor-get on empty minibuffer
    (let* ((r (limn:call "buffer/cursor-get" :|buffer-id| "*minibuffer*"))
           (d (limn/bridge:response-data r)))
      (check "cursor-get on empty minibuffer returns 0"
             (= (getf d :|offset|) 0)
             (format nil "got ~s" d)))

    ;; Type "hello" via OS, then check cursor moved to 5
    (xdotool "type" "--delay" "20" "hello")
    (sleep 0.3)
    (let* ((r (limn:call "buffer/cursor-get" :|buffer-id| "*minibuffer*"))
           (d (limn/bridge:response-data r)))
      (check "after typing 'hello', cursor at offset 5"
             (= (getf d :|offset|) 5)
             (format nil "got ~s" d)))

    ;; cursor-set to 2, then insert "X" — should produce "heXllo"
    (let ((r (limn:call "buffer/cursor-set"
                        :|buffer-id| "*minibuffer*"
                        :|offset| 2)))
      (check "cursor-set to offset 2 returns ok"
             (eq (getf r :|ok|) t)))
    (let ((r (limn:call "buffer/insert"
                        :|buffer-id| "*minibuffer*"
                        :|text| "X")))
      (check "buffer/insert returns ok"
             (eq (getf r :|ok|) t)))
    (let* ((r (limn:call "minibuffer/get"))
           (d (limn/bridge:response-data r)))
      (check (format nil "minibuffer text now 'heXllo' (got ~s)"
                     (getf d :|text|))
             (equal (getf d :|text|) "heXllo")))

    ;; cursor should now be at 3 (after the inserted X)
    (let* ((r (limn:call "buffer/cursor-get" :|buffer-id| "*minibuffer*"))
           (d (limn/bridge:response-data r)))
      (check "cursor advanced to 3 after insert"
             (= (getf d :|offset|) 3)
             (format nil "got offset=~a" (getf d :|offset|))))

    ;; delete range [2, 4) → removes "Xl", leaving "helo"
    (let ((r (limn:call "buffer/delete"
                        :|buffer-id| "*minibuffer*"
                        :|from| 2 :|to| 4)))
      (check "buffer/delete returns ok"
             (eq (getf r :|ok|) t)))
    (let* ((r (limn:call "minibuffer/get"))
           (d (limn/bridge:response-data r)))
      (check (format nil "after delete, text is 'helo' (got ~s)"
                     (getf d :|text|))
             (equal (getf d :|text|) "helo")))

    ;; cursor-set out of range fails
    (let* ((r (handler-case
                  (limn:call "buffer/cursor-set"
                             :|buffer-id| "*minibuffer*"
                             :|offset| 999)
                (error (e) (list :|ok| :error :|caught| (format nil "~a" e)))))
           (ok-flag (getf r :|ok|)))
      (check "cursor-set offset out of range → ok=false"
             (or (eq ok-flag :false) (eq ok-flag :error))
             (format nil "got ~s" r)))

    ;; buffer/insert on mupdf buffer (b1) should fail
    (let* ((r (handler-case
                  (limn:call "buffer/insert"
                             :|buffer-id| "b1"
                             :|text| "X")
                (error (e) (list :|ok| :error :|caught| (format nil "~a" e)))))
           (ok-flag (getf r :|ok|)))
      (check "buffer/insert on mupdf buffer → ok=false"
             (or (eq ok-flag :false) (eq ok-flag :error))
             (format nil "got ~s" r)))

    (limn:call "minibuffer/close")
    (sleep 0.2)

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 19 buffer-edit primitives green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-be")
        (rename-file "/tmp/.limn/init.lisp.stash-be" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
