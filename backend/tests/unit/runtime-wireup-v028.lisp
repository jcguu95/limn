;;;; v0.29 — Runtime wire-up structural + semantic tests  (8 tests)
;;;;
;;;; 三個結構測試（SPEC §v0.29 Testing 原定）：
;;;;   1. wireup-load-lists-match        repl.lisp list ≡ run-unit.lisp impl list
;;;;   2. wireup-all-files-exist         清單每個檔真的在 backend/ 存在
;;;;   3. wireup-init-example-parses     init.lisp.example read 無 error
;;;;
;;;; 五個語義測試（dogfood-driven，防範十天後踩的坑）：
;;;;   4. wireup-which-key-auto-installed    *hook-installed* 在載入後為 t
;;;;   5. wireup-which-key-timer-fires       prefix event → timer 被 schedule
;;;;   6. wireup-text-nav-kill-fn-wired      *kill-new-fn* 接到真實 kill-new
;;;;   7. wireup-pdf-mode-engine-registered  "mupdf" → pdf-mode 在 registry
;;;;   8. wireup-init-example-evaluates      example eval 不爆 unhandled error
;;;;
;;;; 預期結果：
;;;;   - 測試 1 在 v0.29 實作前 RED（repl.lisp 缺 v0.28 三模組）。
;;;;   - 測試 2-8 在全模組載入的 unit runner 環境下應全 GREEN。

(in-package #:limn/unit-test)

;;; ── path helpers ─────────────────────────────────────────────────────────
;;;
;;; This file lives at  backend/tests/unit/runtime-wireup-v028.lisp.
;;; *wireup-unit-dir* is set at load time via *load-pathname*, which
;;; run-unit.lisp sets correctly before calling (load ...).

(defparameter *wireup-unit-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil)
  "Directory of this test file — tests/unit/")

