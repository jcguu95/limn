;;;; limn-cape — Completion-at-point backends（minad Cape 的 Lisp 等價）
;;;;
;;;; Cape 是 completion-at-point 的後端 extension。每個 backend 提供：
;;;;   (cape-xxx-candidates prefix ...) → list of candidate strings
;;;;
;;;; 實作：
;;;;   cape-dabbrev-candidates(prefix buffer-text) → 從 buffer-text 找
;;;;     以 prefix 開頭的 word list（case-insensitive）
;;;;   cape-file-candidates(prefix) → 以 prefix 開頭的路徑 list
;;;;
;;;; 純後端、headless 可驗。不直接讀取檔案系統（由 caller 提供路徑或
;;;; 使用 mock）。

(defpackage #:limn/cape
  (:use #:cl)
  (:export #:cape-dabbrev-candidates
           #:cape-file-candidates))

(in-package #:limn/cape)

;;; ─── 工具函式 ───────────────────────────────────────────────────────

(defun %extract-words (text)
  "從 TEXT 字串中擷取所有「word」。
   Word 定義：連續的字母數字字元或底線/連字號。
   回傳 word 字串 list（保留原始大小寫）。"
  (let ((words '())
        (len (length text))
        (start nil))
    (loop for i from 0 below len
          for ch = (char text i)
          do (if (or (alphanumericp ch)
                     (char= ch #\_)
                     (char= ch #\-))
                 (unless start (setf start i))
                 (when start
                   (push (subseq text start i) words)
                   (setf start nil))))
    (when start
      (push (subseq text start len) words))
    (nreverse words)))

(defun %deduplicate (list &key (test #'string=))
  "移除 LIST 中重複項目（保留第一次出現）。"
  (let ((seen '())
        (result '()))
    (dolist (item list)
      (unless (member item seen :test test)
        (push item seen)
        (push item result)))
    (nreverse result)))

;;; ─── dabbrev（dynamic abbreviation）──────────────────────────────────

(defun cape-dabbrev-candidates (prefix buffer-text)
  "從 BUFFER-TEXT 中找出所有以 PREFIX 開頭的 word。
   Case-insensitive 比對；回傳 deduplicated、依原始大小寫的 list。
   範例：
     (cape-dabbrev-candidates \"foo\" \"foobar foobaz qux\")
     → (\"foobar\" \"foobaz\")"
  (let* ((words (%extract-words buffer-text))
         (ci-prefix (string-downcase prefix))
         (matched
           (remove-if-not
            (lambda (w)
              (and (>= (length w) (length ci-prefix))
                   (string= ci-prefix (string-downcase w)
                            :end2 (length ci-prefix))))
            words)))
    (%deduplicate matched)))

;;; ─── file ────────────────────────────────────────────────────────────

(defun cape-file-candidates (prefix &optional (directory-list nil))
  "回傳以 PREFIX 開頭的檔案路徑 list。
   若提供了 DIRECTORY-LIST（路徑字串 list），以此為候選池；
   若無，嘗試使用 cl:directory 擷取目前目錄（或回傳 nil）。
   在 headless unit-test 中，建議傳入 DIRECTORY-LIST 做 mock。"
  (if directory-list
      (let ((ci-prefix (string-downcase prefix)))
        (remove-if-not
         (lambda (p)
           (let ((name (enough-namestring p)))
             (and (>= (length name) (length ci-prefix))
                  (string= ci-prefix (string-downcase name)
                           :end2 (length ci-prefix)))))
         directory-list))
      ;; 嘗試真實 fs（可能無效於 headless）
      (handler-case
          (let* ((dir (if (or (null prefix) (zerop (length prefix)))
                        "./"
                        (concatenate 'string prefix "*")))
                 (files (directory dir)))
            (mapcar #'namestring files))
        (error () nil))))
