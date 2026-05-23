;;;; Batch 5: Lisp runtime OS-level coverage — K2, K3, O1.
;;;;
;;;; K2 hook on event/key 真的 fires from OS-level keystrokes
;;;; K3 describe-key 對 demo binding 回正確 plist
;;;; O1 bridge/capabilities 返回非空 wire 命令 list

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-lrt"))

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

;; Load demo init.lisp so K3 has demo bindings to inspect.
(sb-posix:setenv "LIMN_INIT" (b/ "init.lisp.example") 1)

(let* ((sock (format nil "/tmp/limn-e2e-lrt-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-lrt.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

    ;; Load fixture so demo init.lisp's view/get etc. work.
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

;;; ── K2: hook on event/key fires on OS-level keystroke ─────────────

    (format t "~%── K2: hook on event/key fires on OS-level inject ──~%")
    (let ((hook-fired-with nil))
      (limn:on-event "key"
                     (lambda (ev) (push (getf ev :|key|) hook-fired-with)))
      (sleep 0.1)
      (xdotool "key" "--clearmodifiers" "q")
      (sleep 0.3)
      (check "K2 — hook fired for 'q'"
             (find "q" hook-fired-with :test #'string=)
             (format nil "captured: ~s" hook-fired-with))

      ;; Multiple keys → multiple hook fires
      (setf hook-fired-with nil)
      (xdotool "key" "--clearmodifiers" "a")
      (xdotool "key" "--clearmodifiers" "b")
      (xdotool "key" "--clearmodifiers" "c")
      (sleep 0.3)
      (check (format nil "K2 — hook fired 3 times for 'abc' (got ~a)"
                     (length hook-fired-with))
             (= (length hook-fired-with) 3))
      (check "K2 — hook saw 'a', 'b', 'c'"
             (and (find "a" hook-fired-with :test #'string=)
                  (find "b" hook-fired-with :test #'string=)
                  (find "c" hook-fired-with :test #'string=))
             (format nil "captured: ~s" hook-fired-with)))

;;; ── K3: describe-key 對 demo binding ─────────────────────────────

    (format t "~%── K3: describe-key for demo bindings ──~%")
    ;; demo init.lisp 應該已經 loaded（透過 $LIMN_INIT）
    (check "K3 setup — demo init.lisp loaded (next-page command exists)"
           (limn/cmd:find-command 'next-page))

    (let ((d (limn/introspect:describe-key "j"
                                            :global-keymap limn:*global-keymap*)))
      (check "K3 — describe-key \"j\" returns plist"
             d
             (format nil "got ~s" d))
      (when d
        (check "K3 — :action is a function (the wrapped next-page)"
               (functionp (getf d :action))
               (format nil "got :action=~s" (getf d :action)))
        (check "K3 — :layer is :global"
               (eq (getf d :layer) :global)
               (format nil "got :layer=~s" (getf d :layer)))))

    ;; describe-key for an unbound key
    (let ((d (limn/introspect:describe-key "<f9>"
                                            :global-keymap limn:*global-keymap*)))
      (check "K3 — describe-key for unbound key returns :layer :unbound"
             (and d (eq (getf d :layer) :unbound))
             (format nil "got ~s" d)))

;;; ── O1: bridge/capabilities returns wire command list ────────────

    (format t "~%── O1: bridge/capabilities returns non-trivial data ──~%")
    (let* ((r (limn:call "bridge/capabilities"))
           (d (limn/bridge:response-data r)))
      (check "O1 — capabilities returns ok=true"
             (eq (getf r :|ok|) t))
      (check "O1 — capabilities data is a plist"
             d
             (format nil "got ~s" r))
      ;; Per SPEC §7, capabilities returns engine + supports info.
      ;; Just sanity-check non-emptyness here (specific shape pinned
      ;; by integration tests already).
      (when d
        (let ((keys (loop for (k v) on d by #'cddr collect k)))
          (check (format nil "O1 — capabilities has multiple keys (got ~a)"
                         (length keys))
                 (> (length keys) 0)))))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 5 Lisp runtime OS coverage green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (sb-posix:setenv "LIMN_INIT" "" 1)
      (when (probe-file "/tmp/.limn/init.lisp.stash-lrt")
        (rename-file "/tmp/.limn/init.lisp.stash-lrt" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
