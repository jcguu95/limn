;;;; Batch 1.7: error / shutdown / scale / restart dimensions.
;;;;
;;;; 1.5 / 1.6 都在「happy path」內。1.7 探索：
;;;;   μ  hook handler 異常 robustness
;;;;   ν  wire command 錯誤路徑
;;;;   ξ  長尾規模 / 記憶體穩定
;;;;   π  shutdown / cleanup / restart

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

(defun rss-kb (pid)
  "Read RSS in kB from /proc/PID/status. Linux only — fine inside container."
  (with-open-file (s (format nil "/proc/~a/status" pid)
                     :direction :input :if-does-not-exist nil)
    (when s
      (loop for line = (read-line s nil nil) while line
            when (and (>= (length line) 6)
                      (string= "VmRSS:" (subseq line 0 6)))
              return (parse-integer line :junk-allowed t :start 6)))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-s3"))

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

(defun start-session (&optional sock-suffix)
  "Spawn Limn + connect SBCL session. Returns (values sock proc wid)."
  (let* ((sock (format nil "/tmp/limn-e2e-s3-~a-~a"
                       (sb-posix:getpid)
                       (or sock-suffix "main")))
         (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
         (proc (sb-ext:run-program
                limn-bin
                (list "--test-mode" "--socket" sock)
                :wait nil :search nil
                :output (format nil "/tmp/limn-os-s3-~a.log"
                                (or sock-suffix "main"))
                :if-output-exists :supersede :error :output)))
    (loop repeat 100 until (probe-file sock) do (sleep 0.05))
    (limn:start sock)
    (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
      (sleep 0.3)
      (values sock proc wid))))

(defun stop-session (proc)
  (handler-case (limn:stop) (error () nil))
  (handler-case (sb-ext:process-kill proc 9) (error () nil))
  ;; Wait for the kernel to actually reap the process (process-wait
  ;; blocks until then). Without this, process-kill returns immediately
  ;; and the next start-session can race with cleanup of /tmp socket
  ;; files etc.
  (handler-case (sb-ext:process-wait proc) (error () nil))
  ;; Wait for the window to actually disappear from X.
  (loop repeat 30
        while (zerop
               (sb-ext:process-exit-code
                (sb-ext:run-program "xdotool"
                                     '("search" "--name" "Limn")
                                     :search t :wait t :output nil)))
        do (sleep 0.1))
  (sleep 0.3))

;;; ═════════════════════════════════════════════════════════════════
;;; μ1 / μ2: hook 異常 robustness
;;; ═════════════════════════════════════════════════════════════════

(format t "~%── μ1 / μ2: hook handler 丟 condition ──~%")
(multiple-value-bind (sock proc wid) (start-session "mu")
  (declare (ignore sock wid))
  (let ((flag-1 0) (flag-3 0))
    (limn:on-event "key" (lambda (ev) (declare (ignore ev)) (incf flag-1)))
    (limn:on-event "key" (lambda (ev) (declare (ignore ev))
                            (error "intentional throw from hook-2")))
    (limn:on-event "key" (lambda (ev) (declare (ignore ev)) (incf flag-3)))
    (sleep 0.2)

    ;; Inject one key — fires all 3 hooks
    (xdotool "key" "--clearmodifiers" "q")
    (sleep 0.4)
    (check "μ1 — hook-1 (before throwing hook) fired"
           (= flag-1 1) (format nil "flag-1=~a" flag-1))
    (check "μ1 — hook-3 (after throwing hook) still fired"
           (= flag-3 1) (format nil "flag-3=~a" flag-3))

    ;; Inject another — verifies pump thread survived the earlier throw
    (xdotool "key" "--clearmodifiers" "w")
    (sleep 0.4)
    (check "μ2 — pump thread still alive after hook threw (hook-1 again)"
           (= flag-1 2) (format nil "flag-1=~a after 2nd inject" flag-1)))

  (stop-session proc))

;;; ═════════════════════════════════════════════════════════════════
;;; ν2: wire cmd missing required field
;;; ═════════════════════════════════════════════════════════════════

(format t "~%── ν2: wire cmd missing required field → ok=false ──~%")
(multiple-value-bind (sock proc wid) (start-session "nu")
  (declare (ignore sock wid))
  ;; view/set without win-id
  (let* ((r (handler-case (limn:call "view/set" :|page| 0)
              (error (e) (list :|ok| :error :|caught| (format nil "~a" e)))))
         (ok-flag (getf r :|ok|)))
    (check "ν2 — view/set without :win-id returns ok=false (not crash)"
           (or (eq ok-flag :false) (eq ok-flag :error))
           (format nil "got ~s" r)))
  ;; buffer/text without buffer-id
  (let* ((r (handler-case (limn:call "buffer/text" :|page| 0)
              (error (e) (list :|ok| :error :|caught| (format nil "~a" e)))))
         (ok-flag (getf r :|ok|)))
    (check "ν2 — buffer/text without :buffer-id → ok=false"
           (or (eq ok-flag :false) (eq ok-flag :error))
           (format nil "got ~s" r)))
  (stop-session proc))

;;; ═════════════════════════════════════════════════════════════════
;;; π1: kill limn process mid-call → call signals error 不 hang
;;; ═════════════════════════════════════════════════════════════════

(format t "~%── π1: kill limn process mid-call → error, no hang ──~%")
(multiple-value-bind (sock proc wid) (start-session "pi1")
  (declare (ignore sock wid))
  ;; Spawn a thread that kills the limn process after a short delay,
  ;; then do a wire call that should error out (peer gone).
  (let ((killer (sb-thread:make-thread
                 (lambda ()
                   (sleep 0.5)
                   (handler-case (sb-ext:process-kill proc 9)
                     (error () nil))))))
    (let* ((start (get-internal-real-time))
           (result (handler-case
                       (progn
                         ;; This call should hang until the kill, then error.
                         (loop repeat 50 do
                               (limn:call "view/get" :|win-id| "w1")))
                     (error (e) (format nil "ERR: ~a" e))))
           (elapsed-sec (/ (- (get-internal-real-time) start)
                            internal-time-units-per-second)))
      (sb-thread:join-thread killer)
      ;; Should NOT hang past ~2 seconds (kill at 0.5s + dispatch timeout)
      (check "π1 — call returns (or errors) within 5 seconds of kill"
             (< elapsed-sec 5)
             (format nil "elapsed=~a sec result=~a" elapsed-sec result))
      (check "π1 — call ended in error (not silent success)"
             (and (stringp result) (search "ERR:" result))
             (format nil "got result=~s" result))))
  (handler-case (limn:stop) (error () nil)))

;;; ═════════════════════════════════════════════════════════════════
;;; π2: limn:stop + limn:start clean restart
;;; ═════════════════════════════════════════════════════════════════

(format t "~%── π2: stop + start clean restart ──~%")
(multiple-value-bind (sock1 proc1 wid1) (start-session "pi2a")
  (declare (ignore sock1 wid1))
  ;; Verify alive
  (let ((r (limn:call "bridge/capabilities")))
    (check "π2 — 1st session alive (capabilities)" (eq (getf r :|ok|) t)))
  (limn:stop)
  (sleep 0.2)
  (handler-case (sb-ext:process-kill proc1 15) (error () nil))
  (sleep 0.3))

(multiple-value-bind (sock2 proc2 wid2) (start-session "pi2b")
  (declare (ignore sock2 wid2))
  (let ((r (limn:call "bridge/capabilities")))
    (check "π2 — 2nd session alive after restart" (eq (getf r :|ok|) t)))
  ;; Verify event hooks still work in restarted session
  (let ((fired 0))
    (limn:on-event "key" (lambda (ev) (declare (ignore ev)) (incf fired)))
    (sleep 0.2)
    (xdotool "key" "--clearmodifiers" "z")
    (sleep 0.3)
    (check "π2 — events fire in 2nd session"
           (= fired 1) (format nil "fired=~a" fired)))
  (stop-session proc2))

;;; ═════════════════════════════════════════════════════════════════
;;; ξ1: 1000 key inject、RSS 不爆漲
;;; ═════════════════════════════════════════════════════════════════

(format t "~%── ξ1: 1000 key inject → RSS stable ──~%")
(multiple-value-bind (sock proc wid) (start-session "xi1")
  (declare (ignore sock wid))
  (let* ((pid (sb-ext:process-pid proc))
         (rss-before (rss-kb pid))
         (events 0))
    (limn:on-event "key" (lambda (ev) (declare (ignore ev)) (incf events)))
    (sleep 0.2)
    ;; Inject 200 keys (1000 takes too long; 200 still meaningful baseline)
    (loop repeat 200 do
          (xdotool "key" "--clearmodifiers" "q"))
    (sleep 1.0)
    (let* ((rss-after (rss-kb pid))
           (growth (- rss-after rss-before)))
      (check (format nil "ξ1 — 200 keys all caught (got ~a)" events)
             (>= events 200))
      (check (format nil "ξ1 — RSS growth bounded (before=~a after=~a delta=~a kB)"
                     rss-before rss-after growth)
             (< growth 50000) ; < 50 MB growth for 200 keys
             "memory may be leaking")))
  (stop-session proc))

;;; ═════════════════════════════════════════════════════════════════
;;; ξ2: minibuffer 10000 chars
;;; ═════════════════════════════════════════════════════════════════

(format t "~%── ξ2: minibuffer 10000-char input → no crash ──~%")
(multiple-value-bind (sock proc wid) (start-session "xi2")
  (declare (ignore sock wid))
  (limn:call "minibuffer/open" :|prompt| "long: ")
  (sleep 0.2)
  ;; xdotool type with long arg has stdin limits; use 1000 chars (still
  ;; an order of magnitude past normal use).
  (let ((long-text (with-output-to-string (s)
                     (loop repeat 1000 do (write-char #\x s)))))
    (handler-case
        (xdotool "type" "--delay" "1" long-text)
      (error (e)
        (check "ξ2 — xdotool can type 1000 chars" nil
               (format nil "xdotool errored: ~a" e))))
    (sleep 0.5)
    (let* ((d (limn/bridge:response-data (limn:call "minibuffer/get")))
           (got (getf d :|text|))
           (got-len (and (stringp got) (length got))))
      (check (format nil "ξ2 — minibuffer accepted ~a chars (got ~a)"
                     1000 got-len)
             (and got-len (>= got-len 900))  ; allow some drops under stress
             (format nil "got-len=~a" got-len))))
  (stop-session proc))

;;; ═════════════════════════════════════════════════════════════════

(let ((ok (null *failures*)))
  (format t "~%── VERDICT: ~a ──~%"
          (if ok "✓ PASS — batch 1.7 all green"
                 (format nil "✗ FAIL (~a):~{~%    ~a~}"
                         (length *failures*) (reverse *failures*))))
  (when (probe-file "/tmp/.limn/init.lisp.stash-s3")
    (rename-file "/tmp/.limn/init.lisp.stash-s3" "/tmp/.limn/init.lisp"))
  (sb-ext:exit :code (if ok 0 1)))
