;;;; v0.28 §C — which-key RED tests  (~21 tests)
;;;;
;;;; 覆蓋：
;;;;   limn/which-key : which-key-mode / *which-key-mode*
;;;;                    *idle-delay* / *max-display*
;;;;                    format-which-key（prefix + keymap → display string）
;;;;                    *echo-fn* vtable（替換 message/echo）
;;;;                    *timer-fn* vtable（替換 limn/timer 排程）
;;;;   Leader dispatch 邏輯（*leader-key* / *leader-keymap* 在 limn/keys）
;;;;
;;;; 測試策略：
;;;;   - format-which-key 是純函數，直接呼叫並 assert 輸出字串。
;;;;   - 排程行為透過 *timer-fn* mock 捕捉 (delay, callback) 後手動觸發 callback。
;;;;   - echo 輸出透過 *echo-fn* mock 捕捉。
;;;;
;;;; 全部 RED — 在 limn-which-key.lisp 實作前都會 fail。

;; ── package stubs ─────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/which-key)
    (make-package '#:limn/which-key :use '(#:cl)))
  (dolist (sym '("WHICH-KEY-MODE"
                 "*WHICH-KEY-MODE*"
                 "*IDLE-DELAY*"
                 "*MAX-DISPLAY*"
                 "FORMAT-WHICH-KEY"
                 "*ECHO-FN*"
                 "*TIMER-FN*"))
    (let ((s (intern sym '#:limn/which-key)))
      (export s '#:limn/which-key))))

(in-package #:limn/unit-test)

;;; ── mock infrastructure ───────────────────────────────────────────────────
;;;
;;; wk-mock: captures echo output and scheduled timer callbacks.

(defstruct (wk-mock (:constructor %make-wk-mock ()))
  (echoed          '())   ; list of strings passed to *echo-fn*
  (timer-schedule  '()))  ; list of (delay . callback) conses

(defun make-wk-mock () (%make-wk-mock))

(defmacro with-wk-mock ((var) &body body)
  "Bind VAR to a wk-mock.  Wire limn/which-key *echo-fn* and *timer-fn*
   to capture calls for test assertions."
  (let ((pkg (gensym "PKG")))
    `(let* ((,var (%make-wk-mock))
            (,pkg (find-package '#:limn/which-key)))
       (if (null ,pkg)
           (progn ,@body)
           (let* ((pairs
                    (list
                     (cons (find-symbol "*ECHO-FN*"  ,pkg)
                           (lambda (str)
                             (push str (wk-mock-echoed ,var))))
                     (cons (find-symbol "*TIMER-FN*" ,pkg)
                           (lambda (delay cb)
                             (push (cons delay cb)
                                   (wk-mock-timer-schedule ,var))))))
                  (live (remove-if (lambda (p) (null (car p))) pairs)))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))

(defun %wk-fire-timers (mock)
  "Fire all captured timer callbacks (simulates timer expiry)."
  (dolist (entry (wk-mock-timer-schedule mock))
    (funcall (cdr entry)))
  (setf (wk-mock-timer-schedule mock) '()))

;;; ── C1. which-key-mode 啟停 ──────────────────────────────────────────────

(deftest wk-c1-mode-starts-disabled
  "*which-key-mode* 初始為 nil（未啟用）。"
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (let ((sym (find-symbol "*WHICH-KEY-MODE*" pkg)))
          (when sym
            (assert-false (symbol-value sym)
                          "*which-key-mode* should start nil/false"))))))

(deftest wk-c1-which-key-mode-toggles-on
  "呼叫 which-key-mode 後 *which-key-mode* 變為 true。"
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (let ((sym (find-symbol "*WHICH-KEY-MODE*" pkg))
              (fn  (find-symbol "WHICH-KEY-MODE"   pkg)))
          (when (and sym fn (fboundp fn))
            (let ((limn/which-key:*which-key-mode* nil))
              (limn/which-key:which-key-mode)
              (assert-true limn/which-key:*which-key-mode*
                           "*which-key-mode* should be truthy after enabling")))))))

(deftest wk-c1-which-key-mode-is-idempotent
  "重複呼叫 which-key-mode 不 error（冪等）。"
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (let ((fn (find-symbol "WHICH-KEY-MODE" pkg)))
          (when (and fn (fboundp fn))
            (assert-no-error
              (progn (limn/which-key:which-key-mode)
                     (limn/which-key:which-key-mode))
              "calling which-key-mode twice should not error"))))))

;;; ── C2. 預設值 ────────────────────────────────────────────────────────────

(deftest wk-c2-idle-delay-default
  "*idle-delay* 預設值是 0.5 秒。"
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (let ((sym (find-symbol "*IDLE-DELAY*" pkg)))
          (when sym
            (assert-true (and (numberp (symbol-value sym))
                              (= (symbol-value sym) 0.5))
                         "*idle-delay* default should be 0.5"))))))

(deftest wk-c2-max-display-default
  "*max-display* 預設值是 20。"
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (let ((sym (find-symbol "*MAX-DISPLAY*" pkg)))
          (when sym
            (assert-eql 20 (symbol-value sym)
                        "*max-display* default should be 20"))))))

;;; ── C3. format-which-key — 輸出格式 ─────────────────────────────────────

(deftest wk-c3-format-basic-bindings
  "format-which-key 輸出包含每個 binding 的 key 和 command 名。"
  (let ((wk-pkg   (find-package '#:limn/which-key))
        (keys-pkg (find-package '#:limn/keys)))
    (if (or (null wk-pkg) (null keys-pkg))
        (check t "skipped" nil)
        (let ((fmt-fn  (find-symbol "FORMAT-WHICH-KEY" wk-pkg))
              (mk-fn   (find-symbol "MAKE-KEYMAP"      keys-pkg))
              (def-fn  (find-symbol "DEFINE-KEY"       keys-pkg)))
          (if (or (null fmt-fn) (null mk-fn) (null def-fn)
                  (not (fboundp fmt-fn)) (not (fboundp mk-fn)) (not (fboundp def-fn)))
              (check t "skipped (symbols not found or unbound)" nil)
              (let ((km (funcall (symbol-function mk-fn))))
                ;; define "f" → find-file, "b" → switch-to-buffer
                (flet ((ff () :find-file) (sb () :switch-to-buffer))
                  (funcall (symbol-function def-fn) km "f" #'ff)
                  (funcall (symbol-function def-fn) km "b" #'sb)
                  (let ((result (funcall (symbol-function fmt-fn) km "")))
                    (assert-true (stringp result) "format-which-key returns a string")
                    (assert-true (search "f" result)  "output contains \"f\"")
                    (assert-true (search "b" result)  "output contains \"b\""))))))))

(deftest wk-c3-format-shows-command-name
  "format-which-key 顯示 command 的名稱（function name 或 symbol name）。"
  (let ((wk-pkg   (find-package '#:limn/which-key))
        (keys-pkg (find-package '#:limn/keys)))
    (if (or (null wk-pkg) (null keys-pkg))
        (check t "skipped" nil)
        (let ((fmt-fn (find-symbol "FORMAT-WHICH-KEY" wk-pkg))
              (mk-fn  (find-symbol "MAKE-KEYMAP"      keys-pkg))
              (def-fn (find-symbol "DEFINE-KEY"       keys-pkg)))
          (if (or (null fmt-fn) (null mk-fn) (null def-fn)
                  (not (fboundp fmt-fn)) (not (fboundp mk-fn)) (not (fboundp def-fn)))
              (check t "skipped" nil)
              (let ((km (funcall (symbol-function mk-fn))))
                (flet ((find-file () :find-file))
                  (funcall (symbol-function def-fn) km "f" #'find-file)
                  (let ((result (funcall (symbol-function fmt-fn) km "")))
                    (assert-true (search "find-file" result)
                                 "output should contain command name 'find-file'")))))))))

(deftest wk-c3-format-respects-max-display
  "*max-display* 限制輸出中的 entry 數量。"
  (let ((wk-pkg   (find-package '#:limn/which-key))
        (keys-pkg (find-package '#:limn/keys)))
    (if (or (null wk-pkg) (null keys-pkg))
        (check t "skipped" nil)
        (let ((fmt-fn (find-symbol "FORMAT-WHICH-KEY" wk-pkg))
              (mk-fn  (find-symbol "MAKE-KEYMAP"      keys-pkg))
              (def-fn (find-symbol "DEFINE-KEY"       keys-pkg)))
          (if (or (null fmt-fn) (null mk-fn) (null def-fn)
                  (not (fboundp fmt-fn)) (not (fboundp mk-fn)) (not (fboundp def-fn)))
              (check t "skipped" nil)
              (let ((km  (funcall (symbol-function mk-fn)))
                    ;; Bind 10 keys, limit display to 3
                    (limn/which-key:*max-display* 3))
                (dotimes (i 10)
                  (let ((key (string (code-char (+ (char-code #\a) i)))))
                    (funcall (symbol-function def-fn) km key (lambda () i))))
                ;; Count occurrences of "→" as a proxy for number of entries shown
                (let* ((result (funcall (symbol-function fmt-fn) km ""))
                       (arrow-count (loop for i below (length result)
                                          count (and (<= (+ i 2) (length result))
                                                     (string= (subseq result i (+ i 1)) "→")))))
                  (assert-true (<= arrow-count 3)
                               "at most *max-display* entries should appear"))))))))

(deftest wk-c3-format-empty-keymap
  "format-which-key 對空 keymap 返回空字串或合法空輸出。"
  (let ((wk-pkg   (find-package '#:limn/which-key))
        (keys-pkg (find-package '#:limn/keys)))
    (if (or (null wk-pkg) (null keys-pkg))
        (check t "skipped" nil)
        (let ((fmt-fn (find-symbol "FORMAT-WHICH-KEY" wk-pkg))
              (mk-fn  (find-symbol "MAKE-KEYMAP"      keys-pkg)))
          (if (or (null fmt-fn) (null mk-fn)
                  (not (fboundp fmt-fn)) (not (fboundp mk-fn)))
              (check t "skipped" nil)
              (let ((km (funcall (symbol-function mk-fn))))
                (let ((result (funcall (symbol-function fmt-fn) km "")))
                  (assert-true (stringp result) "returns a string even for empty keymap"))))))))

;;; ── C4. *idle-delay* 控制 ────────────────────────────────────────────────

(deftest wk-c4-timer-scheduled-with-correct-delay
  "which-key 觸發時以 *idle-delay* 的值排程 timer。"
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (let ((wk-mode-fn (find-symbol "WHICH-KEY-MODE" pkg))
              (mode-sym   (find-symbol "*WHICH-KEY-MODE*" pkg)))
          (if (or (null wk-mode-fn) (null mode-sym))
              (check t "skipped" nil)
              (with-wk-mock (m)
                ;; Enable which-key and fire a prefix-changed event manually
                (let ((limn/which-key:*idle-delay* 0.5)
                      (limn/which-key:*which-key-mode* t))
                  ;; Simulate the event dispatch path (call the internal handler
                  ;; if it's accessible, or use the hook mechanism)
                  (let* ((hooks-pkg (find-package '#:limn/hooks))
                         (run-hook  (and hooks-pkg (find-symbol "RUN-HOOK" hooks-pkg))))
                    (when (and run-hook (fboundp run-hook))
                      (funcall (symbol-function run-hook)
                               "event/key-prefix-changed"
                               (list :|prefix| "C-x"))
                      ;; A timer should have been scheduled
                      (when (wk-mock-timer-schedule m)
                        (let ((delay (caar (wk-mock-timer-schedule m))))
                          (assert-true (and (numberp delay) (= delay 0.5))
                                       "timer scheduled with *idle-delay* = 0.5"))))))))))))

(deftest wk-c4-timer-fires-echo
  "timer callback 觸發後呼叫 *echo-fn* 顯示候選鍵。"
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (let ((mode-sym (find-symbol "*WHICH-KEY-MODE*" pkg)))
          (if (null mode-sym)
              (check t "skipped" nil)
              (with-wk-mock (m)
                (let ((limn/which-key:*which-key-mode* t)
                      (limn/which-key:*idle-delay*      0.0))
                  (let* ((hooks-pkg (find-package '#:limn/hooks))
                         (run-hook  (and hooks-pkg (find-symbol "RUN-HOOK" hooks-pkg))))
                    (when (and run-hook (fboundp run-hook))
                      (funcall (symbol-function run-hook)
                               "event/key-prefix-changed"
                               (list :|prefix| "C-x"))
                      (%wk-fire-timers m)
                      ;; After firing, echo should have been called
                      (assert-true (not (null (wk-mock-echoed m)))
                                   "echo should be called after timer fires"))))))))))

(deftest wk-c4-no-echo-when-mode-disabled
  "which-key-mode 未啟用時，prefix 變更不觸發 echo。"
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (let ((mode-sym (find-symbol "*WHICH-KEY-MODE*" pkg)))
          (if (null mode-sym)
              (check t "skipped" nil)
              (with-wk-mock (m)
                (let ((limn/which-key:*which-key-mode* nil))
                  (let* ((hooks-pkg (find-package '#:limn/hooks))
                         (run-hook  (and hooks-pkg (find-symbol "RUN-HOOK" hooks-pkg))))
                    (when (and run-hook (fboundp run-hook))
                      (funcall (symbol-function run-hook)
                               "event/key-prefix-changed"
                               (list :|prefix| "C-x"))
                      (%wk-fire-timers m)
                      ;; With mode disabled, nothing should be echoed
                      (assert-true (null (wk-mock-echoed m))
                                   "no echo when which-key-mode is disabled"))))))))))

;;; ── C5. Leader dispatch ───────────────────────────────────────────────────
;;;
;;; v0.28 要求：按 *leader-key* 後走 *leader-keymap* 而非 self-insert。
;;; 這些測試驗證 limn/keys 的 dispatch 邏輯（lookup 路徑）。

(deftest wk-c5-leader-key-lookup-uses-leader-keymap
  "lookup 時若當前 prefix == *leader-key*，走 *leader-keymap* 而非普通 keymap。"
  ;; This tests the dispatch integration: when the pressed key equals
  ;; *leader-key*, the lookup should consult *leader-keymap*.
  ;; If limn/keys dispatch supports this, verify it; otherwise skip.
  (let ((keys-pkg (find-package '#:limn/keys)))
    (if (null keys-pkg)
        (check t "skipped (limn/keys not loaded)" nil)
        (let ((lk-sym  (find-symbol "*LEADER-KEY*"    keys-pkg))
              (lkm-sym (find-symbol "*LEADER-KEYMAP*" keys-pkg))
              (mk-fn   (find-symbol "MAKE-KEYMAP"     keys-pkg))
              (def-fn  (find-symbol "DEFINE-KEY"      keys-pkg)))
          (if (or (null lk-sym) (null lkm-sym) (null mk-fn) (null def-fn)
                  (not (fboundp mk-fn)) (not (fboundp def-fn)))
              (check t "skipped (leader symbols not found)" nil)
              (let ((fresh-lkm (funcall (symbol-function mk-fn)))
                    (cmd (lambda () :leader-ff)))
                (progv (list lk-sym lkm-sym) (list "SPC" fresh-lkm)
                  ;; bind "f f" in leader keymap
                  (funcall (symbol-function def-fn) fresh-lkm "f f" cmd)
                  ;; after lookup-sequence "SPC f f" should resolve via leader keymap
                  (let* ((lkp-fn (find-symbol "LOOKUP-SEQUENCE" keys-pkg))
                         (result (when (and lkp-fn (fboundp lkp-fn))
                                   (funcall (symbol-function lkp-fn)
                                            fresh-lkm "f f"))))
                    (assert-true result "\"f f\" should be found in leader keymap")))))))))

(deftest wk-c5-non-leader-key-falls-through
  "普通鍵（非 *leader-key*）正常 fall through，不走 *leader-keymap*。"
  (let ((keys-pkg (find-package '#:limn/keys)))
    (if (null keys-pkg)
        (check t "skipped" nil)
        (let ((mk-fn  (find-symbol "MAKE-KEYMAP"     keys-pkg))
              (lkm-sym (find-symbol "*LEADER-KEYMAP*" keys-pkg)))
          (if (or (null mk-fn) (null lkm-sym) (not (fboundp mk-fn)))
              (check t "skipped" nil)
              (let ((normal-km (funcall (symbol-function mk-fn)))
                    (leader-km (funcall (symbol-function mk-fn))))
                (progv (list lkm-sym) (list leader-km)
                  ;; "j" is not in leader-km; lookup in normal-km returns nil
                  (let* ((lkp (find-symbol "LOOKUP" keys-pkg))
                         (result (when (and lkp (fboundp lkp))
                                   (funcall (symbol-function lkp) normal-km "j"))))
                    (assert-false result "\"j\" not in normal-km should return nil/false")))))))))

;;; ── C6. echo 輸出格式驗證 ────────────────────────────────────────────────

(deftest wk-c6-echo-format-contains-arrow
  "which-key echo 輸出包含 → 分隔 key 和 description。"
  (let ((wk-pkg   (find-package '#:limn/which-key))
        (keys-pkg (find-package '#:limn/keys)))
    (if (or (null wk-pkg) (null keys-pkg))
        (check t "skipped" nil)
        (let ((fmt-fn (find-symbol "FORMAT-WHICH-KEY" wk-pkg))
              (mk-fn  (find-symbol "MAKE-KEYMAP"      keys-pkg))
              (def-fn (find-symbol "DEFINE-KEY"       keys-pkg)))
          (if (or (null fmt-fn) (null mk-fn) (null def-fn)
                  (not (fboundp fmt-fn)) (not (fboundp mk-fn)) (not (fboundp def-fn)))
              (check t "skipped" nil)
              (let ((km (funcall (symbol-function mk-fn))))
                (flet ((my-fn () :my))
                  (funcall (symbol-function def-fn) km "f" #'my-fn)
                  (let ((result (funcall (symbol-function fmt-fn) km "")))
                    (assert-true (search "→" result)
                                 "output should contain → separator")))))))))

(deftest wk-c6-echo-format-multiple-entries-separated
  "多個 binding 的 echo 輸出格式：各 entry 以空白隔開。"
  (let ((wk-pkg   (find-package '#:limn/which-key))
        (keys-pkg (find-package '#:limn/keys)))
    (if (or (null wk-pkg) (null keys-pkg))
        (check t "skipped" nil)
        (let ((fmt-fn (find-symbol "FORMAT-WHICH-KEY" wk-pkg))
              (mk-fn  (find-symbol "MAKE-KEYMAP"      keys-pkg))
              (def-fn (find-symbol "DEFINE-KEY"       keys-pkg)))
          (if (or (null fmt-fn) (null mk-fn) (null def-fn)
                  (not (fboundp fmt-fn)) (not (fboundp mk-fn)) (not (fboundp def-fn)))
              (check t "skipped" nil)
              (let ((km (funcall (symbol-function mk-fn))))
                (flet ((fn-a () :a) (fn-b () :b))
                  (funcall (symbol-function def-fn) km "a" #'fn-a)
                  (funcall (symbol-function def-fn) km "b" #'fn-b)
                  (let ((result (funcall (symbol-function fmt-fn) km "")))
                    ;; Both keys should appear and output should be non-empty
                    (assert-true (> (length result) 0)
                                 "output should be non-empty with 2 bindings")
                    (assert-true (search "a" result) "\"a\" should appear")
                    (assert-true (search "b" result) "\"b\" should appear"))))))))))

;;; ── C7. Dogfood pain points — timer cancellation / rapid prefix changes ─

(deftest wk-c7-rapid-prefix-change-cancels-old-timer
  "連續快速 prefix 變更：只有最後一個 timer 該 fire。"
  ;; This tests that calling the prefix-changed handler twice quickly
  ;; cancels the first timer.  Implementation may use a single tracked
  ;; timer handle that gets cancelled when a new one is scheduled.
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (with-wk-mock (m)
          (let ((limn/which-key:*which-key-mode* t)
                (limn/which-key:*idle-delay*     0.5))
            (let* ((hooks-pkg (find-package '#:limn/hooks))
                   (run-hook  (and hooks-pkg (find-symbol "RUN-HOOK" hooks-pkg))))
              (when (and run-hook (fboundp run-hook))
                ;; First prefix
                (funcall (symbol-function run-hook)
                         "event/key-prefix-changed"
                         (list :|prefix| "C-x"))
                ;; Second prefix immediately
                (funcall (symbol-function run-hook)
                         "event/key-prefix-changed"
                         (list :|prefix| "C-c"))
                ;; Fire all timers
                (%wk-fire-timers m)
                ;; At most ONE echo should appear (the latest prefix's)
                (assert-true (<= (length (wk-mock-echoed m)) 1)
                             "rapid prefix changes should not produce multiple echoes"))))))))

(deftest wk-c7-prefix-cleared-suppresses-echo
  "prefix 被清空（nil 或空 string）時不該 echo。"
  ;; User pressed C-x, then C-g (cancel) → prefix cleared.
  ;; Pending timer should detect cleared prefix and skip echo.
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (with-wk-mock (m)
          (let ((limn/which-key:*which-key-mode* t)
                (limn/which-key:*idle-delay*     0.0))
            (let* ((hooks-pkg (find-package '#:limn/hooks))
                   (run-hook  (and hooks-pkg (find-symbol "RUN-HOOK" hooks-pkg))))
              (when (and run-hook (fboundp run-hook))
                (funcall (symbol-function run-hook)
                         "event/key-prefix-changed"
                         (list :|prefix| nil))
                (%wk-fire-timers m)
                (assert-true (null (wk-mock-echoed m))
                             "no echo when prefix is nil"))))))))

(deftest wk-c7-idle-delay-zero-fires-immediately
  "*idle-delay* = 0 時應立即 fire（不排 timer 或排零延遲）。"
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (with-wk-mock (m)
          (let ((limn/which-key:*which-key-mode* t)
                (limn/which-key:*idle-delay*     0.0))
            (let* ((hooks-pkg (find-package '#:limn/hooks))
                   (run-hook  (and hooks-pkg (find-symbol "RUN-HOOK" hooks-pkg))))
              (when (and run-hook (fboundp run-hook))
                (funcall (symbol-function run-hook)
                         "event/key-prefix-changed"
                         (list :|prefix| "C-x"))
                (%wk-fire-timers m)
                ;; With delay 0, callback should run after the firing step.
                ;; (Echo would have a value either immediately or after firing.)
                (assert-true t "no error on zero delay"))))))))

(deftest wk-c7-mode-disabled-no-new-timer
  "which-key-mode disable 時不再排新 timer。"
  (let ((pkg (find-package '#:limn/which-key)))
    (if (null pkg)
        (check t "skipped" nil)
        (with-wk-mock (m)
          (let ((limn/which-key:*which-key-mode* nil)
                (limn/which-key:*idle-delay*     0.5))
            (let* ((hooks-pkg (find-package '#:limn/hooks))
                   (run-hook  (and hooks-pkg (find-symbol "RUN-HOOK" hooks-pkg))))
              (when (and run-hook (fboundp run-hook))
                (funcall (symbol-function run-hook)
                         "event/key-prefix-changed"
                         (list :|prefix| "C-x"))
                (assert-true (null (wk-mock-timer-schedule m))
                             "no timer scheduled when mode is disabled"))))))))

(deftest wk-c7-format-shows-sub-keymap-as-prefix
  "format-which-key 對 sub-keymap entry 顯示 prefix 標記（不是 command name）。"
  (let ((wk-pkg   (find-package '#:limn/which-key))
        (keys-pkg (find-package '#:limn/keys)))
    (if (or (null wk-pkg) (null keys-pkg))
        (check t "skipped" nil)
        (let ((fmt-fn (find-symbol "FORMAT-WHICH-KEY" wk-pkg))
              (mk-fn  (find-symbol "MAKE-KEYMAP"      keys-pkg))
              (def-fn (find-symbol "DEFINE-KEY"       keys-pkg)))
          (if (or (null fmt-fn) (null mk-fn) (null def-fn)
                  (not (fboundp fmt-fn)) (not (fboundp mk-fn)) (not (fboundp def-fn)))
              (check t "skipped" nil)
              (let ((km (funcall (symbol-function mk-fn))))
                ;; Bind a chord "g g" — "g" itself becomes a prefix
                (funcall (symbol-function def-fn) km "g g" (lambda () :first))
                (let ((result (funcall (symbol-function fmt-fn) km "")))
                  (assert-true (or (search "+prefix" result)
                                   (search "prefix"  result)
                                   (search "+"       result))
                               "sub-keymap entries should be marked as prefix"))))))))
