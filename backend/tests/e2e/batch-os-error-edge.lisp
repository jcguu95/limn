;;;; Batch 10: error / edge cases — H3 / H5 / E5.
;;;;
;;;; H3 multiple rapid C-g    → 不堆積、第 2 次以後是 noop
;;;; H5 malformed JSON 進 socket → backend 不 crash
;;;; E5 nested minibuffer open → 後一次 open 覆蓋前一次的 state？

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-eer"))

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

(let* ((sock (format nil "/tmp/limn-e2e-eer-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-eer.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

;;; ── H3: multiple rapid C-g ────────────────────────────────────────

    (format t "~%── H3: 5 rapid C-g — no error, no hang ──~%")
    ;; Set up a defcommand that interactively reads from minibuffer.
    (defparameter cl-user::*h3-result* :pending)
    (limn/cmd:defcommand h3-test (:interactive "sH3: ")
      (lambda (s) (setf cl-user::*h3-result* s)))
    (limn:bind "h" (lambda (ev)
                     (declare (ignore ev))
                     (handler-case (limn/cmd:call-interactively 'h3-test)
                       (limn/runtime:minibuffer-cancelled ()
                         (setf cl-user::*h3-result* :cancelled)))))
    (sleep 0.2)

    ;; Trigger the command (opens minibuffer + waits)
    (xdotool "key" "--clearmodifiers" "h")
    (sleep 0.3)
    ;; Now spam C-g 5 times rapidly
    (dotimes (i 5)
      (xdotool "key" "--clearmodifiers" "ctrl+g")
      (sleep 0.03))
    (sleep 0.5)

    (check "H3 — defcommand returned :cancelled (first C-g)"
           (eq cl-user::*h3-result* :cancelled)
           (format nil "got ~s" cl-user::*h3-result*))
    ;; subsequent C-g calls should noop (no canceller active anymore)
    (let ((r (limn:call "bridge/capabilities")))
      (check "H3 — session alive after 5 rapid C-g"
             (eq (getf r :|ok|) t)))
    ;; minibuffer closed
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "H3 — minibuffer is closed"
             (eq (getf d :|open|) :false)))

;;; ── H5: malformed JSON 進 socket ──────────────────────────────────

    (format t "~%── H5: malformed JSON → bridge resilient ──~%")
    ;; Send raw garbage directly through the socket. Use limn/client's
    ;; underlying stream.
    (let* ((client (limn/dispatch:session-client limn:*session*))
           (stream (funcall (find-symbol "CLIENT-STREAM" :limn/client) client)))
      (handler-case
          (progn
            (write-string "{this is not json at all" stream)
            (write-char #\Newline stream)
            (force-output stream))
        (error (e)
          (format t "  (raw write error: ~a)~%" e))))
    (sleep 0.5)
    ;; Backend must still respond after garbage
    (let ((r (limn:call "bridge/capabilities")))
      (check "H5 — session alive after malformed JSON injected"
             (eq (getf r :|ok|) t)
             (format nil "got ~s" r)))

    ;; Also send valid JSON but wrong shape (no 'cmd' field)
    (let* ((client (limn/dispatch:session-client limn:*session*))
           (stream (funcall (find-symbol "CLIENT-STREAM" :limn/client) client)))
      (write-string "{\"foo\":\"bar\"}" stream)
      (write-char #\Newline stream)
      (force-output stream))
    (sleep 0.3)
    (let ((r (limn:call "bridge/capabilities")))
      (check "H5 — session alive after JSON without cmd field"
             (eq (getf r :|ok|) t)
             (format nil "got ~s" r)))

;;; ── E5: nested minibuffer open ───────────────────────────────────

    (format t "~%── E5: 2nd minibuffer/open while 1st is open ──~%")
    (limn:call "minibuffer/open" :|prompt| "first: ")
    (sleep 0.2)
    ;; Type something into first minibuffer
    (xdotool "type" "--delay" "20" "abc")
    (sleep 0.3)
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "E5 setup — 1st minibuffer has 'abc'"
             (equal (getf d :|text|) "abc")
             (format nil "got ~s" d)))

    ;; Try to open a 2nd minibuffer while 1st is still open.
    ;; SPEC §5.4 doesn't explicitly say what happens; we pin current
    ;; behaviour.
    (let* ((r (handler-case (limn:call "minibuffer/open" :|prompt| "second: ")
                (error (e) (list :|ok| :error
                                  :|caught| (format nil "~a" e)))))
           (ok-flag (getf r :|ok|)))
      (format t "  2nd open response: ~s~%" r)
      ;; Either accept (overwrite first) or refuse — both reasonable.
      ;; Just check no crash + we get SOME response.
      (check "E5 — 2nd minibuffer/open returns a response (not hang/crash)"
             (or (eq ok-flag t) (eq ok-flag :false) (eq ok-flag :error))
             (format nil "got ~s" r)))

    ;; Whatever the semantics, capabilities should still work.
    (let ((r (limn:call "bridge/capabilities")))
      (check "E5 — session alive after nested open attempt"
             (eq (getf r :|ok|) t)))

    (ignore-errors (limn:call "minibuffer/close"))
    (sleep 0.2)

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 10 error edge green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-eer")
        (rename-file "/tmp/.limn/init.lisp.stash-eer" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
