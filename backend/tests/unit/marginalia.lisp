;;;; marginalia.lisp — Marginalia 候選旁註解的 unit tests
;;;;
;;;; 測試覆蓋：
;;;;   §1 — annotate :buffer → 回非空字串
;;;;   §2 — annotate :file → 回非空字串
;;;;   §3 — annotate :command → 回非空字串
;;;;   §4 — 邊界情況（未知 category、無 mock 不 crash、空白 content）
;;;;   §5 — 整合：consult-buffer-candidates → run-consult → marginalia-annotate
;;;;
;;;; limn-marginalia 透過 ASDF 載入（limn.asd），此處直接使用。

(in-package #:limn/unit-test)

;;; ─── §1 annotate :buffer ────────────────────────────────────────────

(deftest marginalia-s1-annotate-buffer-mock
  "annotate :buffer 使用 mock → 回傳 mode 名稱字串。"
  (let ((limn/marginalia:*marginalia-buffer-mode-fn*
          (lambda (name)
            (cond
              ((string= name "*scratch*") "lisp-interaction-mode")
              ((string= name "notes.org") "org-mode")
              (t "fundamental-mode")))))
    (let ((annotation (limn/marginalia:annotate "*scratch*" :buffer)))
      (assert-true annotation "annotation 非 nil")
      (assert-true (stringp annotation) "annotation 是字串")
      (assert-true (> (length annotation) 0) "annotation 非空字串")
      (assert-equal "lisp-interaction-mode" annotation))))

(deftest marginalia-s1-annotate-buffer-org-mode
  "annotate :buffer 'notes.org' → org-mode。"
  (let ((limn/marginalia:*marginalia-buffer-mode-fn*
          (lambda (name)
            (declare (ignore name))
            "org-mode")))
    (let ((annotation (limn/marginalia:annotate "notes.org" :buffer)))
      (assert-true annotation "annotation 非 nil")
      (assert-equal "org-mode" annotation))))

(deftest marginalia-s1-annotate-buffer-not-empty
  "annotate :buffer 回傳值為非空字串（驗證內容）。"
  (let ((limn/marginalia:*marginalia-buffer-mode-fn*
          (lambda (name)
            (declare (ignore name))
            "fundamental-mode")))
    (let ((annotation (limn/marginalia:annotate "any-buffer" :buffer)))
      (assert-true (stringp annotation) "必須是字串")
      (assert-true (> (length annotation) 0) "字串長度 > 0")
      (assert-false (string= "" annotation) "不可是空白字串"))))

;;; ─── §2 annotate :file ───────────────────────────────────────────────

(deftest marginalia-s2-annotate-file-mock
  "annotate :file 使用 mock → 回傳大小/時間字串。"
  (let ((limn/marginalia:*marginalia-file-attr-fn*
          (lambda (path)
            (declare (ignore path))
            (cons 12288 (encode-universal-time 0 0 0 1 6 2025 0)))))
    (let ((annotation (limn/marginalia:annotate "/tmp/test.txt" :file)))
      (assert-true annotation "annotation 非 nil")
      (assert-true (stringp annotation) "annotation 是字串")
      (assert-true (> (length annotation) 0) "annotation 非空字串")
      ;; 12288 bytes = 12K
      (assert-true (search "12K" annotation) "annotation 含 12K")
      ;; 2025-06-01
      (assert-true (search "2025-06-01" annotation) "annotation 含日期"))))

(deftest marginalia-s2-annotate-file-large
  "annotate :file 大檔案 → 顯示 M 單位。"
  (let ((limn/marginalia:*marginalia-file-attr-fn*
          (lambda (path)
            (declare (ignore path))
            (cons 2097152 (encode-universal-time 0 0 0 15 3 2025 0)))))
    (let ((annotation (limn/marginalia:annotate "/tmp/big.iso" :file)))
      (assert-true annotation "annotation 非 nil")
      (assert-true (search "2.0M" annotation) "2MB → 2.0M")
      (assert-true (search "2025-03-15" annotation) "annotation 含日期"))))

(deftest marginalia-s2-annotate-file-not-empty
  "annotate :file 回傳值為非空字串（驗證內容）。"
  (let ((limn/marginalia:*marginalia-file-attr-fn*
          (lambda (path)
            (declare (ignore path))
            (cons 42 (encode-universal-time 0 0 0 1 1 2025 0)))))
    (let ((annotation (limn/marginalia:annotate "/tmp/small.txt" :file)))
      (assert-true (stringp annotation) "必須是字串")
      (assert-true (> (length annotation) 0) "字串長度 > 0")
      (assert-false (string= "" annotation) "不可是空白字串")
      (assert-true (search "42B" annotation) "annotation 含 42B"))))

;;; ─── §3 annotate :command ────────────────────────────────────────────

(deftest marginalia-s3-annotate-command-mock
  "annotate :command 使用 mock → 回傳 docstring 前 60 字。"
  (let ((limn/marginalia:*marginalia-command-doc-fn*
          (lambda (name)
            (declare (ignore name))
            "Insert a newline and indent the new line according to the major mode.")))
    (let ((annotation (limn/marginalia:annotate "newline-and-indent" :command)))
      (assert-true annotation "annotation 非 nil")
      (assert-true (stringp annotation) "annotation 是字串")
      (assert-true (> (length annotation) 0) "annotation 非空字串")
      (assert-equal "Insert a newline and indent the new line according to the ma" annotation
                    "docstring 前 60 字"))))

(deftest marginalia-s3-annotate-command-short-doc
  "annotate :command 短 docstring → 原樣回傳。"
  (let ((limn/marginalia:*marginalia-command-doc-fn*
          (lambda (name)
            (declare (ignore name))
            "Kill the current buffer.")))
    (let ((annotation (limn/marginalia:annotate "kill-buffer" :command)))
      (assert-true annotation "annotation 非 nil")
      (assert-equal "Kill the current buffer." annotation
                    "短 docstring 不截斷"))))

(deftest marginalia-s3-annotate-command-long-doc
  "annotate :command 長 docstring → 截到 60 字。"
  (let ((limn/marginalia:*marginalia-command-doc-fn*
          (lambda (name)
            (declare (ignore name))
            "This is a very long docstring that goes on and on and on and on and on and on and on and should be truncated at sixty characters")))
    (let ((annotation (limn/marginalia:annotate "some-command" :command)))
      (assert-true annotation "annotation 非 nil")
      (assert-true (<= (length annotation) 60) "長度 ≤ 60")
      (assert-equal 60 (length annotation) "正好截在 60 字"))))

(deftest marginalia-s3-annotate-command-not-empty
  "annotate :command 回傳值為非空字串（驗證內容）。"
  (let ((limn/marginalia:*marginalia-command-doc-fn*
          (lambda (name)
            (declare (ignore name))
            "Find a file and open it.")))
    (let ((annotation (limn/marginalia:annotate "find-file" :command)))
      (assert-true (stringp annotation) "必須是字串")
      (assert-true (> (length annotation) 0) "字串長度 > 0")
      (assert-false (string= "" annotation) "不可是空白字串")
      (assert-true (search "Find a file" annotation) "annotation 含 docstring"))))

;;; ─── §4 邊界情況 ────────────────────────────────────────────────────

(deftest marginalia-s4-unknown-category
  "annotate 未知 category → nil。"
  (let ((annotation (limn/marginalia:annotate "something" :unknown)))
    (assert-false annotation "未知 category → nil")))

(deftest marginalia-s4-buffer-no-mock
  "annotate :buffer 無 mock → 不 crash（可能 nil 或 fallback）。"
  (let ((limn/marginalia:*marginalia-buffer-mode-fn* nil))
    ;; 不該 crash，無論回傳 nil 或字串都接受
    (assert-no-error
      (limn/marginalia:annotate "no-such-buffer" :buffer)
      "無 mock 時不 crash")))

(deftest marginalia-s4-file-no-mock
  "annotate :file 無 mock → 不 crash（可能 nil 或 fallback）。"
  (let ((limn/marginalia:*marginalia-file-attr-fn* nil))
    (assert-no-error
      (limn/marginalia:annotate "/nonexistent/path" :file)
      "無 mock 時不 crash")))

(deftest marginalia-s4-command-no-mock
  "annotate :command 無 mock → 不 crash（可能 nil 或 fallback）。"
  (let ((limn/marginalia:*marginalia-command-doc-fn* nil))
    (assert-no-error
      (limn/marginalia:annotate "no-such-command" :command)
      "無 mock 時不 crash")))

;;; ─── §5 整合測試：consult-buffer-candidates → run-consult → marginalia-annotate

(deftest marginalia-s5-integration-consult-marginalia
  "整合測試：consult-buffer-candidates → run-consult → marginalia-annotate。
   模擬完整流程：取得 buffer 候選、run-consult 選取、取得 annotation。"
  (let ((limn/consult:*consult-buffer-list-fn*
          (lambda ()
            '("*scratch*" "notes.org" "main.lisp")))
        (limn/marginalia:*marginalia-buffer-mode-fn*
          (lambda (name)
            (cond
              ((string= name "*scratch*") "lisp-interaction-mode")
              ((string= name "notes.org") "org-mode")
              (t "fundamental-mode"))))
        (selected-buffer nil)
        (annotation nil))
    ;; Step 1: 取得候選
    (let ((candidates (limn/consult:consult-buffer-candidates)))
      (assert-equal 3 (length candidates) "3 個 buffer 候選")
      (assert-contains "*scratch*" candidates)
      (assert-contains "notes.org" candidates)
      (assert-contains "main.lisp" candidates)
      
      ;; Step 2: run-consult 選第二個候選 (notes.org)
      (limn/consult:run-consult
       candidates
       (lambda (c)
         (setf selected-buffer c))
       :move 1)
      (assert-equal "notes.org" selected-buffer "run-consult 選到 notes.org")
      
      ;; Step 3: marginalia-annotate 為選中的 buffer 產生 annotation
      (setf annotation (limn/marginalia:annotate selected-buffer :buffer))
      (assert-true annotation "annotation 非 nil")
      (assert-true (stringp annotation) "annotation 是字串")
      (assert-true (> (length annotation) 0) "annotation 非空字串")
      (assert-equal "org-mode" annotation "notes.org 的 mode 是 org-mode"))))

(deftest marginalia-s5-integration-move-to-third
  "整合測試：選第三個候選並 annotate。"
  (let ((limn/consult:*consult-buffer-list-fn*
          (lambda ()
            '("*scratch*" "notes.org" "main.lisp")))
        (limn/marginalia:*marginalia-buffer-mode-fn*
          (lambda (name)
            (declare (ignore name))
            "fundamental-mode"))
        (selected-buffer nil))
    (limn/consult:run-consult
     (limn/consult:consult-buffer-candidates)
     (lambda (c) (setf selected-buffer c))
     :move 2)
    (assert-equal "main.lisp" selected-buffer "選到第三個候選 main.lisp")
    (let ((annotation (limn/marginalia:annotate selected-buffer :buffer)))
      (assert-true annotation "annotation 非 nil")
      (assert-equal "fundamental-mode" annotation))))
