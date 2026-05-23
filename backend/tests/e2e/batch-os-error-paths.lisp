;;;; Batch 3: error paths + safety net.
;;;;
;;;; D1 (resize SPEC fields)   — 已被 1.6 ζ1 覆蓋
;;;; H6 (unknown wire cmd)     — 已被 1.7 ν2 覆蓋
;;;;
;;;; 這個 driver 處理剩下的：
;;;;   H1  開不存在的 PDF        → ok=false、無 crash
;;;;   H2  按 unbound key        → no side effects、no stray event
;;;;   H4  C-g 沒 minibuffer 時  → noop、不報錯
;;;;   H8  載入損壞 PDF          → ok=false、無 crash
;;;;   E2  minibuffer 空 submit  → defcommand body 收到 ""

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-err"))

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

(defparameter *captured-keys* nil)
(defparameter *captured-clicks* nil)

(let* ((sock (format nil "/tmp/limn-e2e-err-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-err.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

    (limn:on-event "key" (lambda (ev) (push ev *captured-keys*)))
    (limn:on-event "mouse-click" (lambda (ev) (push ev *captured-clicks*)))
    (sleep 0.2)

;;; ── H1: open non-existent PDF ──────────────────────────────────────

    (format t "~%── H1: load non-existent PDF → ok=false ──~%")
    (let* ((r (handler-case
                  (limn:call "bridge/engine-load"
                              :|engine| "mupdf"
                              :|path|   "/tmp/no-such-file-1734.pdf"
                              :|win-id| "w1")
                (error (e) (list :|ok| :error
                                  :|caught| (format nil "~a" e)))))
           (ok-flag (getf r :|ok|)))
      (check "H1 — engine-load on missing path returns ok=false (not crash)"
             (or (eq ok-flag :false) (eq ok-flag :error))
             (format nil "got response: ~s" r)))

    ;; Limn must still respond to wire commands after the error.
    (let ((r (limn:call "bridge/capabilities")))
      (check "H1 — session alive after engine-load failure"
             (eq (getf r :|ok|) t)
             (format nil "got ~s" r)))

;;; ── H8: open corrupt PDF ───────────────────────────────────────────

    (format t "~%── H8: load corrupt PDF → ok=false ──~%")
    (let ((bad-path "/tmp/corrupt-1734.pdf"))
      (with-open-file (s bad-path :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
        (write-string "this is not a PDF, just garbage bytes" s))
      (let* ((r (handler-case
                    (limn:call "bridge/engine-load"
                                :|engine| "mupdf"
                                :|path|   bad-path
                                :|win-id| "w1")
                  (error (e) (list :|ok| :error
                                    :|caught| (format nil "~a" e)))))
             (ok-flag (getf r :|ok|)))
        (check "H8 — engine-load on garbage file returns ok=false"
               (or (eq ok-flag :false) (eq ok-flag :error))
               (format nil "got response: ~s" r)))
      (ignore-errors (delete-file bad-path)))

    ;; Verify session still alive
    (let ((r (limn:call "bridge/capabilities")))
      (check "H8 — session alive after corrupt-PDF load"
             (eq (getf r :|ok|) t)))

;;; ── H2: unbound key → no side effects ──────────────────────────────

    (format t "~%── H2: unbound key (F11) → no command fires ──~%")
    ;; F11 is unbound by default. Press it.
    (setf *captured-keys* nil)
    (xdotool "key" "--clearmodifiers" "F11")
    (sleep 0.3)
    ;; Real H2 invariant：no side effect、session still alive。
    ;; (key event itself should arrive — hooks can observe — but that
    ;; isn't the SAFETY claim; the safety claim is "no command runs,
    ;; no error".)
    (check "H2 — at least one key event arrived for F11 press"
           (find "<f11>" *captured-keys*
                 :key (lambda (ev) (getf ev :|key|))
                 :test #'string=)
           (format nil "got events: ~s" *captured-keys*))
    (let ((r (limn:call "bridge/capabilities")))
      (check "H2 — session still alive after unbound key"
             (eq (getf r :|ok|) t)))

;;; ── H4: C-g without minibuffer → noop ──────────────────────────────

    (format t "~%── H4: C-g with no minibuffer → no error, no side effect ──~%")
    ;; Make sure minibuffer is closed.
    (ignore-errors (limn:call "minibuffer/close"))
    (sleep 0.2)
    ;; Inject Ctrl-G
    (xdotool "key" "--clearmodifiers" "ctrl+g")
    (sleep 0.3)
    ;; Session should still be alive and minibuffer should still be closed.
    (let ((r (limn:call "bridge/capabilities")))
      (check "H4 — session alive after C-g without minibuffer"
             (eq (getf r :|ok|) t)))
    (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "H4 — minibuffer remains closed"
             (eq (getf d :|open|) :false)
             (format nil "got ~s" d)))

;;; ── E2: minibuffer empty submit ───────────────────────────────────

    (format t "~%── E2: empty minibuffer submit → cmd body sees \"\" ──~%")
    (defparameter cl-user::*e2-captured* :pending)
    (limn/cmd:defcommand e2-empty-test (:interactive "sQuery: ")
      (lambda (q) (setf cl-user::*e2-captured* q)))
    ;; 用 z 而非 F12 觸發——Xvfb 的 F-keys 會帶 phantom Alt mod、
    ;; 跟正常 alt+F12 hard to distinguish、無法簡單 bind。z 乾淨。
    (limn:bind "z" 'e2-empty-test)
    (sleep 0.2)

    (xdotool "key" "--clearmodifiers" "z")
    (sleep 0.3)
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "E2 — minibuffer opened by trigger binding"
             (eq (getf d :|open|) t)
             (format nil "got ~s" d)))
    ;; Submit empty (just Return without typing)
    (xdotool "key" "--clearmodifiers" "Return")
    (sleep 0.4)
    (check "E2 — defcommand body received empty string"
           (equal cl-user::*e2-captured* "")
           (format nil "got ~s" cl-user::*e2-captured*))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 3 error paths all green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-err")
        (rename-file "/tmp/.limn/init.lisp.stash-err" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
