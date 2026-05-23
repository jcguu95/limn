;;;; Batch 11: mode-specific behavior — N3 / N4.
;;;;
;;;; N1 (pdf-mode bindings 限 PDF buffer) 跟 K1 (keymap UX :mode) 都
;;;; blocked on v0.6 SPEC §9.1 keymap UX feature。這個 batch 處理
;;;; **可做的部分**：
;;;;
;;;; N3 define-mode 啟用時 on-enter / on-exit hook 真實觸發
;;;; N4 多 buffer 各自獨立 mode-buffer state、切 buffer mode 不相染

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-mb"))

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

(let* ((sock (format nil "/tmp/limn-e2e-mb-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-mb.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

;;; ── N3: mode on-enter / on-exit hook 真實觸發 ──────────────────

    (format t "~%── N3: mode :on-enter / :on-exit hooks fire ──~%")
    (defparameter cl-user::*mode-hooks-log* nil)
    (limn/mode:define-mode 'n3-mode-a
      :type :major
      :on-enter (lambda () (push :enter-a cl-user::*mode-hooks-log*))
      :on-exit  (lambda () (push :exit-a  cl-user::*mode-hooks-log*)))
    (limn/mode:define-mode 'n3-mode-b
      :type :major
      :on-enter (lambda () (push :enter-b cl-user::*mode-hooks-log*))
      :on-exit  (lambda () (push :exit-b  cl-user::*mode-hooks-log*)))
    (let ((buf (limn/mode:make-mode-buffer)))
      ;; activate a → :enter-a
      (limn/mode:activate buf 'n3-mode-a)
      ;; activate b → :exit-a (a was major), :enter-b
      (limn/mode:activate buf 'n3-mode-b))
    (let ((log (reverse cl-user::*mode-hooks-log*)))
      (check (format nil "N3 — hook order :enter-a :exit-a :enter-b (got ~s)" log)
             (equal log '(:enter-a :exit-a :enter-b))))

;;; ── N4: 多 buffer 各自獨立 mode-buffer state ──────────────────

    (format t "~%── N4: 多 buffer 各自獨立 mode-buffer ──~%")
    (limn/mode:define-mode 'n4-major :type :major)
    (limn/mode:define-mode 'n4-minor-x :type :minor)
    (limn/mode:define-mode 'n4-minor-y :type :minor)

    (let ((buf-a (limn/mode:make-mode-buffer))
          (buf-b (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf-a 'n4-major)
      (limn/mode:activate buf-a 'n4-minor-x)

      (limn/mode:activate buf-b 'n4-major)
      (limn/mode:activate buf-b 'n4-minor-y)

      (check "N4 — buf-a major = n4-major"
             (eq (limn/mode:major-mode buf-a) 'n4-major))
      (check "N4 — buf-a minors include n4-minor-x"
             (find 'n4-minor-x (limn/mode:minor-modes buf-a)))
      (check "N4 — buf-a minors do NOT include n4-minor-y"
             (not (find 'n4-minor-y (limn/mode:minor-modes buf-a))))
      (check "N4 — buf-b minors include n4-minor-y"
             (find 'n4-minor-y (limn/mode:minor-modes buf-b)))
      (check "N4 — buf-b minors do NOT include n4-minor-x"
             (not (find 'n4-minor-x (limn/mode:minor-modes buf-b))))

      ;; Deactivate minor-x from buf-a — should NOT affect buf-b
      (limn/mode:deactivate buf-a 'n4-minor-x)
      (check "N4 — after deactivate on buf-a, buf-b minors unchanged"
             (find 'n4-minor-y (limn/mode:minor-modes buf-b)))
      (check "N4 — after deactivate, buf-a minors empty"
             (null (limn/mode:minor-modes buf-a))))

;;; ── Bonus: runtime mode-buffer ↔ wire buffer-id 映射 ──────────

    (format t "~%── runtime: mode-buffer ↔ buffer-id mapping ──~%")
    ;; SPEC §9.1: 每個 wire-level buffer 對應一個 mode-buffer
    (let ((mb (limn/runtime:find-mode-buffer "b1")))
      (check "runtime — buffer-id b1 has a mode-buffer registered"
             mb
             (format nil "got ~s" mb))
      (when mb
        ;; SPEC §9.1: engine-load 成功 → runtime 建 mode-buffer +
        ;; 啟用 engine 預設 major mode。修了 emit_buffer_opened 帶
        ;; engine 欄位之後、這個 invariant 終於成立。
        (check "runtime — b1's major-mode is the engine default (fundamental-mode)"
               (eq (limn/mode:major-mode mb) 'limn/runtime:fundamental-mode)
               (format nil "got major=~s" (limn/mode:major-mode mb)))))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 11 mode-specific green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-mb")
        (rename-file "/tmp/.limn/init.lisp.stash-mb" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
