;;;; v0.29 — 真實 init.lisp.example session  (OS-tier, needs Limn binary)
;;;;
;;;; 用新版 init.lisp.example 作為 LIMN_INIT 啟動一個真實 Limn session，
;;;; 驗證 v0.29 三件事在完整執行路徑下都能正常運作：
;;;;
;;;;   Ω1  repl.lisp 載入完畢 + init.lisp.example eval 成功，無 stderr error
;;;;   Ω2  which-key-mode 在 init 後為 t（init example 調用了 which-key-mode）
;;;;   Ω3  leader keymap 有 init example 的 SPC 綁定（SPC f f → find-file）
;;;;   Ω4  開 PDF → engine-default-mode "mupdf" 在 session 內正確回 pdf-mode
;;;;   Ω5  text-nav kill-line 在真實 text engine buffer 走完 → kill-ring 有值
;;;;
;;;; 執行環境：
;;;;   - 需要 Limn binary（LIMN_BIN 或 /limn/sioyek/limn）
;;;;   - 不需要顯示器（binary 以 --headless 模式跑）
;;;;   - 不需要 Xvfb / xdotool
;;;;
;;;; v0.29 實作前：
;;;;   Ω1 — repl.lisp 缺 v0.28 模組，init.lisp.example 是 v0.8 舊版，可能 ok
;;;;         但 init 加載後不會有預期的 which-key / map! 效果
;;;;   Ω2 — *which-key-mode* 是 nil（舊 init 沒有呼叫 which-key-mode）
;;;;   Ω3 — *leader-keymap* 沒有 "f f" binding（舊 init 沒有 map! :leader）
;;;;   Ω4 — 取決於 pdf-mode 的 register 是否成功
;;;;   Ω5 — text-nav kill-line 可能 ok（但 kill-ring 依賴 kill module 先載入）

(in-package :cl-user)
(require :sb-posix)
(require :sb-bsd-sockets)

;;; ── paths ────────────────────────────────────────────────────────────────

(defparameter *bdir*
  (or (handler-case (sb-posix:getenv "LIMN_BACKEND_DIR") (error () nil))
      (namestring (merge-pathnames
                   "../../"
                   (make-pathname :defaults (or *load-truename*
                                                *default-pathname-defaults*)
                                  :name nil :type nil)))))

