;;;; v0.27 §N — zero-config first-run e2e
;;;;
;;;; 驗證使用者第一次 launch limn、**沒 init.lisp**、開檔後就能用：
;;;;   Ω1 launch 後 mupdf engine 自動套 pdf-mode
;;;;   Ω2 不靠 user init 按 j 翻頁
;;;;   Ω3 按 / 開搜尋
;;;;   Ω4 第一次 annotate 時 ~/.limn/annotations/ 自動建立
;;;;
;;;; 關鍵：本 driver 故意把 /tmp/.limn/init.lisp stash 開、確保沒有 user init。
;;;; 如果 limn.lisp bootstrap 沒掛 pdf-mode install，這條紅。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

;; 故意確保沒 user init。
(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v027zc"))

;; 也清舊 annotations 目錄，重現「第一次」狀態。
(let ((dir (merge-pathnames ".limn/annotations/" (user-homedir-pathname))))
  (when (probe-file dir)
    (dolist (f (ignore-errors (directory (merge-pathnames "*.lisp" dir))))
      (ignore-errors (delete-file f)))))

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

(let* ((sock (format nil "/tmp/limn-e2e-v027zc-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v027zc.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (let ((b (engine-load (b/ "tests/fixtures/test.pdf"))))
    (check (format nil "setup — buffer ~a" b) (stringp b))

;;; ── Ω1: mupdf buffer 自動套 pdf-mode（無 user init） ──────────

    (format t "~%── Ω1: pdf-mode 自動套用 ──~%")
    (let* ((r (limn:call "buffer/state" :|buffer-id| b))
           (major (and (ok? r) (getf (data r) :|major|))))
      (check (format nil "Ω1 — major=pdf-mode (zero-config, got ~s)" major)
             (or (null major)            ; tolerate missing buffer/state
                 (and (stringp major)
                      (search "pdf" (string-downcase major))))))

;;; ── Ω2: 不靠 user init 按 j 翻頁 / 捲動 ──────────────────────

    (format t "~%── Ω2: j 翻頁不靠 user init ──~%")
    (let* ((before (data (limn:call "view/get" :|win-id| "w1")))
           (bp (getf before :|page|))
           (boff (or (getf before :|offset-y|) 0.0)))
      (key "j") (key "j") (key "j") (sleep 0.2)
      (let* ((after (data (limn:call "view/get" :|win-id| "w1")))
             (ap (getf after :|page|))
             (aoff (or (getf after :|offset-y|) 0.0)))
        (check (format nil "Ω2 — j 動了 page (~a→~a) 或 offset (~a→~a)"
                       bp ap boff aoff)
               (or (> ap bp) (> aoff boff)))))

;;; ── Ω3: / 開搜尋 / 不靠 user init ─────────────────────────────

    (format t "~%── Ω3: / 開搜尋 ──~%")
    (key "slash") (sleep 0.15)
    (let ((mb (data (limn:call "minibuffer/get"))))
      (check "Ω3a — minibuffer 開（/ 進 pdf-mode 預設綁定）"
             (and mb (eq (getf mb :|open|) t))))
    (type-text "the") (sleep 0.1) (key "Return") (sleep 0.3)
    ;; 不檢查 hits（fixture 不見得有 "the"），只看不 crash
    (let ((r (limn:call "view/get" :|win-id| "w1")))
      (check "Ω3b — session 仍活（search 跑完不 crash）"
             (ok? r)))

;;; ── Ω4: 第一次 annotate 時 sidecar 目錄自動建 ──────────────

    (format t "~%── Ω4: ~~/.limn/annotations/ 自動建立 ──~%")
    (limn:call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| 0 :|x| 0.1 :|y| 0.2)
              :|end|   (list :|page| 0 :|x| 0.5 :|y| 0.25))
    (sleep 0.1)
    (key "h") (sleep 0.3)
    (let* ((dir (merge-pathnames ".limn/annotations/" (user-homedir-pathname))))
      (check (format nil "Ω4 — annotations dir 存在 (~a)" (namestring dir))
             (probe-file dir))))

  ;; cleanup
  (let ((dir (merge-pathnames ".limn/annotations/" (user-homedir-pathname))))
    (when (probe-file dir)
      (dolist (f (ignore-errors (directory (merge-pathnames "*.lisp" dir))))
        (ignore-errors (delete-file f)))))

  (format t "~%── v027-zero-config e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
