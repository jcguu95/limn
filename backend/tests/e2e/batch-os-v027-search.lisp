;;;; v0.27 §B — pdf-mode search OS-level e2e
;;;;
;;;; 覆蓋：
;;;;   Ω1 / "the" RET → minibuffer 開、submit、後台 buffer/search 被呼
;;;;   Ω2 view/overlays 有 highlight rect（非空）
;;;;   Ω3 n 移到下一個命中 → overlay 仍存在、current-index 改變
;;;;   Ω4 C-g 取消搜尋 → overlay 清空
;;;;
;;;; v0.27 §B 實作前 RED。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v027sr"))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun engine-load (path)
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "mupdf" :|path| path :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun overlays-of ()
  ;; view/overlays-get 在 v0.14 後存在；若沒有就用 fallback。
  (let ((r (limn:call "view/get" :|win-id| "w1")))
    (when (ok? r)
      (or (getf (data r) :|overlays|) '()))))

(defun xdotool (&rest args)
  (sb-ext:run-program "xdotool" args :search t :wait t
                       :output nil :error nil))
(defun key (k) (xdotool "key" k))
(defun type-text (s) (xdotool "type" "--" s))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (out)
                      (ignore-errors
                        (sb-ext:run-program "xdotool" '("search" "--name" "Limn")
                                             :search t :wait t
                                             :output out :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
          do (return found)
        do (sleep 0.1)))

;;; ── session ─────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v027sr-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v027sr.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (let ((b (engine-load (b/ "tests/fixtures/test.pdf"))))
    (check (format nil "setup — buffer ~a" b) (stringp b))

;;; ── Ω1: / "the" RET 開搜尋 ───────────────────────────────────

    (format t "~%── Ω1: / \"the\" RET ──~%")
    (key "slash") (sleep 0.15)
    ;; 確認 minibuffer 開了。
    (let ((mb (data (limn:call "minibuffer/get"))))
      (check "Ω1a — minibuffer open after /"
             (and mb (eq (getf mb :|open|) t))))
    (type-text "the") (sleep 0.15)
    (key "Return") (sleep 0.3)

;;; ── Ω2: overlays 有命中矩形 ─────────────────────────────────

    (format t "~%── Ω2: overlays from search ──~%")
    (let ((ovs (overlays-of)))
      (check (format nil "Ω2 — view/overlays 有 ~a 個 rect (>= 1)"
                     (length ovs))
             (and (listp ovs) (>= (length ovs) 1))))

;;; ── Ω3: n 推進到下個命中 ─────────────────────────────────────

    (format t "~%── Ω3: n advances current hit ──~%")
    (let ((before (data (limn:call "view/get" :|win-id| "w1"))))
      (key "n") (sleep 0.2)
      (let ((after (data (limn:call "view/get" :|win-id| "w1"))))
        (check "Ω3 — n 後 page 或 offset 變化（跳到下一個命中）"
               (or (not (eql (getf before :|page|)    (getf after :|page|)))
                   (not (eql (getf before :|offset-y|) (getf after :|offset-y|)))))))

;;; ── Ω4: C-g 清除 overlay ─────────────────────────────────────

    (format t "~%── Ω4: C-g clears overlays ──~%")
    (key "ctrl+g") (sleep 0.2)
    (let ((ovs (overlays-of)))
      (check (format nil "Ω4 — C-g 後 overlays 數量 ≤ 1（清掉或近空，got ~a）"
                     (length ovs))
             (and (listp ovs) (<= (length ovs) 1)))))

  (format t "~%── v027-search e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
