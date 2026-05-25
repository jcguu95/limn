;;;; v0.33 §B — overlay before-string 視覺出現 / buffer/text 不含
;;;;
;;;; 鏈條：overlay-put 'before-string "▶ " 在 buffer 中段 → overlays-to-wire-layers
;;;; 加 text layer 在 overlay-start 之前的座標 → C++ paint 出此字串
;;;; → screenshot 找得到；但 buffer/text wire 回傳不含此 "▶"。
;;;;
;;;; Ω1 buffer/text 回傳長度不含 before-string
;;;; Ω2 screenshot 找得到 ▶（用 test/last-text-render 取最後一次 paint 的字串）

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v033bef"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
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

(let* ((sock (format nil "/tmp/limn-e2e-v033bef-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033bef.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)

  (let* ((er (limn:call "bridge/engine-load"
                         :|engine| "text" :|path| "" :|win-id| "w1"))
         (buf (and (ok? er) (getf (data er) :|buffer-id|))))
    (check (format nil "setup — text buf (~a)" buf) (stringp buf))

    (limn:call "buffer/insert" :|buffer-id| buf :|text| "hello world")
    (sleep 0.1)
    (let ((text-before (data (limn:call "buffer/text" :|buffer-id| buf))))
      (check (format nil "baseline buffer/text = 'hello world' (~s)"
                     (getf text-before :|text|))
             (equal "hello world" (getf text-before :|text|))))

    ;; 用 Lisp overlay API 設 before-string
    (let* ((mk  (find-symbol "MAKE-OVERLAY" '#:limn/overlays))
           (put (find-symbol "OVERLAY-PUT"  '#:limn/overlays))
           (to-wl (find-symbol "OVERLAYS-TO-WIRE-LAYERS" '#:limn/overlays))
           (ov  (funcall mk 6 6 buf)))
      (funcall put ov 'before-string "▶ ")
      (let ((layers (funcall to-wl 0 100 buf)))
        (check "wire layers built with before-string"
               (and layers (>= (length layers) 1)))
        (check "view/overlays accepted"
               (ok? (limn:call "view/overlays" :|win-id| "w1" :|overlays| layers)))))
    (sleep 0.3)

    ;; Ω1 buffer/text 仍乾淨
    (let* ((r (limn:call "buffer/text" :|buffer-id| buf))
           (txt (getf (data r) :|text|)))
      (check (format nil "Ω1 — buffer/text 仍 'hello world'（不含 ▶）(~s)" txt)
             (equal "hello world" txt)))

    ;; Ω2 paint 路徑：用 test/last-text-render 拿最後 paint 的 string
    (let* ((r (limn:call "test/last-text-render"))
           (d (data r))
           (rendered-text (and d (getf d :|text|))))
      (check (format nil "Ω2 — last text render 有 ▶ (~s)" rendered-text)
             (and (stringp rendered-text)
                  (search "▶" rendered-text)))))

  (format t "~%── v033-before-string-visual results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