(defun b/ (f) (concatenate 'string *bdir* f))

(defparameter *limn-bin*
  (or (handler-case (sb-posix:getenv "LIMN_BIN") (error () nil))
      (let ((candidates (list "/limn/sioyek/limn"
                               (b/ "../sioyek/limn.app/Contents/MacOS/limn")
                               (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
        (dolist (c candidates nil)
          (when (probe-file c) (return c))))))

;;; ── check harness ────────────────────────────────────────────────────────

(defparameter *failures* nil)

(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    → ~a~%" details))
  (unless ok (push msg *failures*)))

(format t "~%=== batch-os-v029-init-real ===~%")

;; Bail early if no binary available
(unless *limn-bin*
  (format t "  SKIP: Limn binary not found (set LIMN_BIN)~%")
  (sb-ext:exit :code 77))  ; 77 = skip (same convention as autoconf)

(format t "  binary: ~a~%" *limn-bin*)

;;; ── load backend modules via ASDF — must happen BEFORE any defuns
;;; ── below reference the LIMN:* / LIMN/*:* packages at read time.

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

;;; ── helpers ──────────────────────────────────────────────────────────────

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun start-session (sock log &key init-path)
  "Spawn limn with --headless --test-mode --socket SOCK; returns process."
  (let* ((args (list "--headless" "--test-mode" "--socket" sock))
         (env  (when init-path
                 (list (format nil "LIMN_INIT=~a" init-path)))))
    ;; Set env vars before spawning by writing a wrapper if needed.
    ;; Simplest: use sb-posix:setenv directly before run-program.
    (when init-path
      (sb-posix:setenv "LIMN_INIT" init-path 1))
    (let ((proc (sb-ext:run-program
                 *limn-bin* args
                 :wait nil :search nil
                 :output log :if-output-exists :supersede :error :output)))
      (loop repeat 100 until (probe-file sock) do (sleep 0.05))
      (limn:start sock)
      (sleep 0.5)
      proc)))

(defun stop-session (proc &key init-path)
  (ignore-errors (limn:stop))
  (when init-path (ignore-errors (sb-posix:unsetenv "LIMN_INIT")))
  (ignore-errors (sb-ext:process-kill proc 15))
  (ignore-errors (sb-ext:process-wait proc)))

;;; ── stash any existing init ──────────────────────────────────────────────

(defparameter *stash-path* "/tmp/.limn/init.lisp.stash-v029ir")
(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" *stash-path*))

;;; ── Ω1 / Ω2 / Ω3 — startup with new init.lisp.example ──────────────────
;;;
;;; Spawn a session with LIMN_INIT pointing to init.lisp.example.
;;; The new example should:
;;;   - call (which-key-mode)      → *which-key-mode* = t
;;;   - call (map! :leader ...)    → SPC f f in *leader-keymap*
;;; After session starts, we inspect the Lisp-side state over the wire.

(format t "~%── Ω1/Ω2/Ω3: startup with init.lisp.example ──~%")

(let* ((sock      (format nil "/tmp/limn-v029ir-1-~a" (sb-posix:getpid)))
       (log-path  "/tmp/limn-os-v029ir1.log")
       (init-path (b/ "init.lisp.example")))
  (if (not (probe-file init-path))
      (check "Ω1 — init.lisp.example exists" nil init-path)
      (let ((proc (start-session sock log-path :init-path init-path)))
        (unwind-protect
             (progn
               ;; Ω1: session is up → limn:call succeeds
               (let ((caps (handler-case
                                (limn:call "bridge/capabilities")
                              (error (e) (format t "  [caps error] ~a~%" e) nil))))
                 (check "Ω1 — session started (bridge/capabilities ok)"
                        (and caps (ok? caps))
                        (format nil "response: ~s" caps)))

               ;; Ω1 (log): no "error" lines in the log after init
               (sleep 0.3)
               (let* ((log-content
                        (handler-case
                            (with-open-file (s log-path)
                              (let ((buf (make-string (file-length s))))
                                (read-sequence buf s)
                                buf))
                          (error () "")))
                      (error-lines
                        (count-if
                         (lambda (line)
                           (and (search "error" (string-downcase line))
                                (not (search "no-error" line))
                                (not (search "on-error" line))
                                (not (search "error-protection" line))
                                (not (search "with-error" line))
                                (not (search "limn-error" line))))
                         ;; v0.37 Phase F: the original wrote
                         ;; `(loop ... collect X ... finally (when ... (collect Y)))`
                         ;; but COLLECT is a loop CLAUSE, not a function —
                         ;; calling it outside a loop body errors with
                         ;; "function COLLECT is undefined".  Rewrite as an
                         ;; explicit accumulator so the trailing-line case
                         ;; still composes.
                         (let ((acc nil)
                               (start 0)
                               pos)
                           (loop
                             (setf pos (position #\Newline log-content :start start))
                             (unless pos (return))
                             (push (subseq log-content start pos) acc)
                             (setf start (1+ pos)))
                           (when (< start (length log-content))
                             (push (subseq log-content start) acc))
                           (nreverse acc)))))
                 (check (format nil "Ω1 — log has no raw error lines (~a found)" error-lines)
                        (= 0 error-lines)
                        (when (> error-lines 0)
                          (format nil "log: ~a" (subseq log-content 0 (min 500 (length log-content)))))))

               ;; Ω2: *which-key-mode* = t (init calls which-key-mode)
               ;; We check via the Lisp-side state directly (not over wire).
               (let* ((wk-pkg   (find-package '#:limn/which-key))
                      (mode-sym (and wk-pkg (find-symbol "*WHICH-KEY-MODE*" wk-pkg))))
                 (check "Ω2 — *which-key-mode* is t after init"
                        (and mode-sym (boundp mode-sym) (symbol-value mode-sym))
                        "init.lisp.example should call (which-key-mode)"))

               ;; Ω3: *leader-keymap* has SPC f f → find-file
               ;; init.lisp.example calls (map! :leader "f f" #'find-file)
               (let* ((keys-pkg (find-package '#:limn/keys))
                      (lkm-sym  (and keys-pkg (find-symbol "*LEADER-KEYMAP*" keys-pkg)))
                      (lkp-sym  (and keys-pkg (find-symbol "LOOKUP-SEQUENCE"  keys-pkg))))
                 (if (or (null lkm-sym) (null lkp-sym))
                     (check "Ω3 — *leader-keymap* available" nil "symbol missing")
                     (let ((result (handler-case
                                       (funcall (symbol-function lkp-sym)
                                                (symbol-value lkm-sym)
                                                (list "f" "f"))
                                     (error (e) (format t "  [lookup error] ~a~%" e) nil))))
                       (check "Ω3 — SPC f f bound in *leader-keymap*"
                               result
                               "map! :leader in init.lisp.example should have bound this")))))
          (stop-session proc :init-path init-path)))))

;;; ── Ω4 — mupdf engine-default-mode = pdf-mode (live session) ────────────
;;;
;;; dogfood: pdf-mode のauto-install が成功したことを repl.lisp ブートパスで確認。

(format t "~%── Ω4: engine-default-mode persists across start ──~%")

(let* ((rt-pkg (find-package '#:limn/runtime))
       (fn-sym (and rt-pkg (find-symbol "ENGINE-DEFAULT-MODE" rt-pkg))))
  (if (null fn-sym)
      (check "Ω4 — engine-default-mode available" nil)
      (let ((mode (handler-case (funcall (symbol-function fn-sym) "mupdf")
                    (error () nil))))
        (check "Ω4a — mupdf has default mode" (not (null mode)))
        (check "Ω4b — default mode is pdf-mode"
               (and (symbolp mode) (string-equal (symbol-name mode) "PDF-MODE"))
               (format nil "got: ~s" mode)))))

;;; ── Ω5 — text buffer kill-line roundtrip via real session ────────────────
;;;
;;; dogfood: C-k doesn't add to kill-ring (text-nav loaded before kill module).
;;; We spawn a session, open a text buffer, insert text via wire,
;;; call kill-line on the Lisp side, verify kill-ring has the content.

(format t "~%── Ω5: kill-line → kill-ring roundtrip ──~%")

(let* ((sock     (format nil "/tmp/limn-v029ir-5-~a" (sb-posix:getpid)))
       (log-path "/tmp/limn-os-v029ir5.log")
       (proc     (start-session sock log-path)))
  (unwind-protect
       (let* ((r (handler-case
                      (limn:call "bridge/engine-load"
                                  :|win-id| "w1" :|engine| "text" :|path| "")
                    (error (e)
                      (format t "  [engine-load error] ~a~%" e)
                      nil)))
              (buf (and r (ok? r) (getf (data r) :|buffer-id|))))
         (check "Ω5a — text engine-load returns buffer-id"
                (and (stringp buf) (> (length buf) 0))
                (format nil "response: ~s" r))
         (when buf
           ;; Insert a test line via wire.
           (handler-case
               (limn:call "buffer/insert" :|buffer-id| buf
                           :|at| 0 :|text| "hello v029")
             (error (e) (format t "  [insert error] ~a~%" e)))
           (sleep 0.1)

           ;; Call kill-line on the Lisp side with the vtable wired.
           ;; text-nav:kill-line(buf) should push to kill-ring.
           (let* ((nav-pkg (find-package '#:limn/text-nav))
                  (kl-sym  (and nav-pkg (find-symbol "KILL-LINE" nav-pkg)))
                  (kill-pkg (find-package '#:limn/kill))
                  (ring-sym (and kill-pkg (find-symbol "*KILL-RING*" kill-pkg))))
             (if (or (null kl-sym) (null ring-sym))
                 (check "Ω5b — text-nav:kill-line + *kill-ring* available" nil)
                 (let ((ring-before (copy-list (symbol-value ring-sym))))
                   ;; Wire vtable to real buffer (needed for text-nav to work).
                   (let* ((btext-sym (find-symbol "*BUFFER-TEXT-FN*" nav-pkg))
                          (bcur-sym  (find-symbol "*BUFFER-CURSOR-FN*" nav-pkg))
                          (bdel-sym  (find-symbol "*BUFFER-DELETE-FN*" nav-pkg))
                          (bscur-sym (find-symbol "*BUFFER-SET-CURSOR-FN*" nav-pkg)))
                     (when (and btext-sym bcur-sym bdel-sym bscur-sym)
                       (progv (list btext-sym bcur-sym bdel-sym bscur-sym)
                              (list
                               ;; *buffer-text-fn*: query buffer content via wire
                               (lambda (bid)
                                 (let ((r (handler-case
                                               (limn:call "buffer/text" :|buffer-id| bid)
                                             (error () nil))))
                                   (or (and r (ok? r) (getf (data r) :|text|)) "")))
                               ;; *buffer-cursor-fn*: cursor at 0
                               (lambda (bid) (declare (ignore bid)) 0)
                               ;; *buffer-delete-fn*: delete via wire
                               (lambda (bid from to)
                                 (handler-case
                                     (limn:call "buffer/delete" :|buffer-id| bid
                                                 :|from| from :|to| to)
                                   (error () nil)))
                               ;; *buffer-set-cursor-fn*: no-op for this test
                               (lambda (bid pos) (declare (ignore bid pos)) nil))
                         (handler-case
                             (funcall (symbol-function kl-sym) buf)
                           (error (e)
                             (format t "  [kill-line error] ~a~%" e)))))
                     (let ((added (set-difference (symbol-value ring-sym) ring-before
                                                   :test #'equal)))
                       (check "Ω5c — kill-line put text in kill-ring"
                               (and added (not (null added)))
                               (format nil "ring diff: ~s" added)))))))))
    (stop-session proc)))

;;; ── 還原 init ────────────────────────────────────────────────────────────

(ignore-errors (delete-file "/tmp/.limn/init.lisp"))
(when (probe-file *stash-path*)
  (rename-file *stash-path* "/tmp/.limn/init.lisp"))

;;; ── 結果 ─────────────────────────────────────────────────────────────────

(format t "~%── v0.29 init-real e2e ──~%")
(if (null *failures*)
    (format t "✓ ALL CHECKS PASSED~%")
    (progn
      (format t "✗ ~a FAILURE(s):~%" (length *failures*))
      (dolist (m (reverse *failures*))
        (format t "  • ~a~%" m))))

(sb-ext:exit :code (if *failures* 1 0))
