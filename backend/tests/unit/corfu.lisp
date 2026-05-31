;;;; corfu.lisp — Corfu in-buffer completion popup unit tests
;;;;
;;;; 測試覆蓋：
;;;;   §1 — make-corfu-session（建構 session）
;;;;   §2 — corfu-move（移動選取）
;;;;   §3 — corfu-commit（提交候選）
;;;;   §4 — corfu-update-prefix（更新前綴重新過濾）
;;;;   §5 — 邊界情況（空候選、空 prefix）
;;;;
;;;; limn-corfu 透過 ASDF 載入（limn.asd），此處直接使用。

(in-package #:limn/unit-test)

;;; ─── §1 make-corfu-session ──────────────────────────────────────────

(deftest corfu-s1-make-session-basic
  "make-corfu-session 建立含 2 個候選的 session。"
  (let ((state (limn/corfu:make-corfu-session '("foobar" "foobaz" "qux") "foo")))
    (assert-true (limn/corfu:corfu-state-p state) "state 為合法 corfu-state")
    (assert-equal 3 (limn/corfu:corfu-state-count state))
    (assert-equal 0 (limn/corfu:corfu-state-index state))
    (assert-equal "foo" (limn/corfu:corfu-state-prefix state))))

(deftest corfu-s1-make-session-empty-candidates
  "make-corfu-session 空候選：index 為 nil。"
  (let ((state (limn/corfu:make-corfu-session nil "foo")))
    (assert-true (limn/corfu:corfu-state-p state) "state 為合法")
    (assert-equal 0 (limn/corfu:corfu-state-count state))
    (assert-false (limn/corfu:corfu-state-index state) "index 應為 nil")))

;;; ─── §2 corfu-move ─────────────────────────────────────────────────

(deftest corfu-s2-move-down
  "corfu-move +1 移動到下一個候選。"
  (let* ((s0 (limn/corfu:make-corfu-session '("foobar" "foobaz" "qux") "foo"))
         (s1 (limn/corfu:corfu-move s0 1)))
    (assert-equal 1 (limn/corfu:corfu-state-index s1) "+1 → index 1")
    ;; 原始 state 不應被修改
    (assert-equal 0 (limn/corfu:corfu-state-index s0) "原始 state index 仍為 0")))

(deftest corfu-s2-move-up
  "corfu-move -1 移動到上一個候選（wrap around）。"
  (let* ((s0 (limn/corfu:make-corfu-session '("foobar" "foobaz" "qux") "foo"))
         (s1 (limn/corfu:corfu-move s0 -1)))
    (assert-equal 2 (limn/corfu:corfu-state-index s1) "-1 → index 2（wrap）")))

(deftest corfu-s2-move-wrap-forward
  "corfu-move 向前 overflow 會 wrap。"
  (let* ((s0 (limn/corfu:make-corfu-session '("a" "b") "x"))
         (s1 (limn/corfu:corfu-move s0 2)))
    (assert-equal 0 (limn/corfu:corfu-state-index s1) "+2 wrap → index 0")))

(deftest corfu-s2-move-empty-candidates
  "corfu-move 在空候選時不變。"
  (let ((s0 (limn/corfu:make-corfu-session nil "foo")))
    (let ((s1 (limn/corfu:corfu-move s0 1)))
      (assert-false (limn/corfu:corfu-state-index s1) "index 仍為 nil"))))

;;; ─── §3 corfu-commit ───────────────────────────────────────────────

(deftest corfu-s3-commit-selected
  "corfu-commit 回傳選中的候選字串。"
  (let* ((s0 (limn/corfu:make-corfu-session '("foobar" "foobaz" "qux") "foo"))
         (s1 (limn/corfu:corfu-move s0 1))
         (result (limn/corfu:corfu-commit s1)))
    (assert-equal "foobaz" result "+1 → commit → foobaz")))

(deftest corfu-s3-commit-first
  "corfu-commit 預設選取第一個候選。"
  (let* ((s0 (limn/corfu:make-corfu-session '("foobar" "foobaz") "foo"))
         (result (limn/corfu:corfu-commit s0)))
    (assert-equal "foobar" result "index 0 → foobar")))

(deftest corfu-s3-commit-empty-fallback
  "corfu-commit 在無候選時回傳 prefix。"
  (let* ((s0 (limn/corfu:make-corfu-session nil "foo"))
         (result (limn/corfu:corfu-commit s0)))
    (assert-equal "foo" result "無候選 → 回傳 prefix")))

;;; ─── §4 corfu-update-prefix ────────────────────────────────────────

(deftest corfu-s4-update-prefix-filters
  "corfu-update-prefix 過濾候選。"
  (let* ((s0 (limn/corfu:make-corfu-session '("foobar" "foobaz" "qux") "foo"))
         (s1 (limn/corfu:corfu-update-prefix s0 "foob"))
         (candidates (limn/corfu:corfu-state-candidates s1)))
    (assert-equal 2 (length candidates) "foob 過濾剩 2 個")
    (assert-contains "foobar" candidates)
    (assert-contains "foobaz" candidates)
    (assert-equal "foob" (limn/corfu:corfu-state-prefix s1))
    (assert-equal 0 (limn/corfu:corfu-state-index s1) "index 重設為 0")))

(deftest corfu-s4-update-prefix-no-match
  "corfu-update-prefix 無匹配時回傳空候選。"
  (let* ((s0 (limn/corfu:make-corfu-session '("foobar" "foobaz") "foo"))
         (s1 (limn/corfu:corfu-update-prefix s0 "zzz"))
         (candidates (limn/corfu:corfu-state-candidates s1)))
    (assert-equal 0 (length candidates) "zzz 無匹配")
    (assert-false (limn/corfu:corfu-state-index s1) "index 為 nil")))

(deftest corfu-s4-update-prefix-case-insensitive
  "corfu-update-prefix 大小寫無關。"
  (let* ((s0 (limn/corfu:make-corfu-session '("FooBar" "fooBaz" "qux") "foo"))
         (s1 (limn/corfu:corfu-update-prefix s0 "FOO"))
         (candidates (limn/corfu:corfu-state-candidates s1)))
    (assert-equal 2 (length candidates) "FOO 過濾（case-insensitive）")
    (assert-contains "FooBar" candidates)
    (assert-contains "fooBaz" candidates)))

(deftest corfu-s4-update-prefix-empty
  "corfu-update-prefix 空字串回傳全部候選。"
  (let* ((s0 (limn/corfu:make-corfu-session '("a" "b" "c") "x"))
         (s1 (limn/corfu:corfu-update-prefix s0 ""))
         (candidates (limn/corfu:corfu-state-candidates s1)))
    (assert-equal 3 (length candidates) "空 prefix → 全部候選")))

;;; ─── §5 邊界情況 ───────────────────────────────────────────────────

(deftest corfu-s5-single-candidate
  "單一候選的完整流程。"
  (let* ((s0 (limn/corfu:make-corfu-session '("only") "o"))
         (result (limn/corfu:corfu-commit s0)))
    (assert-equal "only" result)))

(deftest corfu-s5-move-then-update-resets-index
  "移動後更新 prefix 會重設 index。"
  (let* ((s0 (limn/corfu:make-corfu-session '("foobar" "foobaz" "food") "foo"))
         (s1 (limn/corfu:corfu-move s0 1))
         (s2 (limn/corfu:corfu-update-prefix s1 "fooba")))
    (assert-equal 0 (limn/corfu:corfu-state-index s2)
                 "更新 prefix 後 index 重設為 0")))
