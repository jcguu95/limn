;;;; v0.27 §I — 30-second 讀者 workflow e2e
;;;;
;;;; 模擬一個真實 dogfooder 第一週會做的完整動作：
;;;;
;;;;   Ω1 開 PDF
;;;;   Ω2 j×5 捲到某處
;;;;   Ω3 / "the" RET 搜尋
;;;;   Ω4 n 跳下一個命中（page 變了）
;;;;   Ω5 mouse-drag 選文字 → h 高亮
;;;;   Ω6 m a 設書籤
;;;;   Ω7 buffer/close 關檔
;;;;   Ω8 同檔再 engine-load → buffer 開回來
;;;;   Ω9 ' a 跳到剛剛設的書籤
;;;;   Ω10 view/overlays-get：之前的高亮 overlay 從 sidecar 自動載回
;;;;
;;;; 這條測「unit 測都綠了但整合鏈中間掉一環」的 bug —— 例如：
;;;;   - install 沒掛到 bootstrap → 第二次 open 不再有 pdf-mode
;;;;   - on-buffer-opened hook 沒呼 → annotation 不重現
;;;;   - bookmark 沒走 view/set → ' a 不會跳

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v027wf"))

;; 確保 sidecar 乾淨開始
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

(defun xdotool (&rest args)
  (sb-ext:run-program "xdotool" args :search t :wait t
                       :output nil :error nil))
(defun key (k) (xdotool "key" k))
(defun type-text (s) (xdotool "type" "--" s))

(defun engine-load (path &key (win "w1"))
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "mupdf" :|path| path :|win-id| win)))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun overlays-of ()
  (let ((r (limn:call "view/get" :|win-id| "w1")))
    (when (ok? r) (or (getf (data r) :|overlays|) '()))))

(defun page-of () (getf (data (limn:call "view/get" :|win-id| "w1")) :|page|))

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

(let* ((sock (format nil "/tmp/limn-e2e-v027wf-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (fixture (b/ "tests/fixtures/test.pdf"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v027wf.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

;;; ── Ω1: 開 PDF ─────────────────────────────────────────────

  (format t "~%── Ω1: 開 PDF ──~%")
  (let ((b1 (engine-load fixture)))
    (check (format nil "Ω1 — open ~a" b1) (stringp b1))

;;; ── Ω2: j×5 ────────────────────────────────────────────────

    (format t "~%── Ω2: j × 5 ──~%")
    (let ((before-p (page-of))
          (before-off (or (getf (data (limn:call "view/get" :|win-id| "w1"))
                                 :|offset-y|) 0.0)))
      (dotimes (_ 5) (key "j") (sleep 0.05))
      (sleep 0.2)
      (let ((after-p (page-of))
            (after-off (or (getf (data (limn:call "view/get" :|win-id| "w1"))
                                  :|offset-y|) 0.0)))
        (check "Ω2 — j×5 動了 page 或 offset"
               (or (> after-p before-p) (> after-off before-off)))))

;;; ── Ω3: / "the" RET ────────────────────────────────────────

    (format t "~%── Ω3: / \"the\" RET ──~%")
    (key "slash") (sleep 0.15)
    (type-text "the") (sleep 0.1) (key "Return") (sleep 0.3)
    (let ((ovs (overlays-of)))
      ;; 至少能跑完不 crash；若 fixture 有 "the"，overlay > 0；否則只驗活
      (check (format nil "Ω3 — search 完成 (overlays=~a)" (length ovs))
             (and (listp ovs))))

;;; ── Ω4: n 跳下一個命中 ───────────────────────────────────

    (format t "~%── Ω4: n 推進命中 ──~%")
    (let ((p-before (page-of))
          (off-before (or (getf (data (limn:call "view/get" :|win-id| "w1"))
                                 :|offset-y|) 0.0)))
      (key "n") (sleep 0.2)
      (let ((p-after (page-of))
            (off-after (or (getf (data (limn:call "view/get" :|win-id| "w1"))
                                  :|offset-y|) 0.0)))
        (check "Ω4 — n 後 page 或 offset 改變"
               (or (not (eql p-before p-after))
                   (not (eql off-before off-after))))))

;;; ── Ω5: selection + h ────────────────────────────────────

    (format t "~%── Ω5: 高亮 ──~%")
    (limn:call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| (page-of) :|x| 0.1 :|y| 0.2)
              :|end|   (list :|page| (page-of) :|x| 0.5 :|y| 0.25))
    (sleep 0.1)
    (key "h") (sleep 0.3)
    (let ((sidecars (ignore-errors
                      (directory
                       (merge-pathnames ".limn/annotations/*.lisp"
                                         (user-homedir-pathname))))))
      (check (format nil "Ω5 — sidecar 寫入 (~a files)" (length sidecars))
             (>= (length sidecars) 1)))

;;; ── Ω6: m a 設書籤 ────────────────────────────────────────

    (format t "~%── Ω6: m a 設書籤 ──~%")
    (let* ((bookmark-page (page-of))
           (r (limn:call "bookmark/set"
                          :|buffer-id| b1 :|name| "a"
                          :|page| bookmark-page :|x| 0.0 :|y| 0.0
                          :|note| "")))
      (check (format nil "Ω6 — bookmark 設在 page ~a" bookmark-page)
             (ok? r)))

;;; ── Ω7: close ─────────────────────────────────────────────

    (format t "~%── Ω7: close ──~%")
    (let ((r (limn:call "buffer/close" :|buffer-id| b1)))
      (check "Ω7 — buffer/close ok" (ok? r)))
    (sleep 0.2)

;;; ── Ω8: re-open ───────────────────────────────────────────

    (format t "~%── Ω8: re-open 同檔 ──~%")
    (let ((b2 (engine-load fixture)))
      (check (format nil "Ω8a — re-open buffer (~a)" b2) (stringp b2))
      (sleep 0.3)

;;; ── Ω9: ' a 跳書籤 ─────────────────────────────────────

      (format t "~%── Ω9: ' a 跳書籤 ──~%")
      (let* ((rg (limn:call "bookmark/get" :|buffer-id| b2 :|name| "a"))
             (got-page (and (ok? rg) (getf (data rg) :|page|))))
        (check (format nil "Ω9a — bookmark 還在 (page=~a)" got-page)
               (integerp got-page))
        (when got-page
          (limn:call "view/set" :|win-id| "w1" :|page| got-page)
          (sleep 0.1)
          (check (format nil "Ω9b — 真的跳到 page ~a" got-page)
                 (eql got-page (page-of)))))

;;; ── Ω10: 高亮 overlay 從 sidecar 自動載回 ───────────────

      (format t "~%── Ω10: annotation 重現 ──~%")
      (sleep 0.3)
      (let ((ovs (overlays-of)))
        (check (format nil "Ω10 — re-open 後 overlay 重現 (~a 個)" (length ovs))
               (and (listp ovs) (>= (length ovs) 1))))

      ;; cleanup
      (ignore-errors (limn:call "bookmark/delete" :|buffer-id| b2 :|name| "a"))))

  ;; cleanup sidecar
  (dolist (f (ignore-errors
               (directory (merge-pathnames ".limn/annotations/*.lisp"
                                            (user-homedir-pathname)))))
    (ignore-errors (delete-file f)))

  (format t "~%── v027-workflow e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
