;;;; v0.32 — narrow-to-region restricts search boundary (OS-tier)
;;;;
;;;; 真實 limn binary。驗證 narrow-to-region 真的把 Lisp 層的 search 縮在
;;;; 視窗內、widen 後恢復。
;;;;
;;;; 文字佈局（codepoint index）：
;;;;   "headXX target tailYY target"
;;;;    0         10         20
;;;;   兩個 "target"：一個在 ~10、一個在 ~22。
;;;;
;;;; Ω1 narrow-to-region 圍住第一個 target 但排除第二個（如 [0,15)），
;;;;    Lisp 端 (re-search-forward "target") 從 point=0 出發 → 找到第一個。
;;;; Ω2 narrow-to-region 圍住「兩個 target 之間的空隙」（如 [16,21)），
;;;;    從 point-min 出發 search "target" → 找不到（nil）。
;;;; Ω3 widen 後從 point=0 再 search "target" → 找到第一個 ~10。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v032narrow"))

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

(defun buf-insert (buf text)
  (limn:call "buffer/insert" :|buffer-id| buf :|text| text))

(defun buf-cursor-set (buf off)
  (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| off))

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

(defun xpkg () (find-package '#:limn/excursion))
(defun xsym (n) (and (xpkg) (find-symbol n (xpkg))))

(defun re-search-from-point-min (needle)
  "Use Lisp-side substring search clipped to (point-min) .. (point-max).
   Returns first match start offset (codepoint) or nil."
  (let* ((point-min (xsym "POINT-MIN"))
         (point-max (xsym "POINT-MAX"))
         (cur       (xsym "CURRENT-BUFFER-ID"))
         (buf-id    (and cur (funcall cur))))
    (when (and point-min point-max buf-id)
      (let* ((full (buf-text buf-id))
             (lo   (funcall point-min))
             (hi   (funcall point-max))
             (region (subseq full lo hi))
             (pos  (search needle region)))
        (and pos (+ lo pos))))))

;;; ── session ─────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v032narrow-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v032narrow.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (when (xpkg)
    (let ((install-bo (xsym "INSTALL-BUFFER-OPENED-HANDLER"))
          (install-vt (xsym "INSTALL-WIRE-VTABLE")))
      (when install-bo (funcall install-bo))
      (when install-vt (funcall install-vt))))

  (unless (xpkg)
    (format t "✗ FATAL: limn/excursion not loaded — RED expected~%")
    (push "limn/excursion not loaded" *failures*))

  (let ((buf (text-engine-load)))
    (check (format nil "setup — opened text buffer (~a)" buf)
           (stringp buf))
    (unless buf
      (limn:stop) (sb-ext:process-kill proc 15)
      (sb-ext:process-wait proc) (sb-ext:exit :code 2))

    (when (xpkg)
      (let ((reg (xsym "REGISTER-BUFFER")))
        (when reg (funcall reg (list :|buffer-id| buf) buf :name buf))))
    (sleep 0.1)

    (let ((set-buf (xsym "SET-BUFFER")))
      (when set-buf (funcall set-buf buf)))

;;; ── Seed: 'headXX target tailYY target' (27 chars) ─────────────────────

    (format t "~%── Seed: text with two 'target' occurrences ──~%")
    (buf-insert buf "headXX target tailYY target")
    (sleep 0.1)
    (buf-cursor-set buf 0)
    (sleep 0.1)
    (check (format nil "seeded text len=27 (got ~a)"
                   (length (or (buf-text buf) "")))
           (eql 27 (length (or (buf-text buf) ""))))
    ;; first 'target' starts at index 7, second at 21
    (let ((full (buf-text buf)))
      (check "first 'target' at index 7"  (eql 7  (search "target" full)))
      (check "second 'target' at index 21" (eql 21 (search "target" full :start2 8))))

;;; ── Ω1: narrow [0,15) — only first 'target' is reachable ─────────────

    (format t "~%── Ω1: narrow [0,15); search 'target' finds first one ──~%")
    (let ((narrow (xsym "NARROW-TO-REGION"))
          (widen  (xsym "WIDEN")))
      (cond
        ((not (and narrow widen)) (check "narrow/widen present" nil "RED"))
        (t
         (funcall narrow 0 15)
         (let ((hit (re-search-from-point-min "target")))
           (check (format nil "found first 'target' at 7 (got ~a)" hit)
                  (eql 7 hit)))
         (funcall widen))))

;;; ── Ω2: narrow [16,21) — second 'target' starts at 21, excluded ───────

    (format t "~%── Ω2: narrow [16,21); search 'target' returns nil ──~%")
    (let ((narrow (xsym "NARROW-TO-REGION"))
          (widen  (xsym "WIDEN")))
      (cond
        ((not (and narrow widen)) (check "narrow/widen present" nil "RED"))
        (t
         (funcall narrow 16 21)
         (let ((hit (re-search-from-point-min "target")))
           (check (format nil "no match within narrow region (got ~a)" hit)
                  (null hit)))
         (funcall widen))))

;;; ── Ω3: after widen, full-buffer search finds first 'target' ──────────

    (format t "~%── Ω3: widened; search 'target' finds 7 again ──~%")
    (let ((widen (xsym "WIDEN")))
      (when widen (funcall widen)))
    (let ((hit (re-search-from-point-min "target")))
      (check (format nil "widened search finds 'target' at 7 (got ~a)" hit)
             (eql 7 hit)))

    (ignore-errors (limn:call "buffer/close" :|buffer-id| buf)))

  (format t "~%── v032 narrow boundary e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
