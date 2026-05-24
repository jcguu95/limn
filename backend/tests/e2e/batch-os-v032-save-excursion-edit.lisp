;;;; v0.32 — save-excursion 在真實 buffer 上 round-trip (OS-tier)
;;;;
;;;; 真實 limn binary + Xvfb + xdotool。覆蓋鏈條：
;;;;
;;;;   xdotool key      X server     Qt event loop     buffer/insert
;;;;        │              │              │              C++ cmd
;;;;        ▼              ▼              ▼                  │
;;;;   QXcbKeyEvent →  text-mode keymap →  self-insert      ▼
;;;;                                                  buffer-modified
;;;;                                                    wire event
;;;;                                                        │
;;;;                                          (limn/dispatch fan-out)
;;;;                                                        ▼
;;;;                                       limn/marker:process-insert
;;;;                                                        ▼
;;;;                                  v0.32 save-excursion's marker fixup
;;;;
;;;; Ω1 seed 11 字、point=5、save-excursion 包住 goto 0 + xdotool type "ABC"
;;;;    → 結束後 point 變 8（因為 save-excursion 在 point 前插了 3 字、
;;;;    marker 自動 fixup）。
;;;; Ω2 save-excursion 拋 error → point 仍 restore（不是 nil、不是亂跑）。
;;;; Ω3 save-excursion 多次 nested、最外層 point restore 對。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v032saveexc"))

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
             "limn-excursion.lisp"
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

(defun text-engine-load ()
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

;;; ── v0.32 helpers ──────────────────────────────────────────────────────

(defun xpkg () (find-package '#:limn/excursion))

(defun xsym (name) (and (xpkg) (find-symbol name (xpkg))))

(defun set-current-buf (buf)
  (let ((set (xsym "SET-BUFFER")))
    (when set (funcall set buf))))

(defun current-buf-id ()
  (let ((sym (xsym "CURRENT-BUFFER-ID")))
    (when sym (funcall sym))))

;;; ── session ─────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v032saveexc-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v032saveexc.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (when (find-package '#:limn/marker)
    (let ((install (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER" '#:limn/marker)))
      (when install (funcall install))))

  (unless (xpkg)
    (format t "✗ FATAL: limn/excursion not loaded — RED expected~%")
    (push "limn/excursion not loaded" *failures*))

  (let ((buf (text-engine-load)))
    (check (format nil "setup — opened text buffer (~a)" buf)
           (stringp buf))

    (unless buf
      (format t "✗ FATAL: text buffer not opened; aborting~%")
      (limn:stop)
      (sb-ext:process-kill proc 15)
      (sb-ext:process-wait proc)
      (sb-ext:exit :code 2))

    (when (xpkg) (set-current-buf buf))

;;; ── Seed ──────────────────────────────────────────────────────────────

    (format t "~%── Seed: 'hello world' (len 11) ──~%")
    (buf-insert buf "hello world")
    (sleep 0.1)
    (buf-cursor-set buf 5)
    (sleep 0.1)
    (check (format nil "text = 'hello world' (got ~s)" (buf-text buf))
           (equal (buf-text buf) "hello world"))
    (check (format nil "point = 5 (got ~a)" (buf-cursor buf))
           (eql 5 (buf-cursor buf)))

;;; ── Ω1: save-excursion + type-before-point → marker fixup ──────────

    (format t "~%── Ω1: save-excursion + type 'ABC' at 0 → point fixed up 5→8 ──~%")
    (let ((save-exc (xsym "SAVE-EXCURSION"))
          (goto     (xsym "GOTO-CHAR")))
      (cond
        ((not (and save-exc goto))
         (check "v0.32 save-excursion / goto-char symbols present" nil
                "RED: limn-excursion.lisp missing"))
        (t
         ;; body 用 wire 改 cursor + xdotool 打 3 字（self-insert at 0）
         (eval `(,save-exc
                 (limn:call "buffer/cursor-set"
                            :|buffer-id| ,buf :|offset| 0)
                 (sleep 0.1)
                 (type-str "ABC")
                 (sleep 0.3)))
         (let ((point-after (buf-cursor buf)))
           (check (format nil "point fixed up: 5+3=8 (got ~a)" point-after)
                  (eql 8 point-after)))
         (let ((text-after (buf-text buf)))
           (check (format nil "text now 'ABChello world' (got ~s)" text-after)
                  (equal text-after "ABChello world"))))))

;;; ── Ω2: save-excursion body errors → point still restored ──────────

    (format t "~%── Ω2: save-excursion + body error → point restored ──~%")
    (buf-cursor-set buf 4)
    (sleep 0.1)
    (let ((save-exc (xsym "SAVE-EXCURSION"))
          (before   (buf-cursor buf)))
      (cond
        ((not save-exc)
         (check "save-excursion present" nil "RED"))
        (t
         (handler-case
             (eval `(,save-exc
                     (limn:call "buffer/cursor-set"
                                :|buffer-id| ,buf :|offset| 0)
                     (error "intentional boom")))
           (error () nil))
         (let ((after (buf-cursor buf)))
           (check (format nil "point restored after error: ~a → ~a" before after)
                  (eql before after))))))

;;; ── Ω3: nested save-excursion — outer restore correct ───────────────

    (format t "~%── Ω3: nested save-excursion → outer point restore ──~%")
    (buf-cursor-set buf 6)
    (sleep 0.1)
    (let ((save-exc (xsym "SAVE-EXCURSION"))
          (before   (buf-cursor buf)))
      (cond
        ((not save-exc)
         (check "save-excursion present" nil "RED"))
        (t
         (eval `(,save-exc
                 (limn:call "buffer/cursor-set"
                            :|buffer-id| ,buf :|offset| 1)
                 (,save-exc
                  (limn:call "buffer/cursor-set"
                             :|buffer-id| ,buf :|offset| 12))))
         (let ((after (buf-cursor buf)))
           (check (format nil "outer point restored: ~a → ~a" before after)
                  (eql before after)))))))

  (format t "~%── v032 save-excursion e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
