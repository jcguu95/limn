;;;; v0.33b OS-level — viewport resize triggers reflow (Xvfb + xdotool)
;;;;
;;;; 鏈條：active region 後用 xdotool windowsize 改寬度 → 不需 Lisp 重 push
;;;; layer，C++ 端應自動 reflow → bbox 應改變但仍存在。
;;;;
;;;; Ω1 第一次 bbox（窄）找到
;;;; Ω2 resize 後 bbox 仍找到
;;;; Ω3 第二次 bbox 寬度 != 第一次（證明 C++ 端真的 reflow 了，非 stale paint）

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v033bresize"))

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

(defun xdotool-resize (w h)
  (sb-ext:run-program "xdotool"
                       (list "search" "--name" "Limn" "windowsize"
                             (write-to-string w) (write-to-string h))
                       :search t :wait t :output nil :error nil))

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

(defun page-rect ()
  (data (limn:call "test/page-pixel-rect" :|win-id| "w1" :|page| 0)))

(defun region-bbox (px py pw ph hexcolor)
  (data (limn:call "test/region-bbox"
                    :|x0| px :|y0| py
                    :|x1| (+ px pw) :|y1| (+ py ph)
                    :|match-color| hexcolor)))

(defun push-overlays-to-wire (buf)
  (let* ((to-wl (find-symbol "OVERLAYS-TO-WIRE-LAYERS" '#:limn/overlays))
         (layers (and to-wl (funcall to-wl 0 1000 buf))))
    (limn:call "view/overlays" :|win-id| "w1" :|layers| (or layers '()))))

(let* ((sock (format nil "/tmp/limn-e2e-v033bresize-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033bresize.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (funcall (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER" '#:limn/marker))

  ;; Narrow initial window. In Xvfb without a WM, xdotool windowsize
  ;; doesn't reach Qt's inner widgets, so pair with test/inject-resize.
  (xdotool-resize 200 500)
  (limn:call "test/inject-resize" :|win-id| "w1" :|width| 200 :|height| 500)
  (sleep 0.3)

  (let* ((er (limn:call "bridge/engine-load"
                         :|engine| "text" :|path| "" :|win-id| "w1"))
         (buf (and (ok? er) (getf (data er) :|buffer-id|))))
    (check (format nil "setup — text buffer (~a)" buf) (stringp buf))

    (limn:call "buffer/insert" :|buffer-id| buf
               :|text| "the quick brown fox jumps over a lazy dog yet again and again continuing to type more letters here")
    (sleep 0.2)
    (limn:call "display/sync-faces"
               :|faces| (list (list :|name| "region"
                                    :|background| "#ffcc00")))

    (setf (symbol-value
           (find-symbol "*TRANSIENT-MARK-MODE*" '#:limn/mark)) t)
    (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 95)
    (funcall (find-symbol "SET-MARK" '#:limn/mark) 0 buf)
    (funcall (find-symbol "UPDATE-REGION-OVERLAY" '#:limn/region) buf)
    (push-overlays-to-wire buf)
    (sleep 0.4)

    ;; Ω1 — bbox visible at narrow width
    (let* ((pr (page-rect))
           (bbox-narrow
             (and pr (region-bbox (getf pr :|x|) (getf pr :|y|)
                                  (getf pr :|w|) (getf pr :|h|)
                                  "#ffcc00"))))
      (check (format nil "Ω1 — region bbox at narrow (bbox=~s)" bbox-narrow)
             (not (null bbox-narrow)))

      ;; Widen the window — text widget should reflow, layout changes.
      ;; Critical: we do NOT re-push overlays here. C++ side must re-layout
      ;; the text-range layer automatically on next paint.
      (xdotool-resize 900 500)
      (limn:call "test/inject-resize" :|win-id| "w1" :|width| 900 :|height| 500)
      (sleep 0.5)

      (let* ((pr2 (page-rect))
             (bbox-wide
               (and pr2 (region-bbox (getf pr2 :|x|) (getf pr2 :|y|)
                                     (getf pr2 :|w|) (getf pr2 :|h|)
                                     "#ffcc00"))))
        ;; Ω2 — still visible
        (check (format nil "Ω2 — bbox still visible after resize (bbox=~s)"
                       bbox-wide)
               (not (null bbox-wide)))
        ;; Ω3 — bbox width changed (proves real reflow, not stale paint)
        (when (and bbox-narrow bbox-wide)
          (check (format nil "Ω3 — bbox geometry changed after resize (~A vs ~A)"
                         (getf bbox-narrow :|w|) (getf bbox-wide :|w|))
                 (or (/= (getf bbox-narrow :|w|) (getf bbox-wide :|w|))
                     (/= (getf bbox-narrow :|h|) (getf bbox-wide :|h|))))))))

  (format t "~%── v033b-viewport-resize-reflow results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
