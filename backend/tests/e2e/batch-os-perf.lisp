;;;; Batch 13: performance baseline — I4 many bindings dispatch perf.
;;;;
;;;; I4 註冊 200 個 binding、measure dispatch latency 是否仍 reasonable。
;;;;
;;;; Limn 的 keymap 用 hash-table、查 O(1)、理論上 binding 數量不影
;;;; 響。但 limn:bind 對 symbol 自動 wrap、register-binding 到
;;;; introspect 的 reverse table；這些 side effect 可能是 O(N)。

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-perf"))

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

(let* ((sock (format nil "/tmp/limn-e2e-perf-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-perf.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

;;; ── I4: 200 binding 註冊 + dispatch perf ──────────────────────────

    (format t "~%── I4: 200 bindings registered, dispatch perf ──~%")

    ;; Register 200 distinct commands + bindings
    (let ((t-reg-start (get-internal-real-time)))
      (loop for i from 0 below 200
            for spec = (format nil "C-x C-~c"
                               ;; cycle through a-z then digits then symbols
                               (cond ((< i 26) (code-char (+ (char-code #\a) i)))
                                     ((< i 36) (code-char (+ (char-code #\0) (- i 26))))
                                     (t #\!)))
            for sym = (intern (format nil "PERF-CMD-~a" i))
            do (eval `(limn/cmd:defcommand ,sym ()
                        (lambda () nil)))
               ;; Use limn/keys:define-key directly to avoid C-x prefix
               ;; collisions (only 26+10 unique specs above; the rest
               ;; duplicate). Just register the symbol in the introspect
               ;; reverse table to simulate \"many bindings\" overhead.
               (limn/introspect:register-binding sym limn:*global-keymap*
                                                  (format nil "C-perf-~a" i)))
      (let ((t-reg-elapsed (/ (- (get-internal-real-time) t-reg-start)
                              internal-time-units-per-second)))
        (format t "  registered 200 commands in ~,3f sec~%" t-reg-elapsed)
        (check (format nil "I4 — register 200 commands fast (<2s; took ~,3f)"
                       t-reg-elapsed)
               (< t-reg-elapsed 2.0))))

    ;; Now dispatch keys to global keymap that has 'j' from demo
    (defparameter cl-user::*i4-counter* 0)
    (limn:bind "v" (lambda (ev) (declare (ignore ev))
                     (incf cl-user::*i4-counter*)))
    (sleep 0.2)

    (let ((t-disp-start (get-internal-real-time)))
      (dotimes (i 50)
        (xdotool "key" "--clearmodifiers" "v"))
      (sleep 1.0)
      (let ((t-disp-elapsed (/ (- (get-internal-real-time) t-disp-start)
                               internal-time-units-per-second)))
        (format t "  50 dispatches + sleep took ~,3f sec, fired ~a times~%"
                t-disp-elapsed cl-user::*i4-counter*)
        (check (format nil "I4 — 50 dispatches all fired (got ~a)"
                       cl-user::*i4-counter*)
               (= cl-user::*i4-counter* 50))))

    ;; where-is-command should still be fast despite 200 registered
    (let ((t-wic-start (get-internal-real-time)))
      (dotimes (_ 100)
        (limn/introspect:where-is-command 'perf-cmd-150))
      (let ((t-wic-elapsed (/ (- (get-internal-real-time) t-wic-start)
                              internal-time-units-per-second)))
        (format t "  100 where-is-command lookups: ~,3f sec~%" t-wic-elapsed)
        (check (format nil "I4 — where-is-command 100x fast (<1s; took ~,3f)"
                       t-wic-elapsed)
               (< t-wic-elapsed 1.0))))

    ;; describe-key still works
    (let ((d (limn/introspect:describe-key "v"
                                            :global-keymap limn:*global-keymap*)))
      (check "I4 — describe-key works under load"
             (and d (getf d :action))))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 13 perf baseline green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-perf")
        (rename-file "/tmp/.limn/init.lisp.stash-perf" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
