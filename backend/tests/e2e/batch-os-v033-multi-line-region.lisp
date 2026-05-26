;;;; v0.33 §C — 跨行 region 高亮 OS-level e2e
;;;;
;;;; 第六個 OS-tier 測：mark 在 line 1、point 在 line 3 → region overlay
;;;; 應涵蓋三行；screenshot 該 face background bbox 高度 ≥ ~3 行像素。
;;;;
;;;; Ω1 region overlay 建立
;;;; Ω2 screenshot bbox 高度足以涵蓋多行（>= 30px 粗略門檻）

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v033ml"))

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

(let* ((sock (format nil "/tmp/limn-e2e-v033ml-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033ml.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)

  (let* ((er (limn:call "bridge/engine-load"
                         :|engine| "text" :|path| "" :|win-id| "w1"))
         (buf (and (ok? er) (getf (data er) :|buffer-id|))))
    (check (format nil "setup — text buf (~a)" buf) (stringp buf))

    ;; "alpha\nbeta\ngamma\ndelta" — 18 chars total, 3 newlines
    (limn:call "buffer/insert"
               :|buffer-id| buf
               :|text| (concatenate 'string
                                    "alpha" (string #\Newline)
                                    "beta"  (string #\Newline)
                                    "gamma" (string #\Newline)
                                    "delta"))
    (sleep 0.1)

    (limn:call "display/sync-faces"
               :|faces| (list (list :|name| "region"
                                    :|background| "#ff00aa"
                                    :|foreground| "#ffffff")))

    (setf (symbol-value
           (find-symbol "*TRANSIENT-MARK-MODE*" '#:limn/mark)) t)
    ;; mark at 0 (start of line 1), point at end of line 3 ("gamma" end)
    ;; = 5 + 1 + 4 + 1 + 5 = 16
    (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 16)
    (funcall (find-symbol "SET-MARK" '#:limn/mark) 0 buf)
    (funcall (find-symbol "UPDATE-REGION-OVERLAY" '#:limn/region) buf)

    (let ((ov (funcall (find-symbol "REGION-OVERLAY-FOR" '#:limn/region) buf)))
      (check "Ω1 — region overlay created" (not (null ov))))

    (let* ((to-wl (find-symbol "OVERLAYS-TO-WIRE-LAYERS" '#:limn/overlays))
           (layers (funcall to-wl 0 200 buf)))
      (check "wire layers built" (and layers (>= (length layers) 1)))
      (check "view/overlays accepted"
             (ok? (limn:call "view/overlays" :|win-id| "w1" :|layers| layers))))
    (sleep 0.3)

    (let* ((pr (data (limn:call "test/page-pixel-rect" :|win-id| "w1" :|page| 0)))
           (bbox (and pr (data (limn:call "test/region-bbox"
                                           :|x0| (getf pr :|x|)
                                           :|y0| (getf pr :|y|)
                                           :|x1| (+ (getf pr :|x|) (getf pr :|w|))
                                           :|y1| (+ (getf pr :|y|) (getf pr :|h|))
                                           :|match-color| "#ff00aa")))))
      (check (format nil "Ω2a — multi-line region bbox found (~s)" bbox)
             (not (null bbox)))
      (when bbox
        (check (format nil "Ω2b — bbox height >= 30 (3 lines, got ~A)"
                       (getf bbox :|h|))
               (>= (getf bbox :|h|) 30)))))

  (format t "~%── v033-multi-line-region results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
