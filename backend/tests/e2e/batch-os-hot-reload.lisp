;;;; Batch 18: G5 hot-reload init.lisp.
;;;;
;;;; Real Emacs convention：載入 init.lisp 後、可以再 (load file) 把
;;;; 新版本覆蓋舊版本、bindings 跟著切。釘住「Limn 真的能 hot reload」。

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

(defparameter *init-a-path* "/tmp/limn-hotreload-a.lisp")
(defparameter *init-b-path* "/tmp/limn-hotreload-b.lisp")

;; Write init A: binding 'z' fires :version-a
(with-open-file (s *init-a-path* :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
  (format s "(defparameter cl-user::*hr-fired-by* nil)
(limn/cmd:defcommand hr-cmd-a ()
  (lambda () (setf cl-user::*hr-fired-by* :version-a)))
(limn:bind \"z\" 'hr-cmd-a)"))

;; Write init B: binding 'z' fires :version-b
(with-open-file (s *init-b-path* :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
  (format s "(limn/cmd:defcommand hr-cmd-b ()
  (lambda () (setf cl-user::*hr-fired-by* :version-b)))
(limn:bind \"z\" 'hr-cmd-b)"))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-hr"))

(sb-posix:setenv "LIMN_INIT" *init-a-path* 1)

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

(let* ((sock (format nil "/tmp/limn-e2e-hr-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-hr.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

;;; ── Phase 1: init A loaded at start, z fires :version-a ─────────

    (format t "~%── G5: phase 1 — init A loaded ──~%")
    (check "G5 — init A 載入後 hr-cmd-a 存在"
           (limn/cmd:find-command 'hr-cmd-a))
    (xdotool "key" "--clearmodifiers" "z")
    (sleep 0.3)
    (check (format nil "G5 — z 觸發 :version-a (got ~s)"
                   cl-user::*hr-fired-by*)
           (eq cl-user::*hr-fired-by* :version-a))

;;; ── Phase 2: hot reload init B ──────────────────────────────────

    (format t "~%── G5: phase 2 — hot reload init B ──~%")
    (load *init-b-path*)
    (sleep 0.2)
    (check "G5 — init B 載入後 hr-cmd-b 存在"
           (limn/cmd:find-command 'hr-cmd-b))

    ;; z 應該 now fire :version-b (b 的 limn:bind 覆寫了 z)
    (setf cl-user::*hr-fired-by* nil)
    (xdotool "key" "--clearmodifiers" "z")
    (sleep 0.3)
    (check (format nil "G5 — z 觸發新 :version-b (got ~s)"
                   cl-user::*hr-fired-by*)
           (eq cl-user::*hr-fired-by* :version-b))

    ;; hr-cmd-a 應該還在（init A defcommand 沒被 reload 移除）
    (check "G5 — hr-cmd-a 仍在 (defcommand 不會被自動移除)"
           (limn/cmd:find-command 'hr-cmd-a))

;;; ── Phase 3: 直接 unbind 看 z 變 unbound ─────────────────────

    (format t "~%── G5: phase 3 — unbind z 後 z 不再 fire ──~%")
    (limn:unbind "z")
    (setf cl-user::*hr-fired-by* :NOT-FIRED)
    (xdotool "key" "--clearmodifiers" "z")
    (sleep 0.3)
    (check (format nil "G5 — z 被 unbind 後不再 fire (got ~s)"
                   cl-user::*hr-fired-by*)
           (eq cl-user::*hr-fired-by* :NOT-FIRED))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 18 hot reload green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (sb-posix:setenv "LIMN_INIT" "" 1)
      (ignore-errors (delete-file *init-a-path*))
      (ignore-errors (delete-file *init-b-path*))
      (when (probe-file "/tmp/.limn/init.lisp.stash-hr")
        (rename-file "/tmp/.limn/init.lisp.stash-hr" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
