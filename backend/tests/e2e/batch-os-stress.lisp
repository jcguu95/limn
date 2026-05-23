;;;; Batch 7: stress / perf baseline — I2, I5, I3.
;;;;
;;;; I2 1000 keystroke 不 drop event
;;;; I5 5 個 Limn instance 各自獨立、不互相干擾
;;;; I3 long-running session、RSS 不單調成長（壓縮成 30 秒 burst loop）

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
  (with-open-file (s (format nil "/proc/~a/status" pid)
                     :direction :input :if-does-not-exist nil)
    (when s
      (loop for line = (read-line s nil nil) while line
            when (and (>= (length line) 6)
                      (string= "VmRSS:" (subseq line 0 6)))
              return (parse-integer line :junk-allowed t :start 6)))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-str"))

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

;;; ── I2: 1000 keystroke 不 drop event ─────────────────────────────

(format t "~%── I2: 1000 keystroke event 全到 ──~%")
(let* ((sock (format nil "/tmp/limn-e2e-stress-i2-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-stress-i2.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (let ((count 0))
      (limn:on-event "key" (lambda (ev) (declare (ignore ev)) (incf count)))
      (sleep 0.2)
      ;; xdotool key --repeat 1000 sends 1000 keypresses fast as it can
      (xdotool "key" "--repeat" "1000" "--delay" "1" "q")
      ;; Allow generous time for pump to drain all events
      (sleep 5.0)
      (check (format nil "I2 — got 1000 key events (actually ~a)" count)
             (= count 1000)
             (format nil "got ~a events, expected 1000" count))))
  (limn:stop)
  (handler-case (sb-ext:process-kill proc 15) (error () nil))
  (sleep 0.5))

;;; ── I3: long burst loop — RSS bounded growth ─────────────────────

(format t "~%── I3: 30s burst loop, RSS bounded ──~%")
(let* ((sock (format nil "/tmp/limn-e2e-stress-i3-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-stress-i3.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)
    (let ((pid (sb-ext:process-pid proc)))
      (let ((rss-start (rss-kb pid)))
        (format t "  RSS start: ~a kB~%" rss-start)
        ;; Burst: 30s of mixed view/get + view/set + minibuffer cycles
        (let ((deadline (+ (get-universal-time) 30))
              (loops 0))
          (loop while (< (get-universal-time) deadline) do
            (limn:call "view/get" :|win-id| "w1")
            (limn:call "view/set" :|win-id| "w1" :|page| (mod loops 5))
            (when (zerop (mod loops 10))
              (limn:call "minibuffer/open" :|prompt| "t: ")
              (limn:call "minibuffer/close"))
            (incf loops))
          (format t "  did ~a iterations in 30s~%" loops)
          (let* ((rss-end (rss-kb pid))
                 (growth (- rss-end rss-start))
                 (growth-pct (* 100.0 (/ growth (max rss-start 1)))))
            (format t "  RSS end: ~a kB (delta=~a kB, +~,1f%)~%"
                    rss-end growth growth-pct)
            (check (format nil "I3 — RSS growth <50% (actual ~,1f%)" growth-pct)
                   (< growth-pct 50.0)
                   "potential memory leak"))))))
  (limn:stop)
  (handler-case (sb-ext:process-kill proc 15) (error () nil))
  (sleep 0.5))

;;; ── I5: 5 個 limn instance 各自獨立 ─────────────────────────────

(format t "~%── I5: 5 Limn instances 同時跑、互不干擾 ──~%")
(let* ((limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (procs '())
       (socks '()))
  (unwind-protect
       (progn
         ;; Spawn 5 separate Limn binaries
         (dotimes (i 5)
           (let* ((sock (format nil "/tmp/limn-e2e-stress-i5-~a-~a"
                                (sb-posix:getpid) i))
                  (proc (sb-ext:run-program
                         limn-bin
                         (list "--test-mode" "--socket" sock)
                         :wait nil :search nil
                         :output (format nil "/tmp/limn-os-stress-i5-~a.log" i)
                         :if-output-exists :supersede :error :output)))
             (push proc procs)
             (push sock socks)))
         (sleep 1.5)
         ;; Verify all 5 sockets came up
         (let ((ready (count-if #'probe-file socks)))
           (check (format nil "I5 — all 5 Limn sockets ready (got ~a)" ready)
                  (= ready 5)))
         ;; Verify all 5 are responsive — connect SBCL to each, send capabilities
         (let ((alive 0))
           (dolist (sock (reverse socks))
             ;; Each connect is its own session; limn:stop between
             (handler-case
                 (progn
                   (limn:start sock)
                   (let ((r (limn:call "bridge/capabilities" :|timeout| 2.0)))
                     (when (eq (getf r :|ok|) t)
                       (incf alive)))
                   (limn:stop))
               (error (e)
                 (format t "  (instance failed: ~a)~%" e))))
           (check (format nil "I5 — all 5 instances responded (got ~a)" alive)
                  (= alive 5))))
    (dolist (p procs)
      (handler-case (sb-ext:process-kill p 15) (error () nil)))))

;;; ── final verdict ──────────────────────────────────────────────────

(let ((ok (null *failures*)))
  (format t "~%── VERDICT: ~a ──~%"
          (if ok "✓ PASS — batch 7 stress baseline green"
                 (format nil "✗ FAIL (~a):~{~%    ~a~}"
                         (length *failures*) (reverse *failures*))))
  (when (probe-file "/tmp/.limn/init.lisp.stash-str")
    (rename-file "/tmp/.limn/init.lisp.stash-str" "/tmp/.limn/init.lisp"))
  (sb-ext:exit :code (if ok 0 1)))
