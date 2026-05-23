;;;; Batch 9: concurrency / async — L1 / L2 / L4.
;;;;
;;;; L1 render 進行中 + user 同時鍵盤：兩個都正確處理、不互相阻塞
;;;; L2 多 wire calls 並行（不同 thread 同時呼叫）→ 各自正確 response
;;;; L4 minibuffer/open 後立即注入鍵 → 鍵走 minibuffer-input 而非 key event
;;;;
;;;; 這層真實使用者每秒會撞到、但 unit / qt-e2e 都 sequential、抓不到。

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-conc"))

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

(defparameter *keys-captured* nil)
(defparameter *mb-input-captured* nil)

(let* ((sock (format nil "/tmp/limn-e2e-conc-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-conc.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

    (limn:on-event "key"
                   (lambda (ev) (push (getf ev :|key|) *keys-captured*)))
    (limn:on-event "minibuffer-input"
                   (lambda (ev) (push (getf ev :|text|) *mb-input-captured*)))
    (sleep 0.2)

;;; ── L1: render + key concurrent ───────────────────────────────────

    (format t "~%── L1: view/set (forces render) + key inject 同步 ──~%")
    (setf *keys-captured* nil)
    (let ((worker
            (sb-thread:make-thread
             (lambda ()
               ;; Force multiple renders rapidly
               (loop repeat 10 do
                     (limn:call "view/set" :|win-id| "w1" :|page| (random 5))
                     (sleep 0.02))))))
      ;; Meanwhile in main thread: inject keys
      (loop for c in '("a" "b" "c" "d" "e" "f" "g") do
            (xdotool "key" "--clearmodifiers" c)
            (sleep 0.03))
      (sb-thread:join-thread worker))
    (sleep 0.5)
    (check (format nil "L1 — all 7 keys delivered during render burst (got ~a)"
                   (length *keys-captured*))
           (= (length *keys-captured*) 7)
           (format nil "keys: ~s" (reverse *keys-captured*)))

;;; ── L2: multi wire calls parallel ─────────────────────────────────

    (format t "~%── L2: 3 threads simultaneous wire calls ──~%")
    (let* ((results (make-array 3 :initial-element nil))
           (threads
             (loop for i from 0 below 3
                   collect (let ((idx i))
                             (sb-thread:make-thread
                              (lambda ()
                                (let ((r (limn:call "bridge/capabilities")))
                                  (setf (aref results idx)
                                        (eq (getf r :|ok|) t)))))))))
      (dolist (th threads) (sb-thread:join-thread th))
      (check "L2 — all 3 parallel calls returned ok=true"
             (every #'identity (coerce results 'list))
             (format nil "results: ~s" (coerce results 'list))))

    ;; More stressful: 10 parallel calls
    (let* ((results (make-array 10 :initial-element nil))
           (threads
             (loop for i from 0 below 10
                   collect (let ((idx i))
                             (sb-thread:make-thread
                              (lambda ()
                                (let ((r (limn:call "view/get" :|win-id| "w1")))
                                  (setf (aref results idx)
                                        (eq (getf r :|ok|) t)))))))))
      (dolist (th threads) (sb-thread:join-thread th))
      (let ((n-success (count t (coerce results 'list))))
        (check (format nil "L2 — 10 parallel view/get all succeed (got ~a/10)"
                       n-success)
               (= n-success 10))))

;;; ── L4: minibuffer/open then immediate key ───────────────────────

    (format t "~%── L4: minibuffer/open + immediate key → goes to minibuffer-input ──~%")
    (setf *mb-input-captured* nil *keys-captured* nil)
    ;; The race: between (limn:call "minibuffer/open" ...) returning ok
    ;; AND the next xdotool key reaching the filter, the filter must
    ;; have updated its internal minibuffer-open state. Otherwise the
    ;; key would route as a normal 'key' event instead of
    ;; minibuffer-input.
    (limn:call "minibuffer/open" :|prompt| "race: ")
    ;; No sleep — push the timing race
    (xdotool "key" "--clearmodifiers" "x")
    (sleep 0.4)
    (check "L4 — 'x' went to minibuffer-input (not key event)"
           (and (= (length *mb-input-captured*) 1)
                (equal (first *mb-input-captured*) "x"))
           (format nil "mb-input=~s  key=~s"
                   *mb-input-captured* *keys-captured*))
    (check "L4 — no spurious key event for 'x' during minibuffer race"
           (not (find "x" *keys-captured* :test #'string=))
           (format nil "key events: ~s" *keys-captured*))
    (limn:call "minibuffer/close")
    (sleep 0.2)

    ;; Reverse race: minibuffer/close immediately followed by key
    (setf *mb-input-captured* nil *keys-captured* nil)
    (limn:call "minibuffer/open" :|prompt| "race2: ")
    (sleep 0.1)
    (limn:call "minibuffer/close")
    ;; Inject right after close
    (xdotool "key" "--clearmodifiers" "y")
    (sleep 0.4)
    (check "L4 — 'y' after minibuffer/close is a key event"
           (find "y" *keys-captured* :test #'string=)
           (format nil "key=~s  mb-input=~s"
                   *keys-captured* *mb-input-captured*))
    (check "L4 — 'y' did NOT go to minibuffer-input after close"
           (not (find "y" *mb-input-captured* :test #'string=))
           (format nil "mb-input=~s" *mb-input-captured*))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 9 concurrency green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-conc")
        (rename-file "/tmp/.limn/init.lisp.stash-conc" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
