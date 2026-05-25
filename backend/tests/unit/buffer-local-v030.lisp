;;;; v0.30 §B — buffer-local variables RED tests (~30 tests)
;;;;
;;;; 覆蓋：
;;;;   limn/local : defvar-local / setq-local / make-variable-buffer-local
;;;;                get / set / bound-p
;;;;                default-value / buffer-local-value
;;;;                set-buffer-local-value / kill-local-variable
;;;;                local-variable-p
;;;;                *current-buffer-id* (dynamic var for "current" context)
;;;;                *buffer-local-changed-fn* (event vtable for test capture)
;;;;                reset-buffer-locals (test cleanup)
;;;;
;;;; Lookup 路徑（SPEC v0.30）：
;;;;   (limn/local:get SYM) →
;;;;     1. 看當前 buffer 的 local-vars 有無 SYM
;;;;     2. 沒有 → 回 (symbol-value SYM)（global default）
;;;;
;;;; 全部 RED — 在 limn-local.lisp 實作前都會 fail。

;; ── package stub ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/local)
    (make-package '#:limn/local :use '(#:cl)))
  (dolist (sym '(;; public API
                 "GET"
                 "SET"
                 "BOUND-P"
                 "DEFAULT-VALUE"
                 "BUFFER-LOCAL-VALUE"
                 "SET-BUFFER-LOCAL-VALUE"
                 "KILL-LOCAL-VARIABLE"
                 "LOCAL-VARIABLE-P"
                 "MAKE-VARIABLE-BUFFER-LOCAL"
                 ;; macros
                 "DEFVAR-LOCAL"
                 "SETQ-LOCAL"
                 ;; dynamic vars
                 "*CURRENT-BUFFER-ID*"
                 ;; event vtable
                 "*BUFFER-LOCAL-CHANGED-FN*"
                 ;; test helpers
                 "RESET-BUFFER-LOCALS"))
    (export (intern sym '#:limn/local) '#:limn/local)))

(in-package #:limn/unit-test)

;;; ── mock infrastructure ──────────────────────────────────────────────────
;;;
;;; with-local-ctx — binds *current-buffer-id* and installs a change-event
;;; accumulator. Resets buffer-local state for all named buffers after body.

(defmacro with-local-ctx ((&rest buf-ids) &body body)
  "Run BODY with limn/local:*current-buffer-id* unbound (set per-test).
   Reset all local state for BUF-IDS before and after body."
  (let ((pkg   (gensym "PKG"))
        (reset (gensym "RESET")))
    `(let* ((,pkg (find-package '#:limn/local))
            (,reset (lambda ()
                      (when ,pkg
                        (let ((fn (find-symbol "RESET-BUFFER-LOCALS" ,pkg)))
                          (when fn
                            (dolist (id '(,@buf-ids))
                              (funcall fn id))))))))
       (funcall ,reset)
       (unwind-protect
            (progn ,@body)
         (funcall ,reset)))))

(defmacro with-current-buf (buf-id &body body)
  "Bind limn/local:*current-buffer-id* to BUF-ID for the duration of BODY."
  (let ((pkg  (gensym "PKG"))
        (sym  (gensym "SYM")))
    `(let* ((,pkg (find-package '#:limn/local))
            (,sym (when ,pkg (find-symbol "*CURRENT-BUFFER-ID*" ,pkg))))
       (if (null ,sym)
           (progn ,@body)
           (progv (list ,sym) (list ,buf-id)
             ,@body)))))

;;; Helper: collect buffer-local-changed events into a list.
(defmacro with-event-capture ((events-var) &body body)
  "Bind EVENTS-VAR to a list; push each :buffer-local-changed payload onto it."
  (let ((pkg (gensym "PKG"))
        (sym (gensym "SYM"))
        (lst (gensym "LST")))
    `(let* ((,pkg (find-package '#:limn/local))
            (,sym (when ,pkg (find-symbol "*BUFFER-LOCAL-CHANGED-FN*" ,pkg)))
            (,lst '())
            (,events-var (lambda () ,lst)))
       (if (null ,sym)
           (progn ,@body)
           (progv (list ,sym)
               (list (lambda (payload) (push payload ,lst)))
             (setf ,events-var (lambda () ,lst))
             ,@body)))))

;;; ── B1. defvar-local / basic read-write ──────────────────────────────────

(deftest local-b1-defvar-local-creates-global-default
  "defvar-local *v-b1a* 70 → global default = 70。"
  (with-local-ctx ("b1a")
    (limn/local:defvar-local *v-b1a* 70 "test var")
    (assert-eql 70 (limn/local:default-value '*v-b1a*)
                "default-value = 70")))

(deftest local-b1-setq-local-writes-buffer-A-only
  "setq-local 在 buffer A 設 80 → get 在 A 回 80、在 B 還是 70。"
  (with-local-ctx ("b1b" "b1c")
    (limn/local:defvar-local *v-b1b* 70 "test var")
    (with-current-buf "b1b"
      (limn/local:setq-local *v-b1b* 80)
      (assert-eql 80 (limn/local:get '*v-b1b*)
                  "get in b1b = 80"))
    (with-current-buf "b1c"
      (assert-eql 70 (limn/local:get '*v-b1b*)
                  "get in b1c falls back to default 70"))))

(deftest local-b1-set-buffer-local-value-explicit-buf
  "set-buffer-local-value 顯式指定 buffer-id，不依賴 *current-buffer-id*。"
  (with-local-ctx ("b1d")
    (limn/local:defvar-local *v-b1d* 0 "test var")
    (limn/local:set-buffer-local-value '*v-b1d* 99 "b1d")
    (assert-eql 99 (limn/local:buffer-local-value '*v-b1d* "b1d")
                "buffer-local-value reads what was explicitly set")))

(deftest local-b1-overwrite-local-value
  "連續 setq-local → 最新的值勝出。"
  (with-local-ctx ("b1e")
    (limn/local:defvar-local *v-b1e* 0 "test var")
    (with-current-buf "b1e"
      (limn/local:setq-local *v-b1e* 10)
      (limn/local:setq-local *v-b1e* 20)
      (assert-eql 20 (limn/local:get '*v-b1e*)
                  "last setq-local wins: 20"))))

(deftest local-b1-get-without-local-returns-global
  "沒有設 local 值時，get 回 global default。"
  (with-local-ctx ("b1f")
    (limn/local:defvar-local *v-b1f* 42 "test var")
    (with-current-buf "b1f"
      (assert-eql 42 (limn/local:get '*v-b1f*)
                  "no local → global default 42"))))

(deftest local-b1-non-buffer-local-var-gets-global
  "未 make-variable-buffer-local 的普通 defvar，get 也回 global value。"
  (with-local-ctx ("b1g")
    (defvar *v-b1g-plain* 55)
    (with-current-buf "b1g"
      (assert-eql 55 (limn/local:get '*v-b1g-plain*)
                  "plain defvar: get returns symbol-value"))))

;;; ── B2. kill-local-variable ──────────────────────────────────────────────

(deftest local-b2-kill-local-falls-back-to-default
  "kill-local-variable 後，get 回 global default。"
  (with-local-ctx ("b2a")
    (limn/local:defvar-local *v-b2a* 7 "test var")
    (with-current-buf "b2a"
      (limn/local:setq-local *v-b2a* 99)
      (limn/local:kill-local-variable '*v-b2a*)
      (assert-eql 7 (limn/local:get '*v-b2a*)
                  "after kill, fallback to default 7"))))

(deftest local-b2-kill-local-only-affects-current-buffer
  "kill-local-variable 只刪當前 buffer 的值，其他 buffer 不受影響。"
  (with-local-ctx ("b2b" "b2c")
    (limn/local:defvar-local *v-b2b* 1 "test var")
    (with-current-buf "b2b"
      (limn/local:setq-local *v-b2b* 10))
    (with-current-buf "b2c"
      (limn/local:setq-local *v-b2b* 20))
    (with-current-buf "b2b"
      (limn/local:kill-local-variable '*v-b2b*)
      (assert-eql 1 (limn/local:get '*v-b2b*)
                  "b2b killed → default 1"))
    (with-current-buf "b2c"
      (assert-eql 20 (limn/local:get '*v-b2b*)
                  "b2c unaffected: still 20"))))

(deftest local-b2-kill-nonexistent-local-is-noop
  "kill-local-variable 對沒有 local 的 buffer 不 error。"
  (with-local-ctx ("b2d")
    (limn/local:defvar-local *v-b2d* 5 "test var")
    (with-current-buf "b2d"
      (assert-no-error
       (limn/local:kill-local-variable '*v-b2d*)
       "kill when no local: no error"))))

;;; ── B3. local-variable-p ─────────────────────────────────────────────────

(deftest local-b3-local-variable-p-false-before-set
  "設 local 之前 local-variable-p 回 nil。"
  (with-local-ctx ("b3a")
    (limn/local:defvar-local *v-b3a* 0 "test var")
    (with-current-buf "b3a"
      (assert-false (limn/local:local-variable-p '*v-b3a*)
                    "no local yet → nil"))))

(deftest local-b3-local-variable-p-true-after-set
  "setq-local 後 local-variable-p 回 t。"
  (with-local-ctx ("b3b")
    (limn/local:defvar-local *v-b3b* 0 "test var")
    (with-current-buf "b3b"
      (limn/local:setq-local *v-b3b* 1)
      (assert-true (limn/local:local-variable-p '*v-b3b*)
                   "has local → t"))))

(deftest local-b3-local-variable-p-false-after-kill
  "kill-local-variable 後 local-variable-p 回 nil。"
  (with-local-ctx ("b3c")
    (limn/local:defvar-local *v-b3c* 0 "test var")
    (with-current-buf "b3c"
      (limn/local:setq-local *v-b3c* 1)
      (limn/local:kill-local-variable '*v-b3c*)
      (assert-false (limn/local:local-variable-p '*v-b3c*)
                    "after kill → nil"))))

(deftest local-b3-local-variable-p-with-explicit-buf
  "local-variable-p BUF-ID 不依賴 *current-buffer-id*。"
  (with-local-ctx ("b3d")
    (limn/local:defvar-local *v-b3d* 0 "test var")
    (limn/local:set-buffer-local-value '*v-b3d* 42 "b3d")
    (assert-true (limn/local:local-variable-p '*v-b3d* "b3d")
                 "explicit buf: has local → t")))

;;; ── B4. default-value ────────────────────────────────────────────────────

(deftest local-b4-default-value-skips-buffer-local
  "default-value 跳過 local 值，直接回 global default。"
  (with-local-ctx ("b4a")
    (limn/local:defvar-local *v-b4a* 10 "test var")
    (with-current-buf "b4a"
      (limn/local:setq-local *v-b4a* 99)
      (assert-eql 10 (limn/local:default-value '*v-b4a*)
                  "default-value ignores local 99, returns 10"))))

(deftest local-b4-default-value-unchanged-by-multiple-locals
  "多個 buffer 各設不同 local，default-value 不受影響。"
  (with-local-ctx ("b4b" "b4c")
    (limn/local:defvar-local *v-b4b* 5 "test var")
    (limn/local:set-buffer-local-value '*v-b4b* 11 "b4b")
    (limn/local:set-buffer-local-value '*v-b4b* 22 "b4c")
    (assert-eql 5 (limn/local:default-value '*v-b4b*)
                "default-value stays 5 regardless of any locals")))

(deftest local-b4-set-default-value-changes-fallback
  "修改 global default 後，沒有 local 的 buffer 讀到新的 default。"
  (with-local-ctx ("b4d" "b4e")
    (limn/local:defvar-local *v-b4d* 1 "test var")
    ;; only b4d has local
    (limn/local:set-buffer-local-value '*v-b4d* 99 "b4d")
    ;; change global default
    (setf (symbol-value '*v-b4d*) 50)
    (with-current-buf "b4e"
      (assert-eql 50 (limn/local:get '*v-b4d*)
                  "b4e has no local → new global default 50"))))

;;; ── B5. buffer-local-value explicit ─────────────────────────────────────

(deftest local-b5-buffer-local-value-reads-local
  "buffer-local-value SYM BUF-ID 讀指定 buffer 的 local 值。"
  (with-local-ctx ("b5a")
    (limn/local:defvar-local *v-b5a* 0 "test var")
    (limn/local:set-buffer-local-value '*v-b5a* 77 "b5a")
    (assert-eql 77 (limn/local:buffer-local-value '*v-b5a* "b5a"))))

(deftest local-b5-buffer-local-value-falls-back-when-no-local
  "buffer-local-value 在沒有 local 時回 global default。"
  (with-local-ctx ("b5b")
    (limn/local:defvar-local *v-b5b* 33 "test var")
    (assert-eql 33 (limn/local:buffer-local-value '*v-b5b* "b5b")
                "no local in b5b → global 33")))

;;; ── B6. make-variable-buffer-local ──────────────────────────────────────

(deftest local-b6-make-variable-buffer-local-upgrades-defvar
  "既有 defvar 後用 make-variable-buffer-local 升級，setq-local 正常運作。"
  (with-local-ctx ("b6a")
    (defvar *v-b6a* 100)
    (limn/local:make-variable-buffer-local '*v-b6a*)
    (with-current-buf "b6a"
      (limn/local:setq-local *v-b6a* 200)
      (assert-eql 200 (limn/local:get '*v-b6a*)
                  "after upgrade, setq-local works: 200")
      (assert-eql 100 (limn/local:default-value '*v-b6a*)
                  "global default still 100"))))

(deftest local-b6-make-variable-buffer-local-idempotent
  "重複呼叫 make-variable-buffer-local 不 error。"
  (with-local-ctx ("b6b")
    (defvar *v-b6b* 0)
    (assert-no-error
     (progn (limn/local:make-variable-buffer-local '*v-b6b*)
            (limn/local:make-variable-buffer-local '*v-b6b*))
     "double make-variable-buffer-local: no error")))

(deftest local-b6-defvar-local-equivalent-to-defvar-plus-upgrade
  "defvar-local *v-b6c* X ≡ (defvar *v-b6c* X) + make-variable-buffer-local。"
  (with-local-ctx ("b6c")
    (limn/local:defvar-local *v-b6c* 88 "equiv test")
    (with-current-buf "b6c"
      (limn/local:setq-local *v-b6c* 77)
      (assert-eql 77 (limn/local:get '*v-b6c*)
                  "local = 77")
      (assert-eql 88 (limn/local:default-value '*v-b6c*)
                  "default = 88"))))

;;; ── B7. event :buffer-local-changed ─────────────────────────────────────

(deftest local-b7-set-fires-changed-event
  "setq-local 觸發 *buffer-local-changed-fn*，payload 含四個 key。"
  (with-local-ctx ("b7a")
    (limn/local:defvar-local *v-b7a* 0 "test var")
    (let ((events '()))
      (let ((pkg (find-package '#:limn/local)))
        (when pkg
          (let ((fn-sym (find-symbol "*BUFFER-LOCAL-CHANGED-FN*" pkg)))
            (when fn-sym
              (progv (list fn-sym)
                  (list (lambda (payload) (push payload events)))
                (with-current-buf "b7a"
                  (limn/local:setq-local *v-b7a* 42))
                (assert-true (= 1 (length events))
                             "exactly one event fired")
                (let ((ev (first events)))
                  (assert-equal "b7a" (getf ev :buffer-id)
                                "payload :buffer-id")
                  (assert-eq '*v-b7a* (getf ev :symbol)
                             "payload :symbol")
                  (assert-eql 0 (getf ev :old)
                              "payload :old = 0")
                  (assert-eql 42 (getf ev :new)
                              "payload :new = 42"))))))))))

(deftest local-b7-kill-fires-changed-event
  "kill-local-variable 觸發 event，:new = global default。"
  (with-local-ctx ("b7b")
    (limn/local:defvar-local *v-b7b* 5 "test var")
    (let ((events '()))
      (let ((pkg (find-package '#:limn/local)))
        (when pkg
          (let ((fn-sym (find-symbol "*BUFFER-LOCAL-CHANGED-FN*" pkg)))
            (when fn-sym
              (with-current-buf "b7b"
                (limn/local:setq-local *v-b7b* 50))
              (progv (list fn-sym)
                  (list (lambda (payload) (push payload events)))
                (with-current-buf "b7b"
                  (limn/local:kill-local-variable '*v-b7b*))
                (assert-true (= 1 (length events))
                             "one event from kill")
                (let ((ev (first events)))
                  (assert-eql 50 (getf ev :old)
                              "old = local value before kill")
                  (assert-eql 5  (getf ev :new)
                              "new = global default after kill"))))))))))

(deftest local-b7-set-same-value-no-event
  "setq-local 相同值不觸發 event（old == new）。"
  (with-local-ctx ("b7c")
    (limn/local:defvar-local *v-b7c* 10 "test var")
    (let ((events '()))
      (let ((pkg (find-package '#:limn/local)))
        (when pkg
          (let ((fn-sym (find-symbol "*BUFFER-LOCAL-CHANGED-FN*" pkg)))
            (when fn-sym
              (with-current-buf "b7c"
                (limn/local:setq-local *v-b7c* 10)) ; same as default
              (progv (list fn-sym)
                  (list (lambda (payload) (push payload events)))
                (with-current-buf "b7c"
                  (limn/local:setq-local *v-b7c* 10)) ; same value again
                (assert-eql 0 (length events)
                            "same value → no event fired")))))))))

(deftest local-b7-event-payload-has-all-required-keys
  "event payload 一定含 :buffer-id :symbol :old :new 四個 key。"
  (with-local-ctx ("b7d")
    (limn/local:defvar-local *v-b7d* 0 "test var")
    (let ((events '()))
      (let ((pkg (find-package '#:limn/local)))
        (when pkg
          (let ((fn-sym (find-symbol "*BUFFER-LOCAL-CHANGED-FN*" pkg)))
            (when fn-sym
              (progv (list fn-sym)
                  (list (lambda (payload) (push payload events)))
                (with-current-buf "b7d"
                  (limn/local:setq-local *v-b7d* 1))
                (let ((ev (first events)))
                  (dolist (k '(:buffer-id :symbol :old :new))
                    (assert-true (member k ev)
                                 (format nil "payload has ~s key" k))))))))))))

;;; ── B8. Multi-buffer pressure test ──────────────────────────────────────

(deftest local-b8-10-buffers-independent-values
  "10 個 buffer 各設不同值，批次讀取全部正確。"
  (with-local-ctx ("b8-0" "b8-1" "b8-2" "b8-3" "b8-4"
                   "b8-5" "b8-6" "b8-7" "b8-8" "b8-9")
    (limn/local:defvar-local *v-b8* -1 "pressure test var")
    (loop for id in '("b8-0" "b8-1" "b8-2" "b8-3" "b8-4"
                      "b8-5" "b8-6" "b8-7" "b8-8" "b8-9")
          for i from 0
          do (limn/local:set-buffer-local-value '*v-b8* (* i 10) id))
    (loop for id in '("b8-0" "b8-1" "b8-2" "b8-3" "b8-4"
                      "b8-5" "b8-6" "b8-7" "b8-8" "b8-9")
          for i from 0
          do (assert-eql (* i 10)
                         (limn/local:buffer-local-value '*v-b8* id)
                         (format nil "buffer ~a = ~a" id (* i 10))))))

(deftest local-b8-global-default-unaffected-by-mass-set
  "大量設 local 不改變 global default。"
  (with-local-ctx ("b8a" "b8b" "b8c")
    (limn/local:defvar-local *v-b8-def* 999 "pressure default test")
    (dolist (id '("b8a" "b8b" "b8c"))
      (limn/local:set-buffer-local-value '*v-b8-def* 0 id))
    (assert-eql 999 (limn/local:default-value '*v-b8-def*)
                "global default 999 unchanged after mass local sets")))

(deftest local-b8-reset-clears-all-locals-in-buffer
  "reset-buffer-locals 清掉一個 buffer 所有 local，其餘不受影響。"
  (with-local-ctx ("b8x" "b8y")
    (limn/local:defvar-local *v-b8-r1* 1 "reset test 1")
    (limn/local:defvar-local *v-b8-r2* 2 "reset test 2")
    (limn/local:set-buffer-local-value '*v-b8-r1* 10 "b8x")
    (limn/local:set-buffer-local-value '*v-b8-r2* 20 "b8x")
    (limn/local:set-buffer-local-value '*v-b8-r1* 30 "b8y")
    ;; reset only b8x
    (when (find-package '#:limn/local)
      (limn/local:reset-buffer-locals "b8x"))
    (assert-false (limn/local:local-variable-p '*v-b8-r1* "b8x")
                  "b8x r1 cleared")
    (assert-false (limn/local:local-variable-p '*v-b8-r2* "b8x")
                  "b8x r2 cleared")
    (assert-true (limn/local:local-variable-p '*v-b8-r1* "b8y")
                 "b8y r1 unaffected")))

;;; ── B9. Dogfood — 長期使用情境 ──────────────────────────────────────────
;;;
;;; 模擬使用者連續使用 1-2 週後可能遇到的問題：init.el 重 load、未宣告
;;; setq-local、unknown buf-id 查詢、nil 值區分、複雜物件 identity 等。

(deftest local-b9-defvar-local-twice-preserves-existing-local
  "init.el 重 load：defvar-local 重複呼叫，已存的 buffer-local 值不被覆蓋。"
  (with-local-ctx ("b9a")
    (limn/local:defvar-local *v-b9a* 10 "first")
    (with-current-buf "b9a"
      (limn/local:setq-local *v-b9a* 50))
    ;; reload: 第二次 defvar-local（defvar 對已 bound 不重 init）
    (limn/local:defvar-local *v-b9a* 999 "reload")
    (with-current-buf "b9a"
      (assert-eql 50 (limn/local:get '*v-b9a*)
                  "buffer-local 值 survives 第二次 defvar-local"))))

(deftest local-b9-setq-local-auto-marks-undeclared
  "setq-local on 未 make-variable-buffer-local 的 var → 自動標記為 buffer-local。"
  (with-local-ctx ("b9b")
    (defvar *v-b9b* 0)
    ;; 故意不呼叫 make-variable-buffer-local
    (with-current-buf "b9b"
      (limn/local:setq-local *v-b9b* 7)
      (assert-true (limn/local:local-variable-p '*v-b9b*)
                   "auto-marked after setq-local")
      (assert-eql 7 (limn/local:get '*v-b9b*)
                  "value set correctly"))))

(deftest local-b9-buffer-local-value-unknown-buf-returns-default
  "buffer-local-value 對從未設過 local 的 buf-id → 回 global default（不 error）。"
  (with-local-ctx ()
    (limn/local:defvar-local *v-b9c* 33 "test var")
    (assert-eql 33 (limn/local:buffer-local-value '*v-b9c* "never-existed-b9c")
                "unknown buf-id falls back to global default")))

(deftest local-b9-nil-local-value-distinct-from-no-local
  "setq-local var nil → local-variable-p t（區別於 default 也剛好是 nil 的情況）。"
  (with-local-ctx ("b9d")
    (limn/local:defvar-local *v-b9d* "default-string" "test var")
    (with-current-buf "b9d"
      (limn/local:setq-local *v-b9d* nil)
      (assert-true (limn/local:local-variable-p '*v-b9d*)
                   "nil-valued local 仍是 local")
      (assert-eq nil (limn/local:get '*v-b9d*)
                 "get 回 nil (the local), 不是 default-string"))))

(deftest local-b9-event-buffer-id-uses-explicit-arg
  "set-buffer-local-value 顯式指定 buf-id → event :buffer-id 用該值（不是 *current-buffer-id*）。"
  (with-local-ctx ("b9e-explicit" "b9e-current")
    (limn/local:defvar-local *v-b9e* 0 "test var")
    (let ((events '()))
      (let ((pkg (find-package '#:limn/local)))
        (when pkg
          (let ((fn-sym (find-symbol "*BUFFER-LOCAL-CHANGED-FN*" pkg)))
            (when fn-sym
              ;; 故意把 *current* 設成不同的 buffer
              (with-current-buf "b9e-current"
                (progv (list fn-sym)
                    (list (lambda (p) (push p events)))
                  (limn/local:set-buffer-local-value '*v-b9e* 1 "b9e-explicit")
                  (assert-equal "b9e-explicit"
                                (getf (first events) :buffer-id)
                                "event :buffer-id = explicit arg"))))))))))

(deftest local-b9-defvar-local-no-docstring
  "defvar-local 沒給 docstring 也能用。"
  (with-local-ctx ("b9f")
    (assert-no-error
     (limn/local:defvar-local *v-b9f* 5)
     "no docstring: no error")
    (assert-eql 5 (limn/local:default-value '*v-b9f*))))

(deftest local-b9-complex-value-stored-by-identity
  "存 list 進 buffer-local，讀回 eq 同一物件（不複製）。"
  (with-local-ctx ("b9g")
    (limn/local:defvar-local *v-b9g* nil "test var")
    (let ((data (list 1 2 3)))
      (with-current-buf "b9g"
        (limn/local:setq-local *v-b9g* data)
        (assert-eq data (limn/local:get '*v-b9g*)
                   "讀回是 eq 同一 cons")))))

(deftest local-b9-default-value-undeclared-signals
  "default-value 對從未 defvar 的 symbol → signal error。"
  (assert-error error
                (limn/local:default-value 'never-defvared-b9h)
                "unbound symbol → error"))

(deftest local-b9-kill-never-set-no-op-no-event
  "kill-local-variable 對沒有 local 的 var → no-op，不觸發 event。"
  (with-local-ctx ("b9i")
    (limn/local:defvar-local *v-b9i* 0 "test var")
    (let ((events '()))
      (let ((pkg (find-package '#:limn/local)))
        (when pkg
          (let ((fn-sym (find-symbol "*BUFFER-LOCAL-CHANGED-FN*" pkg)))
            (when fn-sym
              (progv (list fn-sym)
                  (list (lambda (p) (push p events)))
                (with-current-buf "b9i"
                  (assert-no-error
                   (limn/local:kill-local-variable '*v-b9i*)
                   "kill on never-set: no error"))
                (assert-eql 0 (length events)
                            "no event fired")))))))))

(deftest local-b9-100-buffers-reset-isolation
  "100 個 buffer 各有 local 值，reset 其中一個不影響其餘 99 個。"
  (let ((ids (loop for i from 0 below 100
                   collect (format nil "b9j-~3,'0d" i))))
    (when (find-package '#:limn/local)
      (dolist (id ids) (limn/local:reset-buffer-locals id)))
    (unwind-protect
         (progn
           (limn/local:defvar-local *v-b9j* -1 "scale test")
           (loop for id in ids
                 for i from 0
                 do (limn/local:set-buffer-local-value '*v-b9j* i id))
           ;; reset 第 50 個
           (limn/local:reset-buffer-locals (nth 50 ids))
           (assert-false (limn/local:local-variable-p '*v-b9j* (nth 50 ids))
                         "reset target cleared")
           (assert-true  (limn/local:local-variable-p '*v-b9j* (nth 49 ids))
                         "neighbour 49 untouched")
           (assert-true  (limn/local:local-variable-p '*v-b9j* (nth 51 ids))
                         "neighbour 51 untouched")
           (assert-eql 99 (limn/local:buffer-local-value '*v-b9j* (nth 99 ids))
                       "邊界 buffer 99 = 99"))
      (when (find-package '#:limn/local)
        (dolist (id ids) (limn/local:reset-buffer-locals id))))))
