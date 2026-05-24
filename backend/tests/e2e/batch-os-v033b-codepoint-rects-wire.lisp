;;;; v0.33b OS-level — direct buffer/codepoint-rects wire invocation
;;;;
;;;; 鏈條：開 text buffer → 塞已知文字 → 直接 invoke buffer/codepoint-rects
;;;; 拿幾何 → 驗 rects 數量、y 軸單調、寬度為正。
;;;;
;;;; Ω1 :ok = t、rects 是 list
;;;; Ω2 多行文字 → rects >= line-count
;;;; Ω3 y 單調遞增（後續 rect 不會 y 比前面小）
;;;; Ω4 每個 rect width > 0, height > 0
;;;; Ω5 限制範圍（短 range）→ rects 較少（不會 over-return）

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v033bcprects"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-timer.lisp" "limn-process.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-undo.lisp" "limn-buffer-undo.lisp"
             "limn-keys.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp"
             "limn-text-mode.lisp"
             "limn-marker.lisp" "limn-local.lisp" "limn-mark.lisp"
             "limn-face.lisp"
             "limn-overlays.lisp" "limn-region.lisp"
             "limn.lisp"))
  (handler-case (load (b/ f))
    (error (e) (format t "  !! skipped ~A: ~A~%" f e))))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool" '("search" "--name" "Limn")
                                             :search t :wait t
                                             :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
          do (return found)
        do (sleep 0.1)))

(defun rects-of (buf start end)
  (let* ((r (limn:call "buffer/codepoint-rects"
                        :|buf-id| buf :|win-id| "w1"
                        :|start| start :|end| end)))
    (values (ok? r)
            (and (ok? r) (data r) (getf (data r) :|rects|)))))

(let* ((sock (format nil "/tmp/limn-e2e-v033bcprects-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033bcprects.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (let* ((er (limn:call "bridge/engine-load"
                         :|engine| "text" :|path| "" :|win-id| "w1"))
         (buf (and (ok? er) (getf (data er) :|buffer-id|))))
    (check (format nil "setup — text buffer (~a)" buf) (stringp buf))

    ;; Three lines, easy to verify
    (limn:call "buffer/insert" :|buffer-id| buf
               :|text| "alpha
beta
gamma")
    (sleep 0.2)

    ;; Ω1 — basic call works
    (multiple-value-bind (success rects) (rects-of buf 0 16)
      (check "Ω1 — ok = t, rects is list"
             (and success (listp rects))
             (format nil "ok=~a rects=~s" success rects))

      ;; Ω2 — at least one rect per line
      (check (format nil "Ω2 — 3 lines → >=3 rects (got ~A)"
                     (and rects (length rects)))
             (and rects (>= (length rects) 3)))

      ;; Ω3 — y monotonic
      (when (and rects (>= (length rects) 2))
        (let ((monotonic t)
              (prev-y -1))
          (dolist (rr rects)
            (let* ((r (getf rr :|rect|))
                   (y (second r)))
              (when (< y prev-y) (setf monotonic nil))
              (setf prev-y y)))
          (check "Ω3 — y monotonic across rects" monotonic)))

      ;; Ω4 — every rect has positive w/h
      (when rects
        (let ((all-positive t))
          (dolist (rr rects)
            (let* ((r (getf rr :|rect|))
                   (x0 (first r)) (y0 (second r))
                   (x1 (third r)) (y1 (fourth r)))
              (unless (and (> x1 x0) (> y1 y0))
                (setf all-positive nil))))
          (check "Ω4 — every rect has w>0, h>0" all-positive))))

    ;; Ω5 — short range returns fewer rects
    (multiple-value-bind (success-short rects-short) (rects-of buf 0 5)
      (declare (ignore success-short))
      (multiple-value-bind (success-long rects-long) (rects-of buf 0 16)
        (declare (ignore success-long))
        (check (format nil "Ω5 — short range fewer rects (~A vs ~A)"
                       (and rects-short (length rects-short))
                       (and rects-long  (length rects-long)))
               (and rects-short rects-long
                    (<= (length rects-short) (length rects-long)))))))

  (format t "~%── v033b-codepoint-rects-wire results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
