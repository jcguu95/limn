;;;; v0.29 — Full module load + semantic wiring  (OS-tier, pure Lisp)
;;;;
;;;; 不需要 Limn binary。直接把全部模組依 v0.29 目標順序載入，
;;;; 然後驗證跨模組 wiring 確實成立。
;;;;
;;;; 等於是在真實 SBCL 環境裡重現 `repl.lisp` 的載入路徑，
;;;; 比 smoke test（只看 exit 0 + 無 warning）多出語義層的保證。
;;;;
;;;; Ω1  所有模組依序載入，0 error
;;;; Ω2  各版本代表性函數 fboundp
;;;; Ω3  which-key auto-install: hook 已掛、timer mock 可觸發
;;;; Ω4  text-nav kill-fn 已接 kill-ring
;;;; Ω5  pdf-mode 登記為 mupdf engine 的預設 mode
;;;; Ω6  map! 能把 leader binding 寫進 *leader-keymap*
;;;; Ω7  新版 init.lisp.example 在全模組環境下 eval 無 error
;;;;
;;;; v0.29 實作前：
;;;;   - Ω1 可能有 redefin warning（順序錯）
;;;;   - Ω3/Ω4/Ω5/Ω6 因模組未全載入而失敗
;;;;   - Ω7 因 init.lisp.example 仍是 v0.8 舊版而失敗

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

;;; ── check harness ────────────────────────────────────────────────────────

(defparameter *failures* nil)
(defparameter *warnings* nil)

(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details)
    (format t "    → ~a~%" details))
  (unless ok (push msg *failures*)))

(defun warn-check (msg ok &optional details)
  "Like check but failure goes to *warnings*, not *failures*."
  (format t "  ~a [warn] ~a~%" (if ok "✓" "!") msg)
  (when (and (not ok) details)
    (format t "    → ~a~%" details))
  (unless ok (push msg *warnings*)))

;;; ── Ω1 — 全模組依 v0.29 目標順序載入，0 error ───────────────────────────
;;;
;;; 這是 v0.29 實作後 repl.lisp 的目標載入順序（對應 LIMN-SPEC §v0.29 A）。
;;; 每個 load 都計入 error 數；Ω1 通過條件是 errors = 0。

(format t "~%=== batch-os-v029-full-load ===~%")
(format t "~%── Ω1: 全模組載入 (target load order) ──~%")

(defparameter *load-errors* 0)

(defun %load (f)
  (handler-case
      (progn (load (b/ f)) t)
    (error (e)
      (incf *load-errors*)
      (format t "  !! load error ~a: ~a~%" f e)
      nil)))

(dolist (f '(;; v0.7-v0.22 core
             "limn-hooks.lisp"
             "limn-log.lisp"                  ; v0.23
             "limn-error.lisp"                ; v0.23
             "limn-timer.lisp"                ; v0.23
             "limn-process.lisp"              ; v0.23
             "limn-buffer.lisp"
             "limn-bridge.lisp"
             "limn-undo.lisp"
             "limn-buffer-undo.lisp"          ; v0.23.1
             "limn-keys.lisp"
             "limn-search.lisp"
             "limn-client.lisp"
             "limn-dispatch.lisp"
             "limn-mode.lisp"
             "limn-cmd.lisp"
             "limn-runtime.lisp"
             "limn-introspect.lisp"
             ;; v0.24 edit model
             "limn-kill.lisp"
             "limn-mark.lisp"
             "limn-register.lisp"
             "limn-kmacro.lisp"
             "limn-file.lisp"
             "limn-auto-save.lisp"
             "limn-backup.lisp"
             "limn-recentf.lisp"
             ;; v0.25 interaction
             "limn-history.lisp"
             "limn-custom.lisp"
             "limn-advice.lisp"
             "limn-face.lisp"
             "limn-text-props.lisp"
             "limn-help.lisp"
             "limn-completion.lisp"
             ;; v0.26 search UI
             "limn-isearch.lisp"
             "limn-occur.lisp"
             ;; v0.28 keymap completion (text-mode AFTER kill/mark/undo)
             "limn-text-nav.lisp"
             "limn-text-mode.lisp"
             "limn-map-macro.lisp"
             "limn-which-key.lisp"
             ;; v0.27 pdf-mode
             "limn-pdf-mode.lisp"
             ;; bootstrap (last)
             "limn.lisp"))
  (%load f))

(check (format nil "Ω1 — 全模組載入 0 error (got ~a)" *load-errors*)
       (= 0 *load-errors*))

;;; ── Ω2 — 各版本代表性函數 fboundp ───────────────────────────────────────

(format t "~%── Ω2: 代表性函數 fboundp ──~%")

