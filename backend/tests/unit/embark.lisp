;;;; embark.lisp — Embark context-aware action dispatcher unit tests
;;;;
;;;; 測試覆蓋：
;;;;   §1 — embark-actions-for（查詢可用動作）
;;;;   §2 — embark-execute（執行動作）
;;;;   §3 — 整合測試（cape → corfu → commit）
;;;;
;;;; limn-embark 透過 ASDF 載入（limn.asd），此處直接使用。

(in-package #:limn/unit-test)

;;; ─── §1 embark-actions-for ──────────────────────────────────────────

(deftest embark-s1-actions-for-file
  "embark-actions-for :file 回傳 alist 含 :open-file。"
  (let ((actions (limn/embark:embark-actions-for "/tmp/foo" :file)))
    (assert-true actions "回傳非 nil")
    (assert-true (assoc :open-file actions) "alist 含 :open-file")
    (assert-true (assoc :copy-path actions) "alist 含 :copy-path")))

(deftest embark-s1-actions-for-buffer
  "embark-actions-for :buffer 回傳 alist 含 :switch-to-buffer。"
  (let ((actions (limn/embark:embark-actions-for "scratch" :buffer)))
    (assert-true actions "回傳非 nil")
    (assert-true (assoc :switch-to-buffer actions) "alist 含 :switch-to-buffer")
    (assert-true (assoc :kill-buffer actions) "alist 含 :kill-buffer")))

(deftest embark-s1-actions-for-unknown-category
  "embark-actions-for 未知 category 回傳 nil。"
  (let ((actions (limn/embark:embark-actions-for "something" :unknown)))
    (assert-false actions "未知 category → nil")))

(deftest embark-s1-action-names
  "embark-action-names 回傳動作名稱 list。"
  (let ((names (limn/embark:embark-action-names :file)))
    (assert-contains :open-file names)
    (assert-contains :copy-path names)))

;;; ─── §2 embark-execute ─────────────────────────────────────────────

(deftest embark-s2-execute-open-file
  "embark-execute :open-file 回傳 :ok。"
  (let ((result (limn/embark:embark-execute :open-file "/tmp/foo" :file)))
    (assert-eq :ok result ":open-file → :ok")))

(deftest embark-s2-execute-copy-path
  "embark-execute :copy-path 回傳 :ok。"
  (let ((result (limn/embark:embark-execute :copy-path "/tmp/foo" :file)))
    (assert-eq :ok result ":copy-path → :ok")))

(deftest embark-s2-execute-switch-to-buffer
  "embark-execute :switch-to-buffer 回傳 :ok。"
  (let ((result (limn/embark:embark-execute :switch-to-buffer "scratch" :buffer)))
    (assert-eq :ok result ":switch-to-buffer → :ok")))

(deftest embark-s2-execute-kill-buffer
  "embark-execute :kill-buffer 回傳 :ok。"
  (let ((result (limn/embark:embark-execute :kill-buffer "scratch" :buffer)))
    (assert-eq :ok result ":kill-buffer → :ok")))

(deftest embark-s2-execute-not-found
  "embark-execute 未知 action 回傳 :not-found。"
  (let ((result (limn/embark:embark-execute :bogus-action "/tmp/foo" :file)))
    (assert-eq :not-found result "未知 action → :not-found")))

(deftest embark-s2-execute-without-category
  "embark-execute 不指定 category 也能找到 action。"
  (let ((result (limn/embark:embark-execute :open-file "/tmp/foo")))
    (assert-eq :ok result "無 category 也能找到 :open-file")))

;;; ─── §3 整合：cape → corfu → commit ────────────────────────────────

(deftest embark-s3-integration-cape-corfu-commit
  "整合測試：cape-dabbrev 提供 candidates → make-corfu-session → commit。"
  (let* ((buffer-text "foobar alpha foobaz beta qux gamma")
         (candidates (limn/cape:cape-dabbrev-candidates "foo" buffer-text))
         (state (limn/corfu:make-corfu-session candidates "foo"))
         (result (limn/corfu:corfu-commit state)))
    (assert-true (limn/corfu:corfu-state-p state) "合法 corfu state")
    (assert-equal 2 (length (limn/corfu:corfu-state-candidates state))
                 "來自 dabbrev 的兩個候選")
    (assert-equal "foobar" result "預設選取第一個候選 foobar")))

(deftest embark-s3-integration-move-then-commit
  "整合測試：dabbrev → corfu move +1 → commit。"
  (let* ((buffer-text "foobar alpha foobaz beta")
         (candidates (limn/cape:cape-dabbrev-candidates "foo" buffer-text))
         (state (limn/corfu:make-corfu-session candidates "foo"))
         (moved (limn/corfu:corfu-move state 1))
         (result (limn/corfu:corfu-commit moved)))
    (assert-equal "foobaz" result "移動後選取第二個候選")))

(deftest embark-s3-integration-update-prefix
  "整合測試：dabbrev → corfu → update-prefix → commit。"
  (let* ((buffer-text "foobar alpha foobaz beta food gamma")
         (candidates (limn/cape:cape-dabbrev-candidates "foo" buffer-text))
         (state (limn/corfu:make-corfu-session candidates "foo"))
         (filtered (limn/corfu:corfu-update-prefix state "fooba"))
         (filtered-cands (limn/corfu:corfu-state-candidates filtered)))
    (assert-equal 2 (length filtered-cands) "fooba 過濾剩 2 個")
    (assert-contains "foobar" filtered-cands)
    (assert-contains "foobaz" filtered-cands)))