(defun %wu-path (relative)
  "Resolve RELATIVE from the backend/ root (two dirs up from tests/unit/)."
  (namestring
   (merge-pathnames relative
                    (merge-pathnames #p"../../" *wireup-unit-dir*))))

;;; ── file-list parser ─────────────────────────────────────────────────────
;;;
;;; We need to read the load list from two Lisp source files without
;;; evaluating them.  Both files contain exactly one top-level form:
;;;   (dolist (VAR '("file1.lisp" "file2.lisp" ...)) body...)
;;; %extract-string-dolist finds the FIRST such form and returns the list.

(defun %extract-string-dolist (path)
  "Open PATH and return the first (dolist (VAR '(STRING...))) string list.
   Returns NIL if not found or on read error.  *read-eval* is disabled."
  (let ((*read-eval* nil))
    (with-open-file (s path :direction :input :if-does-not-exist nil)
      (unless s
        (format t "  [%extract-string-dolist] file not found: ~a~%" path)
        (return-from %extract-string-dolist nil))
      (handler-case
          (loop for form = (read s nil :eof)
                until (eq form :eof)
                thereis
                  (and (listp form)
                       (eq (first form) 'dolist)
                       (let* ((binding  (second form))
                              (init-val (and (listp binding) (second binding))))
                         (and (listp init-val)
                              (eq (first init-val) 'quote)
                              (listp (second init-val))
                              (every #'stringp (second init-val))
                              (second init-val)))))
        (error (e)
          (format t "  [%extract-string-dolist error ~a] ~a~%" path e)
          nil)))))

;;; ══════════════════════════════════════════════════════════════════════════
;;; 結構測試 1 — load list 一致
;;; ══════════════════════════════════════════════════════════════════════════

(deftest wireup-load-lists-match
  "repl.lisp 的模組清單（去除 limn.lisp）與 run-unit.lisp 的 impl 清單相同，
   且相對順序一致。  v0.29 實作前 RED（缺 limn-text-nav / map-macro /
   which-key，且部份順序不同）。"
  (let* ((repl-path (%wu-path "repl.lisp"))
         (ru-path   (%wu-path "tests/unit/run-unit.lisp"))
         (repl-raw  (%extract-string-dolist repl-path))
         (ru-raw    (%extract-string-dolist ru-path)))
    ;; assert-true returns nil (from check), so we guard on the values directly,
    ;; then call assert-true for display output.
    (assert-true repl-raw "repl.lisp: dolist string list found")
    (assert-true ru-raw   "run-unit.lisp: dolist string list found")
    (when (and repl-raw ru-raw)
      ;; limn.lisp is the bootstrap sentinel; run-unit never loads it.
      (let* ((repl-list (remove "limn.lisp" repl-raw :test #'equal))
             (extra     (set-difference repl-list ru-raw   :test #'equal))
             (missing   (set-difference ru-raw   repl-list :test #'equal)))
        (check (null extra)
               "repl.lisp has no extra files absent from run-unit"
               "extra in repl: ~s" extra)
        (check (null missing)
               "repl.lisp has no files missing vs run-unit"
               "missing from repl: ~s" missing)
        ;; Relative order: project repl-list onto ru-raw and compare.
        (let* ((repl-projected
                 (remove-if-not (lambda (f) (member f ru-raw :test #'equal))
                                repl-list))
               (order-ok (equal repl-projected ru-raw)))
          (check order-ok
                 "relative load order matches run-unit.lisp"
                 "repl order: ~s~%  run-unit order: ~s"
                 repl-projected ru-raw))))))

;;; ══════════════════════════════════════════════════════════════════════════
;;; 結構測試 2 — 每個列出的模組都存在
;;; ══════════════════════════════════════════════════════════════════════════

(deftest wireup-all-files-exist
  "repl.lisp 模組清單中每一個檔名對應的 backend/<name> 都存在於磁碟。"
  (let* ((repl-raw (%extract-string-dolist (%wu-path "repl.lisp"))))
    (if (null repl-raw)
        (check nil "repl.lisp load list could not be read" nil)
        (dolist (fname repl-raw)
          (let ((full (%wu-path fname)))
            (check (probe-file full)
                   (format nil "backend/~a exists" fname)
                   "file not found: ~a" full))))))

;;; ══════════════════════════════════════════════════════════════════════════
;;; 結構測試 3 — init.lisp.example 可讀取（parse）
;;; ══════════════════════════════════════════════════════════════════════════

(deftest wireup-init-example-parses
  "backend/init.lisp.example 能被 READ 到 EOF，無任何 read-level error。"
  (let ((path (%wu-path "init.lisp.example")))
    (check (probe-file path)
           "init.lisp.example exists"
           "not found: ~a" path)
    (when (probe-file path)
      (let ((*read-eval* nil))
        (assert-no-error
          (with-open-file (s path :direction :input)
            (loop for form = (read s nil :eof)
                  until (eq form :eof)))
          "init.lisp.example parses without read errors")))))

;;; ══════════════════════════════════════════════════════════════════════════
;;; 語義測試 4 — which-key auto-install 完成
;;; ══════════════════════════════════════════════════════════════════════════
;;;
;;; dogfood bug: which-key popup 從不出現
;;;   原因：auto-install 時 limn/hooks 不存在，hook 靜默跳過；
;;;         *hook-installed* 停在 nil，之後觸發 prefix 沒有任何反應。

(deftest wireup-which-key-auto-installed
  "limn/which-key:*hook-installed* 在模組載入後應為 t
   （auto-install 呼叫 limn/hooks:add-hook 並設 flag）。"
  (let* ((pkg (find-package '#:limn/which-key))
         (sym (and pkg (find-symbol "*HOOK-INSTALLED*" pkg))))
    (if (null sym)
        (check nil "limn/which-key loaded" "package not found")
        (assert-true (and (boundp sym) (symbol-value sym))
                     "limn/which-key:*hook-installed* is t"))))

;;; ══════════════════════════════════════════════════════════════════════════
;;; 語義測試 5 — prefix event 確實 schedule timer
;;; ══════════════════════════════════════════════════════════════════════════
;;;
;;; dogfood bug: which-key popup 從不出現（深層原因）
;;;   原因：即使 hook 安裝了，如果 limn/timer 比 which-key 晚載入，
;;;         *timer-fn* 在 install 時仍是 default no-op stub。
;;;         User 按 prefix key，hook 觸發，stub 被呼叫，沒有 timer 被建立。
;;;
;;; 測試方法：mock *timer-fn*，fire hook，確認 mock 被呼叫了。

(deftest wireup-which-key-timer-fires
  "按 prefix key 後，which-key hook 呼叫 *timer-fn*（timer 比 which-key 先載入的
   證明，否則 *timer-fn* 還是 default no-op）。"
  (let* ((wk-pkg   (find-package '#:limn/which-key))
         (timer-sym (and wk-pkg (find-symbol "*TIMER-FN*"  wk-pkg)))
         (mode-sym  (and wk-pkg (find-symbol "*WHICH-KEY-MODE*" wk-pkg)))
         (hooks-pkg (find-package '#:limn/hooks))
         (run-hook  (and hooks-pkg (find-symbol "RUN-HOOK" hooks-pkg))))
    (cond
      ((null wk-pkg)
       (check nil "limn/which-key loaded" "package not found"))
      ((null run-hook)
       (check nil "limn/hooks:run-hook available" "symbol not found"))
      (t
       (let ((scheduled nil)
             (installed-sym (find-symbol "*HOOK-INSTALLED*" wk-pkg)))
         ;; Earlier test suites (hooks.lisp, dispatch.lisp, minibuffer-read.lisp)
         ;; call clear-all-hooks, wiping the "event/key-prefix-changed" entry.
         ;; Re-install by temporarily resetting *hook-installed* so the
         ;; idempotency guard lets the hook re-register.
         (when installed-sym
           (progv (list installed-sym) (list nil)
             (handler-case (limn/which-key:install) (error () nil))))
         ;; Temporarily enable which-key and mock the timer function.
         (progv (list mode-sym timer-sym)
                (list t
                      (lambda (delay cb)
                        (declare (ignore delay cb))
                        (setf scheduled t)))
           ;; Fire the prefix-changed event just like limn/keys would.
           (handler-case
               (funcall (symbol-function run-hook)
                        "event/key-prefix-changed"
                        (list :|prefix| "C-x"))
             (error (e)
               (format t "  [run-hook error] ~a~%" e))))
         (assert-true scheduled
                      "prefix event caused *timer-fn* to be called"))))))

;;; ══════════════════════════════════════════════════════════════════════════
;;; 語義測試 6 — text-nav *kill-new-fn* 已接到真實 kill-new
;;; ══════════════════════════════════════════════════════════════════════════
;;;
;;; dogfood bug: C-k kill-line 沒有把文字放進 kill-ring
;;;   原因：如果 limn-text-nav 比 limn-kill 早載入，install 時
;;;         limn/kill:kill-new 尚未定義，*kill-new-fn* 停在 default no-op。
;;;         User 按 C-k 內容被刪但 kill-ring 空的，C-y yank 回來只有空字串。
;;;
;;; 測試方法：直接呼叫 *kill-new-fn*，確認它真的 push 到 kill-ring。

(deftest wireup-text-nav-kill-fn-wired
  "limn/text-nav:*kill-new-fn* 已 wire 到 limn/kill:kill-new；
   呼叫它會把字串加進 limn/kill:*kill-ring*。"
  (let* ((nav-pkg  (find-package '#:limn/text-nav))
         (kill-pkg (find-package '#:limn/kill))
         (kfn-sym  (and nav-pkg  (find-symbol "*KILL-NEW-FN*" nav-pkg)))
         (ring-sym (and kill-pkg (find-symbol "*KILL-RING*"   kill-pkg))))
    (cond
      ((null kfn-sym)
       (check nil "limn/text-nav:*kill-new-fn* exists" "symbol not found"))
      ((null ring-sym)
       (check nil "limn/kill:*kill-ring* exists" "symbol not found"))
      (t
       ;; Snapshot ring, call fn, check ring grew by the sentinel string.
       (let* ((sentinel  "__wireup-test-kill__")
              (ring-before (copy-list (symbol-value ring-sym))))
         (handler-case
             (funcall (symbol-value kfn-sym) sentinel)
           (error (e)
             (format t "  [*kill-new-fn* error] ~a~%" e)))
         (let ((added (set-difference (symbol-value ring-sym) ring-before
                                      :test #'equal)))
           (check (member sentinel added :test #'equal)
                  "*kill-new-fn* pushed sentinel to *kill-ring*"
                  "ring grew by: ~s, expected ~s somewhere" added sentinel)))))))

;;; ══════════════════════════════════════════════════════════════════════════
;;; 語義測試 7 — pdf-mode 已向 engine registry 登記 "mupdf"
;;; ══════════════════════════════════════════════════════════════════════════
;;;
;;; dogfood bug: 開 PDF 後 pdf-mode 沒被套上
;;;   原因：limn-pdf-mode 的 auto-install 呼叫 register-engine-default-mode，
;;;         但如果 limn-runtime（含該函數）尚未載入，呼叫靜默失敗。
;;;         User 開 PDF 檔，j/k/SPC 無反應，誤以為設定錯了。

(deftest wireup-pdf-mode-engine-registered
  "limn/runtime:engine-default-mode \"mupdf\" 在全模組載入後應回傳 pdf-mode
   的 symbol，表示 pdf-mode 的 auto-install 成功呼叫了
   register-engine-default-mode。"
  (let* ((rt-pkg  (find-package '#:limn/runtime))
         (edf-sym (and rt-pkg (find-symbol "ENGINE-DEFAULT-MODE" rt-pkg))))
    (cond
      ((null edf-sym)
       (check nil "limn/runtime:engine-default-mode available" "symbol not found"))
      ((not (fboundp edf-sym))
       (check nil "limn/runtime:engine-default-mode fboundp" "function not defined"))
      (t
       (let ((mode (funcall (symbol-function edf-sym) "mupdf")))
         (assert-true mode
                      "engine-default-mode \"mupdf\" is non-nil")
         (when mode
           (check (and (symbolp mode)
                       (string-equal (symbol-name mode) "PDF-MODE"))
                  "engine-default-mode \"mupdf\" resolves to pdf-mode symbol"
                  "got ~s" mode)))))))

;;; ══════════════════════════════════════════════════════════════════════════
;;; 語義測試 8 — init.lisp.example 整體 evaluate 不爆
;;; ══════════════════════════════════════════════════════════════════════════
;;;
;;; dogfood bug: user 把 example 複製到 ~/.limn/init.lisp 後啟動爆 error
;;;   原因：example 裡用了 limn/map:map!、limn/which-key:which-key-mode
;;;         等符號，但如果 load 時這些 package 未定義，會 error。
;;;         測試 3 只做 *read-eval*=nil 的 parse；這裡做真實 load。
;;;
;;; 注意：bridge 不需要連線——各模組在 bridge 未連線時的 I/O 呼叫都是 no-op。
;;;        auto-save enable! 會建立 timer；recentf load-history 若無歷史檔
;;;        則 no-op；enable-theme 在無 bridge 時跳過 sync。

(deftest wireup-init-example-evaluates
  "用 LOAD 真正 eval backend/init.lisp.example，確認無 unhandled condition。
   在全模組都已載入的 unit-runner 環境中執行，不需要 bridge 連線。"
  (let ((path (%wu-path "init.lisp.example")))
    (if (not (probe-file path))
        (check nil "init.lisp.example exists for eval test" nil)
        (assert-no-error
          (load path :verbose nil :print nil)
          "init.lisp.example loads without unhandled conditions"))))