(defmacro check-fboundp (pkg-sym fn-str)
  `(let* ((p (find-package ,pkg-sym))
          (s (and p (find-symbol ,fn-str p))))
     (check (format nil "Ω2 ~a:~a fboundp" ,pkg-sym ,fn-str)
            (and s (fboundp s)))))

;; v0.23
(check-fboundp '#:limn/timer   "RUN-AT-TIME")
(check-fboundp '#:limn/process "MAKE-PROCESS")
(check-fboundp '#:limn/log     "MESSAGE")
;; v0.24
(check-fboundp '#:limn/kill    "KILL-NEW")
(check-fboundp '#:limn/mark    "SET-MARK")
(check-fboundp '#:limn/file    "FIND-FILE")
(check-fboundp '#:limn/recentf "RECENTF-LOAD")
;; v0.25
(check-fboundp '#:limn/face       "ENABLE-THEME")
(check-fboundp '#:limn/completion "COMPLETING-READ")
(check-fboundp '#:limn/help       "DESCRIBE-FUNCTION")
;; v0.26
(check-fboundp '#:limn/isearch "ISEARCH-START")
(check-fboundp '#:limn/occur   "OCCUR")
;; v0.27
(check-fboundp '#:limn/pdf-mode "INSTALL")
;; v0.28
(check-fboundp '#:limn/text-nav  "FORWARD-WORD")
(check-fboundp '#:limn/map-macro "MAP!")
(check-fboundp '#:limn/which-key "WHICH-KEY-MODE")

;;; ── Ω3 — which-key: hook 已掛、timer mock 可觸發 ────────────────────────
;;;
;;; dogfood: 如果 limn-timer 比 limn-which-key 晚載入，install 時找不到
;;; timer → *hook-installed* 停 nil → prefix key 觸發後無 popup。

(format t "~%── Ω3: which-key hook + timer wiring ──~%")

(let* ((wk-pkg (find-package '#:limn/which-key))
       (hi-sym (and wk-pkg (find-symbol "*HOOK-INSTALLED*" wk-pkg))))
  (check "Ω3a — *hook-installed* is t"
         (and hi-sym (boundp hi-sym) (symbol-value hi-sym))))

(let* ((wk-pkg    (find-package '#:limn/which-key))
       (hp        (find-package '#:limn/hooks))
       (mode-sym  (and wk-pkg (find-symbol "*WHICH-KEY-MODE*" wk-pkg)))
       (timer-sym (and wk-pkg (find-symbol "*TIMER-FN*" wk-pkg)))
       (hi-sym    (and wk-pkg (find-symbol "*HOOK-INSTALLED*" wk-pkg)))
       (rh-sym    (and hp (find-symbol "RUN-HOOK" hp)))
       (scheduled nil))
  (when (and mode-sym timer-sym hi-sym rh-sym)
    ;; Re-register hook in case clear-all-hooks ran (defensive).
    (progv (list hi-sym) (list nil)
      (handler-case (limn/which-key:install) (error () nil)))
    (progv (list mode-sym timer-sym)
           (list t (lambda (d c) (declare (ignore d c)) (setf scheduled t)))
      (handler-case
          (funcall (symbol-function rh-sym)
                   "event/key-prefix-changed"
                   (list :|prefix| "C-x"))
        (error (e) (format t "  [run-hook error] ~a~%" e)))))
  (check "Ω3b — prefix event schedules timer"
         scheduled
         "timer mock not called — timer may have loaded after which-key"))

;;; ── Ω4 — text-nav *kill-new-fn* 接到真實 kill-ring ──────────────────────
;;;
;;; dogfood: C-k kill-line 在 text buffer 裡不把文字放進 kill-ring。
;;; 原因：limn-kill 比 limn-text-nav 晚載入 → install 時 kill-new 未定義
;;; → *kill-new-fn* 仍是 default no-op stub。

(format t "~%── Ω4: text-nav *kill-new-fn* wired ──~%")

(let* ((nav-pkg  (find-package '#:limn/text-nav))
       (kill-pkg (find-package '#:limn/kill))
       (kfn-sym  (and nav-pkg  (find-symbol "*KILL-NEW-FN*" nav-pkg)))
       (ring-sym (and kill-pkg (find-symbol "*KILL-RING*"   kill-pkg)))
       (sentinel "__v029-kill-sentinel__"))
  (if (or (null kfn-sym) (null ring-sym))
      (check "Ω4 — *kill-new-fn* callable" nil "symbol not found")
      (let ((ring-before (copy-list (symbol-value ring-sym))))
        (handler-case (funcall (symbol-value kfn-sym) sentinel)
          (error (e)
            (check "Ω4 — *kill-new-fn* no error" nil (format nil "~a" e))))
        (check "Ω4 — kill-line pushes to kill-ring"
               (member sentinel
                       (set-difference (symbol-value ring-sym) ring-before
                                        :test #'equal)
                       :test #'equal)
               (format nil "ring diff: ~s" (set-difference (symbol-value ring-sym)
                                                            ring-before :test #'equal))))))

;;; ── Ω5 — pdf-mode 登記為 mupdf engine 預設 mode ─────────────────────────
;;;
;;; dogfood: 開 PDF 後 pdf-mode 沒套上 → j/k/SPC 無反應。
;;; 原因：pdf-mode auto-install 呼叫 register-engine-default-mode 時
;;; limn-runtime 尚未就緒（或 install 在 mode-system 之前跑）。

(format t "~%── Ω5: pdf-mode engine registry ──~%")

(let* ((rt-pkg (find-package '#:limn/runtime))
       (fn-sym (and rt-pkg (find-symbol "ENGINE-DEFAULT-MODE" rt-pkg))))
  (if (null fn-sym)
      (check "Ω5 — engine-default-mode available" nil "symbol not found")
      (let ((mode (handler-case (funcall (symbol-function fn-sym) "mupdf")
                    (error (e) (format t "  [edf error] ~a~%" e) nil))))
        (check "Ω5a — mupdf has default mode" (not (null mode)))
        (check "Ω5b — default mode is pdf-mode"
               (and (symbolp mode)
                    (string-equal (symbol-name mode) "PDF-MODE"))
               (format nil "got: ~s" mode)))))

;;; ── Ω6 — map! 寫入 *leader-keymap* ──────────────────────────────────────
;;;
;;; dogfood: user 在 init.lisp 裡用 (map! :leader "f f" #'find-file)
;;; 但 SPC f f 完全沒有反應。
;;; 原因：limn-map-macro 沒載入 → map! 是 undefined function。

(format t "~%── Ω6: map! leader binding ──~%")

(let* ((keys-pkg (find-package '#:limn/keys))
       (lkm-sym  (and keys-pkg (find-symbol "*LEADER-KEYMAP*" keys-pkg)))
       (lkp-sym  (and keys-pkg (find-symbol "LOOKUP-SEQUENCE"  keys-pkg))))
  (if (or (null lkm-sym) (null lkp-sym))
      (check "Ω6 — *leader-keymap* + lookup-sequence available" nil "symbol missing")
      (let* ((fresh-km (handler-case (limn/keys:make-keymap) (error () nil)))
             (bound-fn (lambda () :v029-test-fn)))
        (if (null fresh-km)
            (check "Ω6 — make-keymap works" nil)
            (progn
              (progv (list lkm-sym) (list fresh-km)
                (handler-case
                    (limn/map-macro:map! :leader
                      "f f" bound-fn)
                  (error (e)
                    (check "Ω6 — map! :leader no error" nil (format nil "~a" e)))))
              (let ((result (handler-case
                                (funcall (symbol-function lkp-sym)
                                         fresh-km
                                         (list "f" "f"))
                              (error () nil))))
                (check "Ω6 — SPC f f bound in fresh leader keymap"
                       result
                       "lookup-sequence returned nil")))))))

;;; ── Ω7 — 新版 init.lisp.example eval 無 error ───────────────────────────
;;;
;;; dogfood: user 把 init.lisp.example 複製到 ~/.limn/init.lisp 後
;;; 啟動看到一堆 error（package 找不到、symbol undefined 等）。
;;; 這個 Ω 在全模組載入環境下用 (load ...) 驗證 example 不爆。

(format t "~%── Ω7: init.lisp.example eval ──~%")

(let* ((example-path (b/ "init.lisp.example"))
       (exists (probe-file example-path)))
  (check "Ω7a — init.lisp.example exists" exists example-path)
  (when exists
    (let ((eval-ok t))
      (handler-case (load example-path :verbose nil :print nil)
        (error (e)
          (setf eval-ok nil)
          (format t "  [eval error] ~a~%" e)))
      (check "Ω7b — init.lisp.example loads without error" eval-ok))))

;;; ── 結果 ─────────────────────────────────────────────────────────────────

(format t "~%── v0.29 full-load e2e ──~%")
(when *warnings*
  (format t "  [warnings: ~a]~%" (length *warnings*)))
(if (null *failures*)
    (format t "✓ ALL CHECKS PASSED~%")
    (progn
      (format t "✗ ~a FAILURE(s):~%" (length *failures*))
      (dolist (m (reverse *failures*))
        (format t "  • ~a~%" m))))

(sb-ext:exit :code (if *failures* 1 0))
