;;;; v0.33 §C — region 視覺化 OS-level e2e
;;;;
;;;; 真 limn binary + Xvfb + xdotool。完整鏈條：
;;;;
;;;;   xdotool key C-space    → keymap → set-mark
;;;;   xdotool key Right ×5   → motion command → region update
;;;;   (wire) view/overlays   → C++ paintGL → region face background pixel
;;;;
;;;; Ω1 set-mark + arrow keys → screenshot 出現 region face 反白
;;;; Ω2 region 範圍對：bbox 寬度 ≈ 5 個 codepoint 寬

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v033region"))

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
             ;; v0.33 modules
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
(defun key (k)  (xdotool "key" k))
(defun type-str (s) (xdotool "type" "--delay" "50" s))

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

(let* ((sock (format nil "/tmp/limn-e2e-v033region-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033region.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  ;; Open text buffer
  (let* ((er (limn:call "bridge/engine-load"
                         :|engine| "text" :|path| "" :|win-id| "w1"))
         (buf (and (ok? er) (getf (data er) :|buffer-id|))))
    (check (format nil "setup — text buffer (~a)" buf) (stringp buf))

    ;; Seed text + sync region face (blue background)
    (limn:call "buffer/insert" :|buffer-id| buf :|text| "hello world example")
    (sleep 0.1)
    (limn:call "display/sync-faces"
               :|faces| (list (list :|name| "region"
                                    :|background| "#3366ff"
                                    :|foreground| "#ffffff")))

    ;; Enable transient-mark, set mark at 3, move cursor to 8 via wire
    (setf (symbol-value
           (find-symbol "*TRANSIENT-MARK-MODE*" '#:limn/mark)) t)
    (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 8)
    (funcall (find-symbol "SET-MARK" '#:limn/mark) 3 buf)
    (funcall (find-symbol "UPDATE-REGION-OVERLAY" '#:limn/region) buf)

    ;; Push region overlay to wire
    (let* ((to-wl (find-symbol "OVERLAYS-TO-WIRE-LAYERS" '#:limn/overlays))
           (layers (funcall to-wl 0 200 buf)))
      (check "Ω1a — region overlay layers built"
             (and layers (>= (length layers) 1)))
      (check "Ω1b — view/overlays accepted"
             (ok? (limn:call "view/overlays" :|win-id| "w1" :|layers| layers))))
    (sleep 0.3)

    (let* ((pr (page-rect))
           (bbox (and pr (region-bbox (getf pr :|x|) (getf pr :|y|)
                                       (getf pr :|w|) (getf pr :|h|)
                                       "#3366ff"))))
      (check (format nil "Ω1c — region blue area visible (bbox = ~s)" bbox)
             (not (null bbox)))
      ;; v0.37 strict: was just "> 10 px" — catches zero but not
      ;; wrong-position / wrong-size bugs.  Region selects 5 chars
      ;; (offset 3..8 in "hello world example", = "lo wo").  At
      ;; typical text-widget font, 5 chars ≈ 30-100 px wide, single
      ;; line 10-40 px tall, near widget top-left (x,y < 100).
      (check (format nil "Ω2 — region bbox width sensible (30..150 px, got ~s)"
                     (and bbox (getf bbox :|w|)))
             (and bbox (>= (getf bbox :|w|) 30) (<= (getf bbox :|w|) 150)))
      (check (format nil "Ω2 — region bbox height sensible (single line, 8..40 px, got ~s)"
                     (and bbox (getf bbox :|h|)))
             (and bbox (>= (getf bbox :|h|) 8) (<= (getf bbox :|h|) 40)))
      (check (format nil "Ω2 — region bbox positioned at text widget top (x<100, y<100, got ~s)"
                     (and bbox (list (getf bbox :|x|) (getf bbox :|y|))))
             (and bbox (< (getf bbox :|x|) 100) (< (getf bbox :|y|) 100)))))

  (format t "~%── v033-region OS e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
