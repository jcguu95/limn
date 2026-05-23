;;;; Batch 16: K4 multi minor mode precedence at OS level.
;;;;
;;;; SPEC §9.1 約定：keymap lookup 順序為 minor (newest first) → major
;;;; → global。pure-Lisp unit test 已釘住 limn/mode:lookup-key 邏輯、
;;;; 這個 OS-level 版本驗 dispatch chain 真實透過 active mode-buffer
;;;; 走完該 stack。
;;;;
;;;; 需求：v0.6 SPEC keymap UX (:mode binding) 還沒實作、所以無法直接
;;;; 透過 limn:bind :mode 寫。改用 limn/keys:define-key 對 mode keymap
;;;; 直接操作。

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-prec"))

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

(let* ((sock (format nil "/tmp/limn-e2e-prec-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-prec.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

;;; ── K4: minor newest-first → major → global ──────────────────────

    (format t "~%── K4: minor newest-first → major → global ──~%")

    (defparameter cl-user::*k4-fired-by* nil)
    (defun k4-fire-cmd (label)
      (setf cl-user::*k4-fired-by* label))

    ;; Set up keymaps for global / major / minor-a / minor-b
    (let* ((global-km limn:*global-keymap*)
           ;; major mode "k4-major" with binding "z" → :major
           (major-km (limn/keys:make-keymap))
           ;; minor mode "k4-minor-a" with binding "z" → :minor-a
           (minor-a-km (limn/keys:make-keymap))
           ;; minor mode "k4-minor-b" without "z" binding (test fall-through)
           (minor-b-km (limn/keys:make-keymap)))

      (limn/keys:define-key global-km "z"
                            (lambda (ev) (declare (ignore ev))
                              (k4-fire-cmd :global)))
      (limn/keys:define-key major-km "z"
                            (lambda (ev) (declare (ignore ev))
                              (k4-fire-cmd :major)))
      (limn/keys:define-key minor-a-km "z"
                            (lambda (ev) (declare (ignore ev))
                              (k4-fire-cmd :minor-a)))

      (limn/mode:define-mode 'k4-major   :type :major)
      (limn/mode:define-mode 'k4-minor-a :type :minor)
      (limn/mode:define-mode 'k4-minor-b :type :minor)
      (setf (limn/mode:mode-keymap (limn/mode:find-mode 'k4-major))   major-km
            (limn/mode:mode-keymap (limn/mode:find-mode 'k4-minor-a)) minor-a-km
            (limn/mode:mode-keymap (limn/mode:find-mode 'k4-minor-b)) minor-b-km)

      ;; The wire-level active buffer needs a mode-buffer with this stack.
      ;; engine-load already created mb for b1; set its modes.
      (let ((mb (limn/runtime:find-mode-buffer "b1")))
        (check "K4 setup — b1 has mode-buffer" mb)
        (when mb
          (limn/mode:activate mb 'k4-major)
          ;; State 1: just major
          (setf cl-user::*k4-fired-by* nil)
          (xdotool "key" "--clearmodifiers" "z")
          (sleep 0.3)
          (check (format nil "K4 — only major → fired by :major (got ~s)"
                         cl-user::*k4-fired-by*)
                 (eq cl-user::*k4-fired-by* :major))

          ;; State 2: add minor-a (it has z binding) — should win over major
          (limn/mode:activate mb 'k4-minor-a)
          (setf cl-user::*k4-fired-by* nil)
          (xdotool "key" "--clearmodifiers" "z")
          (sleep 0.3)
          (check (format nil "K4 — minor-a active → fired by :minor-a (got ~s)"
                         cl-user::*k4-fired-by*)
                 (eq cl-user::*k4-fired-by* :minor-a))

          ;; State 3: add minor-b on top (no z binding) — minor-a still wins
          (limn/mode:activate mb 'k4-minor-b)
          (setf cl-user::*k4-fired-by* nil)
          (xdotool "key" "--clearmodifiers" "z")
          (sleep 0.3)
          (check (format nil "K4 — minor-b (no z) on top → minor-a still wins (got ~s)"
                         cl-user::*k4-fired-by*)
                 (eq cl-user::*k4-fired-by* :minor-a))

          ;; State 4: deactivate minor-a — major wins again
          (limn/mode:deactivate mb 'k4-minor-a)
          (setf cl-user::*k4-fired-by* nil)
          (xdotool "key" "--clearmodifiers" "z")
          (sleep 0.3)
          (check (format nil "K4 — minor-a out → major wins (got ~s)"
                         cl-user::*k4-fired-by*)
                 (eq cl-user::*k4-fired-by* :major)))))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 16 mode precedence green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-prec")
        (rename-file "/tmp/.limn/init.lisp.stash-prec" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
