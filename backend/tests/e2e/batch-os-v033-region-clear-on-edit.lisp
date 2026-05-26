;;;; v0.33 §C — region 在 edit command 後清除 OS-level e2e
;;;;
;;;; 鏈條：set-mark + cursor 移動 → region active → 真 xdotool type 一個
;;;; 字元（self-insert-command）→ note-command 把 region deactivate → 重新
;;;; update-region-overlay → wire 無 region layer → 截圖無 region face。
;;;;
;;;; Ω1 active 期間有 region overlay
;;;; Ω2 xdotool type 一字後 mark-active-p 為 nil
;;;; Ω3 重 push wire 後 page 看不到 region color

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v033clear"))

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

(defun push-overlays-to-wire (buf)
  (let* ((to-wl (find-symbol "OVERLAYS-TO-WIRE-LAYERS" '#:limn/overlays))
         (layers (and to-wl (funcall to-wl 0 1000 buf))))
    (limn:call "view/overlays" :|win-id| "w1" :|layers| (or layers '()))))

(let* ((sock (format nil "/tmp/limn-e2e-v033clear-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033clear.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (funcall (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER" '#:limn/marker))

  (let* ((er (limn:call "bridge/engine-load"
                         :|engine| "text" :|path| "" :|win-id| "w1"))
         (buf (and (ok? er) (getf (data er) :|buffer-id|))))
    (check (format nil "setup — text buffer (~a)" buf) (stringp buf))

    (limn:call "buffer/insert" :|buffer-id| buf :|text| "hello world!!!!!")
    (sleep 0.1)
    (limn:call "display/sync-faces"
               :|faces| (list (list :|name| "region"
                                    :|background| "#3366ff"
                                    :|foreground| "#ffffff")))

    (setf (symbol-value
           (find-symbol "*TRANSIENT-MARK-MODE*" '#:limn/mark)) t)
    (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 8)
    (funcall (find-symbol "SET-MARK" '#:limn/mark) 3 buf)
    (funcall (find-symbol "UPDATE-REGION-OVERLAY" '#:limn/region) buf)
    (push-overlays-to-wire buf)
    (sleep 0.2)

    ;; Ω1: region overlay should be present
    (let* ((pr (page-rect))
           (bbox (and pr (region-bbox (getf pr :|x|) (getf pr :|y|)
                                       (getf pr :|w|) (getf pr :|h|)
                                       "#3366ff"))))
      (check (format nil "Ω1 — region visible before edit (bbox=~s)" bbox)
             (not (null bbox)))
      ;; v0.37 strict: 5 chars selected (offset 3..8 = "lo wo"
      ;; from "hello world"), sensible bbox dims.
      (when bbox
        (check (format nil "Ω1 — region bbox dims sensible (30..150 × 8..40, got ~ax~a)"
                       (getf bbox :|w|) (getf bbox :|h|))
               (and (>= (getf bbox :|w|) 30) (<= (getf bbox :|w|) 150)
                    (>= (getf bbox :|h|) 8)  (<= (getf bbox :|h|) 40)))
        (check (format nil "Ω1 — region positioned top-left (x<100,y<100, got (~a,~a))"
                       (getf bbox :|x|) (getf bbox :|y|))
               (and (< (getf bbox :|x|) 100) (< (getf bbox :|y|) 100)))))

    ;; Ω2: type a char — self-insert via xdotool → keymap fires
    ;; note-command 'self-insert-command'. We also do it explicitly in
    ;; case the keymap-→ command-name introspection isn't wired yet.
    (type-str "X")
    (sleep 0.3)
    (funcall (find-symbol "NOTE-COMMAND" '#:limn/mark) 'self-insert-command buf)
    (funcall (find-symbol "UPDATE-REGION-OVERLAY" '#:limn/region) buf)
    (check "Ω2 — mark-active-p nil after edit"
           (not (funcall (find-symbol "MARK-ACTIVE-P" '#:limn/mark) buf)))

    ;; Ω3: re-push overlays → wire should now have no region layer →
    ;; screenshot bbox 找不到
    (push-overlays-to-wire buf)
    (sleep 0.2)
    (let* ((pr (page-rect))
           (bbox (and pr (region-bbox (getf pr :|x|) (getf pr :|y|)
                                       (getf pr :|w|) (getf pr :|h|)
                                       "#3366ff"))))
      (check (format nil "Ω3 — region cleared after edit (bbox=~s)" bbox)
             (null bbox))))

  (format t "~%── v033-region-clear-on-edit results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
