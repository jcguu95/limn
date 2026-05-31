;;;; consult.lisp — Consult 搜尋/導航指令的 unit tests
;;;;
;;;; 測試覆蓋：
;;;;   §1 — consult-buffer-candidates mock list → 斷言候選名稱
;;;;   §2 — consult-line-candidates 內容 → 行號格式候選
;;;;   §3 — consult-find-file-candidates mock directory list
;;;;   §4 — run-consult + mock action → action 被呼叫且 candidate 正確
;;;;   §5 — run-consult + move → 能選到非第一個候選
;;;;   §6 — 邊界情況（空候選集、空內容、move 超出範圍）
;;;;
;;;; limn-consult 透過 ASDF 載入（limn.asd），此處直接使用。

(in-package #:limn/unit-test)

;;; ─── §1 consult-buffer-candidates ────────────────────────────────────

(deftest consult-s1-buffer-candidates-mock
  "consult-buffer-candidates 使用 mock *consult-buffer-list-fn* 回傳名稱 list。"
  (let ((limn/consult:*consult-buffer-list-fn*
          (lambda ()
            '("*scratch*" "notes.org" "main.lisp" "README.md"))))
    (let ((candidates (limn/consult:consult-buffer-candidates)))
      (assert-equal 4 (length candidates) "4 個 buffer 候選")
      (assert-contains "*scratch*" candidates)
      (assert-contains "notes.org" candidates)
      (assert-contains "main.lisp" candidates)
      (assert-contains "README.md" candidates))))

(deftest consult-s1-buffer-candidates-empty-mock
  "consult-buffer-candidates mock 空 list → 回傳 nil。"
  (let ((limn/consult:*consult-buffer-list-fn*
          (lambda () '())))
    (let ((candidates (limn/consult:consult-buffer-candidates)))
      (assert-true (listp candidates) "回傳 list")
      (assert-equal 0 (length candidates) "空 list → 0 個候選"))))

(deftest consult-s1-buffer-candidates-without-mock
  "consult-buffer-candidates 無 mock → 回傳空 list（不 crash）。"
  (let ((limn/consult:*consult-buffer-list-fn* nil))
    (let ((candidates (limn/consult:consult-buffer-candidates)))
      (assert-true (listp candidates) "回傳 list"))))

;;; ─── §2 consult-line-candidates ──────────────────────────────────────

(deftest consult-s2-line-candidates-basic
  "consult-line-candidates 'foo\\nbar\\nbaz' → 3 個含行號的候選。"
  (let ((lines (limn/consult:consult-line-candidates "foo
bar
baz")))
    (assert-equal 3 (length lines) "3 行 → 3 候選")
    (assert-equal "1:foo" (first lines))
    (assert-equal "2:bar" (second lines))
    (assert-equal "3:baz" (third lines))))

(deftest consult-s2-line-candidates-single-line
  "consult-line-candidates 單行無換行 → 1 個候選。"
  (let ((lines (limn/consult:consult-line-candidates "hello world")))
    (assert-equal 1 (length lines))
    (assert-equal "1:hello world" (first lines))))

(deftest consult-s2-line-candidates-empty
  "consult-line-candidates 空字串 → '1:'。"
  (let ((lines (limn/consult:consult-line-candidates "")))
    (assert-equal 1 (length lines))
    (assert-equal "1:" (first lines))))

(deftest consult-s2-line-candidates-trailing-newline
  "consult-line-candidates 結尾換行 → 最後一行為空。"
  (let ((lines (limn/consult:consult-line-candidates "alpha
beta
")))
    (assert-equal 3 (length lines) "含尾隨換行 → 3 行")
    (assert-equal "1:alpha" (first lines))
    (assert-equal "2:beta" (second lines))
    (assert-equal "3:" (third lines) "尾隨換行產生空行")))

(deftest consult-s2-line-candidates-line-numbers-sequential
  "consult-line-candidates 行號為 1-based 遞增。"
  (let ((lines (limn/consult:consult-line-candidates "a
b
c
d
e")))
    (assert-equal 5 (length lines))
    (assert-equal "1:a" (elt lines 0))
    (assert-equal "2:b" (elt lines 1))
    (assert-equal "3:c" (elt lines 2))
    (assert-equal "4:d" (elt lines 3))
    (assert-equal "5:e" (elt lines 4))))

;;; ─── §3 consult-find-file-candidates ─────────────────────────────────

(deftest consult-s3-find-file-candidates-mock
  "consult-find-file-candidates 使用 mock *consult-directory-files-fn*。"
  (let ((limn/consult:*consult-directory-files-fn*
          (lambda (dir)
            (declare (ignore dir))
            '("foo.txt" "bar.org" "foobar.lisp" "README.md"))))
    (let ((files (limn/consult:consult-find-file-candidates "/test")))
      (assert-equal 4 (length files) "4 個檔案")
      (assert-contains "foo.txt" files)
      (assert-contains "bar.org" files)
      (assert-contains "foobar.lisp" files)
      (assert-contains "README.md" files))))

(deftest consult-s3-find-file-candidates-empty-mock
  "consult-find-file-candidates mock 空目錄 → 空 list。"
  (let ((limn/consult:*consult-directory-files-fn*
          (lambda (dir)
            (declare (ignore dir))
            '())))
    (let ((files (limn/consult:consult-find-file-candidates "/empty")))
      (assert-equal 0 (length files)))))

;;; ─── §4 run-consult + mock action ─────────────────────────────────────

(deftest consult-s4-run-consult-action-called
  "run-consult [\"a\",\"b\",\"c\"] + mock action → action 被呼叫且 candidate 正確。"
  (let ((captured nil))
    (let ((result (limn/consult:run-consult
                   '("alpha" "beta" "gamma")
                   (lambda (candidate)
                     (setf captured candidate)
                     :done))))
      (assert-eq :done result "action-fn 回傳值正確")
      (assert-equal "alpha" captured "預設選第一個候選"))))

(deftest consult-s4-run-consult-action-returns-value
  "run-consult 回傳 action-fn 的結果。"
  (let ((result (limn/consult:run-consult
                 '("x")
                 (lambda (c) (declare (ignore c)) 42))))
    (assert-equal 42 result "回傳 action-fn 的結果 42")))

(deftest consult-s4-run-consult-action-called-once
  "run-consult 只呼叫 action-fn 一次。"
  (let ((count 0))
    (limn/consult:run-consult
     '("one" "two" "three")
     (lambda (c)
       (declare (ignore c))
       (incf count)))
    (assert-equal 1 count "action-fn 被呼叫恰好一次")))

;;; ─── §5 run-consult + move ────────────────────────────────────────────

(deftest consult-s5-run-consult-move-second
  "run-consult + :move 1 → 選到第二個候選。"
  (let ((captured nil))
    (limn/consult:run-consult
     '("first" "second" "third")
     (lambda (c) (setf captured c))
     :move 1)
    (assert-equal "second" captured ":move 1 選到 second")))

(deftest consult-s5-run-consult-move-third
  "run-consult + :move 2 → 選到第三個候選。"
  (let ((captured nil))
    (limn/consult:run-consult
     '("first" "second" "third")
     (lambda (c) (setf captured c))
     :move 2)
    (assert-equal "third" captured ":move 2 選到 third")))

(deftest consult-s5-run-consult-move-zero
  "run-consult + :move 0 → 選第一個（預設）。"
  (let ((captured nil))
    (limn/consult:run-consult
     '("x" "y" "z")
     (lambda (c) (setf captured c))
     :move 0)
    (assert-equal "x" captured ":move 0 選第一個")))

(deftest consult-s5-run-consult-move-clamped
  "run-consult + :move 過大 → clamp 到最後一個。"
  (let ((captured nil))
    (limn/consult:run-consult
     '("a" "b" "c")
     (lambda (c) (setf captured c))
     :move 999)
    (assert-equal "c" captured "move 999 clamp → 選最後一個")))

;;; ─── §6 邊界情況 ────────────────────────────────────────────────────

(deftest consult-s6-empty-candidates-error
  "run-consult 空候選集 → error。"
  (assert-error error
    (limn/consult:run-consult
     '()
     (lambda (c) (declare (ignore c)) nil))
    "空候選集應 sign error"))

(deftest consult-s6-single-candidate
  "run-consult 單候選 → 正確選取。"
  (let ((captured nil))
    (limn/consult:run-consult
     '("only")
     (lambda (c) (setf captured c)))
    (assert-equal "only" captured "單候選正確選取")))
