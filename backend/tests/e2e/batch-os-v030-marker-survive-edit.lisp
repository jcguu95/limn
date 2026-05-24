;;;; v0.30 §A — marker survives OS-level edit (end-to-end)
;;;;
;;;; 真實 limn binary + Xvfb + xdotool。覆蓋從 kernel keystroke 一路到
;;;; Lisp marker fixup 的完整鏈條：
;;;;
;;;;   xdotool key      X server     Qt event loop     buffer/insert
;;;;        │              │              │              C++ cmd
;;;;        ▼              ▼              ▼                  │
;;;;   QXcbKeyEvent →  Qt key handler →  text-mode keymap   ▼
;;;;                                          │       gap buffer mutation
;;;;                                          ▼              │
;;;;                                   self-insert-command   ▼
;;;;                                                  buffer-modified
;;;;                                                    wire event
;;;;                                                        │
;;;;                                          (limn/dispatch fan-out)
;;;;                                                        ▼
;;;;                                       limn/marker:%dispatch-event
;;;;                                                        ▼
;;;;                                            process-insert / -delete
;;;;
;;;; Ω1 set-mark 5；xdotool type "XY" at cursor=0 → mark 變 7
;;;; Ω2 marker-buffer 依然指對 buf-id（沒被 unlink）
;;;; Ω3 重複 inject：set-mark 後 type 5 個字 → mark += 5

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

;; Stash any pre-existing init.lisp so it doesn't fight our test setup.
(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v030marker"))

;; Load backend modules in-process. limn/marker + limn/local + limn/mark
;; for direct Lisp calls; the rest for limn:start + text-mode bootstrap
;; (so xdotool-typed chars route to self-insert-command).
(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-timer.lisp" "limn-process.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-undo.lisp" "limn-buffer-undo.lisp"
             "limn-keys.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp"
             "limn-text-mode.lisp"
             "limn-marker.lisp"
             "limn-local.lisp"
             "limn-mark.lisp"
             "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun text-engine-load ()
  "Open a text-engine buffer. Returns buffer-id or nil."
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "text" :|path| "" :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun buf-text (buf)
  (let ((r (limn:call "buffer/text" :|buffer-id| buf)))
    (and (ok? r) (getf (data r) :|text|))))

(defun buf-cursor (buf)
  (let ((r (limn:call "buffer/cursor-get" :|buffer-id| buf)))
    (and (ok? r) (getf (data r) :|offset|))))

(defun buf-cursor-set (buf off)
  (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| off))

(defun buf-insert (buf text)
  (limn:call "buffer/insert" :|buffer-id| buf :|text| text))

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

(defun mark-of (buf)
  (funcall (find-symbol "MARK" '#:limn/mark) buf))

(defun set-mark-at (pos buf)
  (funcall (find-symbol "SET-MARK" '#:limn/mark) pos buf))

;;; ── session ─────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v030marker-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v030marker.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  ;; bootstrap is supposed to have called install-buffer-modified-handler;
  ;; call again here defensively in case the limn:start ordering hasn't.
  (funcall (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER" '#:limn/marker))

  (let ((buf (text-engine-load)))
    (check (format nil "setup — opened text buffer (~a)" buf)
           (stringp buf))

    (unless buf
      (format t "✗ FATAL: text-engine buffer not opened; aborting~%")
      (limn:stop)
      (sb-ext:process-kill proc 15)
      (sb-ext:process-wait proc)
      (sb-ext:exit :code 2))

;;; ── Seed buffer with "hello world" via wire (faster than xdotool) ──

    (format t "~%── Seed buffer with 'hello world' ──~%")
    (buf-insert buf "hello world")
    (sleep 0.1)
    (check (format nil "buffer text = 'hello world' (got ~s)" (buf-text buf))
           (equal (buf-text buf) "hello world"))

;;; ── Ω1: set-mark 5; xdotool type "XY" at cursor=0 → mark = 7 ──

    (format t "~%── Ω1: set-mark 5; type 'XY' at cursor=0 → mark=7 ──~%")
    (buf-cursor-set buf 5)
    (set-mark-at 5 buf)
    (check (format nil "initial mark = 5 (got ~a)" (mark-of buf))
           (eql 5 (mark-of buf)))
    ;; cursor to 0, then inject 'X' 'Y' through kernel
    (buf-cursor-set buf 0)
    (sleep 0.1)
    (type-str "XY")
    (sleep 0.3)   ; give event loop time for both keystrokes + fixup
    (let ((text-after (buf-text buf))
          (mark-after (mark-of buf)))
      (check (format nil "buffer text now starts with 'XY' (got ~s)" text-after)
             (and (stringp text-after)
                  (search "XY" text-after :start2 0 :end2 (min 4 (length text-after)))))
      (check (format nil "mark adjusted 5 → 7 (got ~a)" mark-after)
             (eql 7 mark-after)))

;;; ── Ω2: marker-buffer still points to the same buf-id ──────────

    (format t "~%── Ω2: marker still bound to buffer ──~%")
    (let* ((bm-pkg (find-package '#:limn/mark))
           (bufs (when bm-pkg
                   (symbol-value (find-symbol "*BUFS*" bm-pkg))))
           (state (and bufs (gethash buf bufs)))
           (mark-obj (and state (funcall (find-symbol "BM-MARK" bm-pkg) state)))
           (mpkg (find-package '#:limn/marker))
           (mbuf-of (and mpkg (find-symbol "MARKER-BUFFER" mpkg)))
           (mbuf (and mark-obj mbuf-of (funcall mbuf-of mark-obj))))
      (check (format nil "internal mark is a marker bound to buf-id ~a" buf)
             (equal mbuf buf)))

;;; ── Ω3: type 5 more chars before mark → mark += 5 ──────────────

    (format t "~%── Ω3: type 5 chars at cursor=0 → mark += 5 ──~%")
    (let ((before (mark-of buf)))
      (buf-cursor-set buf 0)
      (sleep 0.1)
      (type-str "abcde")
      (sleep 0.4)
      (let ((after (mark-of buf)))
        (check (format nil "mark advanced by 5 (~a → ~a)" before after)
               (eql (+ before 5) after)))))

  (format t "~%── v030-marker e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
