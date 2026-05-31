;;;; cape.lisp — Cape completion backends unit tests
;;;;
;;;; 測試覆蓋：
;;;;   §1 — cape-dabbrev-candidates（基本、case-insensitive、空輸入）
;;;;   §2 — cape-file-candidates（mock directory list）
;;;;   §3 — 邊界情況
;;;;
;;;; limn-cape 透過 ASDF 載入（limn.asd），此處直接使用。

(in-package #:limn/unit-test)

;;; ─── §1 cape-dabbrev-candidates ─────────────────────────────────────

(deftest cape-s1-dabbrev-basic
  "cape-dabbrev-candidates 基本：找出以 prefix 開頭的 word。"
  (let ((result (limn/cape:cape-dabbrev-candidates
                 "foo" "foobar foobaz qux")))
    (assert-equal 2 (length result))
    (assert-contains "foobar" result)
    (assert-contains "foobaz" result)))

(deftest cape-s1-dabbrev-case-insensitive
  "cape-dabbrev-candidates 大小寫無關。"
  (let ((result (limn/cape:cape-dabbrev-candidates
                 "FOO" "foobar Foobaz qux")))
    (assert-equal 2 (length result) "FOO matches foobar and Foobaz")
    (assert-contains "foobar" result)
    (assert-contains "Foobaz" result)))

(deftest cape-s1-dabbrev-deduplicate
  "cape-dabbrev-candidates 去重複。"
  (let ((result (limn/cape:cape-dabbrev-candidates
                 "foo" "foobar foobar foobaz")))
    (assert-equal 2 (length result) "deduplicated")
    (assert-contains "foobar" result)
    (assert-contains "foobaz" result)))

(deftest cape-s1-dabbrev-no-match
  "cape-dabbrev-candidates 無匹配時回傳 nil。"
  (let ((result (limn/cape:cape-dabbrev-candidates
                 "zzz" "foobar foobaz qux")))
    (assert-false result "zzz 無匹配 → nil")))

(deftest cape-s1-dabbrev-empty-prefix
  "cape-dabbrev-candidates 空 prefix 回傳所有 word。"
  (let ((result (limn/cape:cape-dabbrev-candidates
                 "" "foo bar baz")))
    (assert-equal 3 (length result))
    (assert-contains "foo" result)
    (assert-contains "bar" result)
    (assert-contains "baz" result)))

(deftest cape-s1-dabbrev-partial-word-match
  "cape-dabbrev-candidates 只回傳以 prefix 開頭的 word。"
  (let ((result (limn/cape:cape-dabbrev-candidates
                 "ob" "foobar qux")))
    ;; "ob" 不是任何 word 的開頭（foobar 以 f 開頭）
    (assert-false result "ob 不匹配任何 word 開頭 → nil")))

(deftest cape-s1-dabbrev-hyphen-underscore
  "cape-dabbrev-candidates 辨識含連字號和底線的 word。"
  (let ((result (limn/cape:cape-dabbrev-candidates
                 "my" "my-var my_var other")))
    (assert-equal 2 (length result))
    (assert-contains "my-var" result)
    (assert-contains "my_var" result)))

;;; ─── §2 cape-file-candidates ────────────────────────────────────────

(deftest cape-s2-file-mock
  "cape-file-candidates 使用 mock directory list。"
  (let* ((mock-files (mapcar #'parse-namestring
                             '("/tmp/foo.txt" "/tmp/bar.org" "/tmp/foobar.lisp")))
         (result (limn/cape:cape-file-candidates "/tmp/foo" mock-files)))
    (assert-true result "mock 回傳非 nil")
    (assert-equal 2 (length result) "匹配 foo 開頭的兩個路徑")))

(deftest cape-s2-file-no-match
  "cape-file-candidates mock 無匹配時回傳 nil。"
  (let* ((mock-files (mapcar #'parse-namestring
                             '("/tmp/foo.txt" "/tmp/bar.org")))
         (result (limn/cape:cape-file-candidates "/tmp/zzz" mock-files)))
    (assert-false result "無匹配 → nil")))

(deftest cape-s2-file-case-insensitive
  "cape-file-candidates 大小寫無關。"
  (let* ((mock-files (mapcar #'parse-namestring
                             '("/tmp/Foo.txt" "/tmp/bar.org")))
         (result (limn/cape:cape-file-candidates "/tmp/foo" mock-files)))
    (assert-true result)
    (assert-equal 1 (length result))))

;;; ─── §3 邊界情況 ───────────────────────────────────────────────────

(deftest cape-s3-empty-buffer-text
  "cape-dabbrev-candidates 空 buffer-text 回傳 nil。"
  (let ((result (limn/cape:cape-dabbrev-candidates "foo" "")))
    (assert-false result "空 buffer-text → nil")))

(deftest cape-s3-special-chars
  "cape-dabbrev-candidates 忽略特殊字元。"
  (let ((result (limn/cape:cape-dabbrev-candidates
                 "foo" "foo! bar, foo: qux.")))
    ;; 標點符號不是 word 字元，所以 word 為 "foo" "bar" "foo" "qux"
    ;; dedup 後 "foo" "bar" "qux"
    (assert-equal 1 (length result))
    (assert-contains "foo" result)))
