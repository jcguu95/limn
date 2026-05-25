;;;; v0.33b OS-level — real key path triggers region clear during edit
;;;;
;;;; 與既有 v033 region-clear-on-edit 的差異：那個 explicit funcall
;;;; note-command；這個走真 xdotool key → keymap → dispatch → 自然
;;;; deactivate。驗 keymap-↔-command-name 連線真的對。
;;;;
;;;; Ω1 active region 視覺可見
;;;; Ω2 xdotool key X 後，**不**手動 note-command → region 仍 active？
;;;;    (這條 RED 等到 keymap dispatch 真的 fire note-command 才會通)
;;;; Ω3 update + push 後 region bbox 不見

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v033bedit"))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

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
(defun type-str (s) (xdotool "type" "--delay" "60" s))

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

(let* ((sock (format nil "/tmp/limn-e2e-v033bedit-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033bedit.log"
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
    (sleep 0.3)

    ;; Ω1 — region bbox visible
    (let* ((pr (page-rect))
           (bbox (and pr (region-bbox (getf pr :|x|) (getf pr :|y|)
                                       (getf pr :|w|) (getf pr :|h|)
                                       "#3366ff"))))
      (check (format nil "Ω1 — region visible before edit (bbox=~s)" bbox)
             (not (null bbox))))

    ;; Ω2 — real key press（不手動 note-command），靠 dispatch 自動 fire
    (type-str "X")
    (sleep 0.4)
    ;; 不主動 note-command, 也不主動 update — 看 keymap→dispatch 鏈條
    ;; 有沒有自動 deactivate mark。
    (let ((active (funcall (find-symbol "MARK-ACTIVE-P" '#:limn/mark) buf)))
      (check (format nil "Ω2 — mark auto-deactivated after key (active=~a)"
                     active)
             (not active)))

    ;; Ω3 — re-push overlays（dispatcher 應該也自動 update region）→
    ;; 視覺 bbox 不見
    (push-overlays-to-wire buf)
    (sleep 0.3)
    (let* ((pr (page-rect))
           (bbox (and pr (region-bbox (getf pr :|x|) (getf pr :|y|)
                                       (getf pr :|w|) (getf pr :|h|)
                                       "#3366ff"))))
      (check (format nil "Ω3 — region pixel gone after key edit (bbox=~s)"
                     bbox)
             (null bbox))))

  (format t "~%── v033b-edit-during-active-region results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
