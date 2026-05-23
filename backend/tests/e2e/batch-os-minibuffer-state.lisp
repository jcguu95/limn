;;;; Batch 4: Minibuffer state primitives — E3 set-text, E4 set-prompt.
;;;;
;;;; E6 (long text)、E7 (C-g during open vs printable) 已被 1.7 ξ2 +
;;;; batch-os-cg + batch-os-type 蓋過。
;;;;
;;;; SPEC §5.4：
;;;;   minibuffer/set-text :text "..."  替換目前文字（completion/history）
;;;;   minibuffer/set-prompt :prompt    更新 prompt（dynamic prompt）

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-mbst"))

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

(let* ((sock (format nil "/tmp/limn-e2e-mbst-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-mbst.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

;;; ── E3: minibuffer/set-text 替換目前文字 ─────────────────────────

    (format t "~%── E3: minibuffer/set-text replaces current text ──~%")
    (limn:call "minibuffer/open" :|prompt| "test: ")
    (sleep 0.2)
    ;; Type a few characters first
    (xdotool "type" "--delay" "20" "abc")
    (sleep 0.3)
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "E3 setup — initial type 'abc' visible"
             (equal (getf d :|text|) "abc")
             (format nil "got ~s" d)))

    ;; Programmatically replace via set-text
    (let ((r (limn:call "minibuffer/set-text" :|text| "prefill")))
      (check "E3 — set-text returns ok=true"
             (eq (getf r :|ok|) t)))
    (sleep 0.2)
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "E3 — text now equals 'prefill'"
             (equal (getf d :|text|) "prefill")
             (format nil "got ~s" d)))

    ;; Continued typing should append to set text (not start over)
    (xdotool "type" "--delay" "20" "X")
    (sleep 0.3)
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "E3 — typing 'X' after set-text appends → 'prefillX'"
             (equal (getf d :|text|) "prefillX")
             (format nil "got ~s" d)))

    (limn:call "minibuffer/close")
    (sleep 0.2)

;;; ── E4: minibuffer/set-prompt 更新 prompt ───────────────────────

    (format t "~%── E4: minibuffer/set-prompt updates prompt mid-flow ──~%")
    (limn:call "minibuffer/open" :|prompt| "/")
    (sleep 0.2)
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "E4 setup — initial prompt '/'"
             (equal (getf d :|prompt|) "/")
             (format nil "got ~s" d)))

    (let ((r (limn:call "minibuffer/set-prompt" :|prompt| "Search: ")))
      (check "E4 — set-prompt returns ok=true"
             (eq (getf r :|ok|) t)))
    (sleep 0.2)
    (let ((d (limn/bridge:response-data (limn:call "minibuffer/get"))))
      (check "E4 — prompt now equals 'Search: '"
             (equal (getf d :|prompt|) "Search: ")
             (format nil "got ~s" d))
      (check "E4 — text unchanged by set-prompt"
             (equal (getf d :|text|) "")
             (format nil "got text=~s" (getf d :|text|))))

    ;; set-prompt while closed should fail (SPEC §5.4)
    (limn:call "minibuffer/close")
    (sleep 0.2)
    (let* ((r (handler-case (limn:call "minibuffer/set-prompt" :|prompt| "foo")
                (error (e) (list :|ok| :error
                                 :|caught| (format nil "~a" e)))))
           (ok-flag (getf r :|ok|)))
      (check "E4 — set-prompt on closed minibuffer returns ok=false"
             (or (eq ok-flag :false) (eq ok-flag :error))
             (format nil "got ~s" r)))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 4 minibuffer state primitives green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-mbst")
        (rename-file "/tmp/.limn/init.lisp.stash-mbst" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
