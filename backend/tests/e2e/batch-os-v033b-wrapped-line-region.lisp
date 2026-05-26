;;;; v0.33b OS-level — wrapped line region (Xvfb + 真 widget wrap)
;;;;
;;;; 鏈條：窄 window → 塞長行（會被 Qt auto-wrap）→ set-mark + 跨 wrap point
;;;; cursor → text-range region overlay 應分多段、bbox 高度 > 一行高度。
;;;;
;;;; Ω1 region bbox 找得到（基本可見）
;;;; Ω2 bbox 高度 >= 兩行高度（證明 wrap 確實切了多段）
;;;; Ω3 buffer/codepoint-rects 對該 range 也回 >=2 rects

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v033bwrap"))

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

(defun xdotool (&rest args)
  (sb-ext:run-program "xdotool" args :search t :wait t
                       :output nil :error nil))

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

(let* ((sock (format nil "/tmp/limn-e2e-v033bwrap-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033bwrap.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (funcall (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER" '#:limn/marker))

  ;; Shrink window. In Xvfb without a WM, xdotool windowsize doesn't
  ;; propagate to Qt's inner widgets — pair it with test/inject-resize
  ;; to force the actual QPlainTextEdit resize. Both must happen so
  ;; environments with a real WM (where xdotool alone works) keep working.
  (sb-ext:run-program "xdotool"
                       '("search" "--name" "Limn" "windowsize" "300" "400")
                       :search t :wait t :output nil :error nil)
  (limn:call "test/inject-resize" :|win-id| "w1" :|width| 300 :|height| 400)
  (sleep 0.3)

  (let* ((er (limn:call "bridge/engine-load"
                         :|engine| "text" :|path| "" :|win-id| "w1"))
         (buf (and (ok? er) (getf (data er) :|buffer-id|))))
    (check (format nil "setup — text buffer (~a)" buf) (stringp buf))

    ;; Long single line that WILL wrap in 300px viewport
    (limn:call "buffer/insert" :|buffer-id| buf
               :|text|
               "the quick brown fox jumps over the lazy dog while another sentence continues")
    (sleep 0.2)

    (limn:call "display/sync-faces"
               :|faces| (list (list :|name| "region"
                                    :|background| "#ff00aa"
                                    :|foreground| "#ffffff")))

    ;; Active region across full line — guaranteed crosses wrap boundary
    (setf (symbol-value
           (find-symbol "*TRANSIENT-MARK-MODE*" '#:limn/mark)) t)
    (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 76)
    (funcall (find-symbol "SET-MARK" '#:limn/mark) 0 buf)
    (funcall (find-symbol "UPDATE-REGION-OVERLAY" '#:limn/region) buf)
    (push-overlays-to-wire buf)
    (sleep 0.4)

    ;; Ω1 — bbox visible
    (let* ((pr (page-rect))
           (bbox (and pr (region-bbox (getf pr :|x|) (getf pr :|y|)
                                       (getf pr :|w|) (getf pr :|h|)
                                       "#ff00aa"))))
      (check (format nil "Ω1 — wrapped region bbox visible (~s)" bbox)
             (not (null bbox)))
      ;; Ω2 — bbox height >= ~2 line heights. Default Xvfb font yields
      ;; ~14 px per line; threshold 25 keeps the assertion meaningful
      ;; (single line stays ≤16) without being pixel-fragile.
      (when bbox
        (check (format nil "Ω2 — bbox height >= 25 (2+ wrap lines, got ~A)"
                       (getf bbox :|h|))
               (>= (getf bbox :|h|) 25))))

    ;; Ω3 — buffer/codepoint-rects returns >= 2 rects for the same range
    (let* ((r (limn:call "buffer/codepoint-rects"
                          :|buf-id| buf :|win-id| "w1"
                          :|start| 0 :|end| 76))
           (rects (and (ok? r) (data r) (getf (data r) :|rects|))))
      (check (format nil "Ω3 — codepoint-rects returns >= 2 segments (got ~A)"
                     (and rects (length rects)))
             (and rects (>= (length rects) 2)))))

  (format t "~%── v033b-wrapped-line-region results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
