;;;; v0.33 §A — theme switch live-updates overlay pixel color, OS-level e2e
;;;;
;;;; 鏈條：display/sync-faces 推新值 → view/overlays 重送 → C++ paintGL
;;;; lazy lookup → sample-pixel 反映新顏色。
;;;;
;;;; Ω1 baseline overlay uses face foreground → pixel = red
;;;; Ω2 sync-faces 改 foreground → 重送 → pixel = blue（驗 lazy lookup）

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

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

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun sync-face! (name fg)
  (limn:call "display/sync-faces"
             :|faces| (list (list :|name| name :|foreground| fg))))

(defun rect-with-face (win page face)
  (limn:call "view/overlays"
             :|win-id| win
             :|layers| (list (list :|type| "rect" :|page| page
                                    :|face| face
                                    :|x0| 0.1 :|y0| 0.1
                                    :|x1| 0.9 :|y1| 0.9
                                    :|opacity| 1.0))))

(defun sample-center (win page)
  (let* ((pr (data (limn:call "test/page-pixel-rect"
                               :|win-id| win :|page| page)))
         (cx (+ (getf pr :|x|) (round (/ (getf pr :|w|) 2))))
         (cy (+ (getf pr :|y|) (round (/ (getf pr :|h|) 2)))))
    (data (limn:call "test/sample-pixel" :|x| cx :|y| cy))))

(defun near? (px r g b &optional (tol 10))
  (and px
       (<= (abs (- (getf px :|r|) r)) tol)
       (<= (abs (- (getf px :|g|) g)) tol)
       (<= (abs (- (getf px :|b|) b)) tol)))

(let* ((sock (format nil "/tmp/limn-e2e-v033theme-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033theme.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)

  (let* ((er (limn:call "bridge/engine-load"
                         :|engine| "mupdf"
                         :|path| (b/ "tests/fixtures/test.pdf")
                         :|win-id| "w1"))
         (buf (and (ok? er) (getf (data er) :|buffer-id|))))
    (check (format nil "setup — buffer (~a)" buf) (stringp buf))

    ;; Ω1: baseline
    (format t "~%── Ω1: baseline red ──~%")
    (check "Ω1a — sync red" (ok? (sync-face! "pdf-search-match" "#ff0000")))
    (check "Ω1b — overlay set" (ok? (rect-with-face "w1" 0 "pdf-search-match")))
    (sleep 0.1)
    (let ((px (sample-center "w1" 0)))
      (check (format nil "Ω1c — pixel red (~s)" px)
             (near? px 255 0 0)))

    ;; Ω2: theme switch — sync new foreground value, re-push overlay,
    ;; pixel must follow
    (format t "~%── Ω2: theme switch → blue ──~%")
    (check "Ω2a — sync blue" (ok? (sync-face! "pdf-search-match" "#0000ff")))
    (check "Ω2b — overlay re-set" (ok? (rect-with-face "w1" 0 "pdf-search-match")))
    (sleep 0.1)
    (let ((px (sample-center "w1" 0)))
      (check (format nil "Ω2c — pixel now blue (~s)" px)
             (near? px 0 0 255))))

  (format t "~%── v033-theme-switch results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
