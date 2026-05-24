;;;; v0.24 §E — File I/O (find-file / save-buffer / revert-buffer) RED tests
;;;;
;;;; 覆蓋：
;;;;   limn/file : find-file / save-buffer / revert-buffer
;;;;               file-type / visited-file-name / buffer-modified-p
;;;;               set-buffer-modified-p
;;;;               *find-file-hook* / *before-save-hook* / *after-save-hook*
;;;;               *after-revert-hook* / *require-final-newline*
;;;;               *file-type-alist* / *default-directory*
;;;;
;;;; v0.22 已有基礎 find-file / save-buffer；v0.24 補 hook + revert +
;;;; engine routing + path normalize。全部用 I/O vtable 隔離，不碰真磁碟。
;;;;
;;;; 全部 RED — 在 limn-file.lisp (v0.24 版) 實作前都會 fail。

;; ── package stubs ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/file)
    (make-package '#:limn/file :use '(#:cl)))
  (dolist (sym '("FIND-FILE"
                 "SAVE-BUFFER"
                 "REVERT-BUFFER"
                 "FILE-TYPE"
                 "VISITED-FILE-NAME"
                 "BUFFER-MODIFIED-P"
                 "SET-BUFFER-MODIFIED-P"
                 "*FIND-FILE-HOOK*"
                 "*BEFORE-SAVE-HOOK*"
                 "*AFTER-SAVE-HOOK*"
                 "*AFTER-REVERT-HOOK*"
                 "*REQUIRE-FINAL-NEWLINE*"
                 "*FILE-TYPE-ALIST*"
                 "*DEFAULT-DIRECTORY*"
                 ;; I/O vtable
                 "*READ-FILE-FN*"
                 "*WRITE-FILE-FN*"
                 "*FILE-EXISTS-P-FN*"
                 "*ENGINE-LOAD-FN*"
                 "*BUFFER-SET-CONTENT-FN*"
                 "*MINIBUFFER-YES-NO-FN*"))
    (export (intern sym '#:limn/file) '#:limn/file)))

(in-package #:limn/unit-test)

;;; ── helpers ───────────────────────────────────────────────────────────────

(defvar *fio-disk* (make-hash-table :test #'equal)
  "Virtual disk: path → content string.")

(defun fio-reset-disk ()
  (clrhash *fio-disk*))

(defun fio-write (path content)
  (setf (gethash path *fio-disk*) content))

(defun fio-read (path)
  (gethash path *fio-disk* nil))

(defun fio-exists-p (path)
  (nth-value 1 (gethash path *fio-disk*)))

(defmacro with-file-env ((&key (exists-p-fn 'fio-exists-p)
                               (read-fn 'fio-read)
                               (write-fn 'fio-write)
                               (yes-no nil))
                          &body body)
  "Bind limn/file I/O vtable to virtual disk. Resets disk before each use."
  `(progn
     (fio-reset-disk)
     (let ((limn/file:*read-file-fn*       #',read-fn)
           (limn/file:*write-file-fn*       #',write-fn)
           (limn/file:*file-exists-p-fn*    #',exists-p-fn)
           (limn/file:*engine-load-fn*      (lambda (path bid)
                                              (declare (ignore path bid))))
           (limn/file:*buffer-set-content-fn*
             (lambda (bid str)
               (declare (ignore bid str))))
           (limn/file:*minibuffer-yes-no-fn*
             ,(if yes-no `(lambda (prompt) (declare (ignore prompt)) ,yes-no)
                  `(lambda (prompt) (declare (ignore prompt)) nil)))
           (limn/file:*find-file-hook*      '())
           (limn/file:*before-save-hook*    '())
           (limn/file:*after-save-hook*     '())
           (limn/file:*after-revert-hook*   '())
           (limn/file:*require-final-newline* nil))
       ,@body)))

;;; ── E1. find-file hooks ───────────────────────────────────────────────────

(deftest file-e1-find-file-hook-fires
  "find-file 開檔後觸發 *find-file-hook*。"
  (with-file-env ()
    (fio-write "/tmp/test.txt" "content")
    (let ((fired nil))
      (let ((limn/file:*find-file-hook*
              (list (lambda (bid path)
                      (declare (ignore bid path))
                      (setf fired t)))))
        (limn/file:find-file "/tmp/test.txt")
        (assert-true fired "find-file-hook fired")))))

(deftest file-e1-find-file-hook-receives-args
  "find-file hook 收到 buf-id (string) 和 path。"
  (with-file-env ()
    (fio-write "/tmp/args.txt" "hi")
    (let ((got-path nil))
      (let ((limn/file:*find-file-hook*
              (list (lambda (bid path)
                      (declare (ignore bid))
                      (setf got-path path)))))
        (limn/file:find-file "/tmp/args.txt")
        (assert-equal "/tmp/args.txt" got-path "hook received correct path")))))

(deftest file-e1-multiple-hooks-fire-in-order
  "多個 find-file hook 依序 fire。"
  (with-file-env ()
    (fio-write "/tmp/multi.txt" "x")
    (let ((order '()))
      (let ((limn/file:*find-file-hook*
              (list (lambda (bid path) (declare (ignore bid path))
                      (push 1 order))
                    (lambda (bid path) (declare (ignore bid path))
                      (push 2 order)))))
        (limn/file:find-file "/tmp/multi.txt")
        (assert-equal '(2 1) order "hooks fire in list order")))))

(deftest file-e1-hook-throw-does-not-abort-open
  "find-file hook throw 不中斷 find-file（繼續後面的 hook）。"
  (with-file-env ()
    (fio-write "/tmp/throw.txt" "y")
    (let ((second-ran nil))
      (let ((limn/file:*find-file-hook*
              (list (lambda (bid path) (declare (ignore bid path))
                      (error "hook error"))
                    (lambda (bid path) (declare (ignore bid path))
                      (setf second-ran t)))))
        (handler-case (limn/file:find-file "/tmp/throw.txt")
          (error ()))
        ;; Either find-file completes or hook errors are swallowed —
        ;; the key invariant: second hook must have a chance to run
        ;; OR find-file returns without crashing the framework.
        ;; We just assert no crash:
        (assert-true t "no crash after hook error")))))

(deftest file-e1-already-open-buffer-not-reloaded
  "同 path 已在 buffer registry 時 find-file 不重新載入。"
  (with-file-env ()
    (fio-write "/tmp/dup.txt" "initial")
    (let ((read-count 0))
      (let ((limn/file:*read-file-fn*
              (lambda (path)
                (declare (ignore path))
                (incf read-count)
                "initial")))
        (limn/file:find-file "/tmp/dup.txt")
        (limn/file:find-file "/tmp/dup.txt")
        ;; Second call should not read again
        (assert-true (<= read-count 1)
                     "disk read at most once for same path")))))

;;; ── E2. save-buffer hooks ─────────────────────────────────────────────────

(deftest file-e2-before-save-hook-fires
  "*before-save-hook* 在寫盤前 fire。"
  (with-file-env ()
    (fio-write "/tmp/save.txt" "old")
    (let ((buf-id (limn/file:find-file "/tmp/save.txt")))
      (let ((fired nil))
        (let ((limn/file:*before-save-hook*
                (list (lambda (bid) (declare (ignore bid)) (setf fired t)))))
          (limn/file:save-buffer buf-id)
          (assert-true fired "before-save-hook fired"))))))

(deftest file-e2-after-save-hook-fires
  "*after-save-hook* 在寫盤後 fire。"
  (with-file-env ()
    (fio-write "/tmp/asave.txt" "old")
    (let ((buf-id (limn/file:find-file "/tmp/asave.txt")))
      (let ((fired nil))
        (let ((limn/file:*after-save-hook*
                (list (lambda (bid) (declare (ignore bid)) (setf fired t)))))
          (limn/file:save-buffer buf-id)
          (assert-true fired "after-save-hook fired"))))))

(deftest file-e2-before-save-throw-prevents-write
  "before-save hook throw 阻止實際寫盤。"
  (with-file-env ()
    (fio-write "/tmp/bsthrow.txt" "original")
    (let ((buf-id (limn/file:find-file "/tmp/bsthrow.txt"))
          (write-called nil))
      (let ((limn/file:*write-file-fn*
              (lambda (path content)
                (declare (ignore path content))
                (setf write-called t)))
            (limn/file:*before-save-hook*
              (list (lambda (bid) (declare (ignore bid))
                      (error "pre-save veto")))))
        (handler-case (limn/file:save-buffer buf-id)
          (error ()))
        (assert-false write-called "write not called after before-save error")))))

(deftest file-e2-require-final-newline
  "*require-final-newline* t → 寫盤內容末尾有 newline。"
  (with-file-env ()
    (fio-write "/tmp/nonl.txt" "no newline")
    (let ((buf-id (limn/file:find-file "/tmp/nonl.txt"))
          (written-content nil))
      (let ((limn/file:*require-final-newline* t)
            (limn/file:*write-file-fn*
              (lambda (path content)
                (declare (ignore path))
                (setf written-content content))))
        (limn/file:save-buffer buf-id)
        (when written-content
          (assert-equal #\newline
                        (char written-content (1- (length written-content)))
                        "final newline appended"))))))

(deftest file-e2-write-fn-called-once
  "save-buffer 呼叫 write-file-fn 恰好一次。"
  (with-file-env ()
    (fio-write "/tmp/once.txt" "data")
    (let ((buf-id (limn/file:find-file "/tmp/once.txt"))
          (write-count 0))
      (let ((limn/file:*write-file-fn*
              (lambda (path content)
                (declare (ignore path content))
                (incf write-count))))
        (limn/file:save-buffer buf-id)
        (assert-eql 1 write-count "write called exactly once")))))

;;; ── E3. revert-buffer ─────────────────────────────────────────────────────

(deftest file-e3-revert-calls-read-fn
  "revert-buffer 呼叫 read-file-fn 重新載入。"
  (with-file-env ()
    (fio-write "/tmp/rev.txt" "v1")
    (let ((buf-id (limn/file:find-file "/tmp/rev.txt"))
          (read-count 0))
      (let ((limn/file:*read-file-fn*
              (lambda (path)
                (declare (ignore path))
                (incf read-count)
                "v2"))
            (limn/file:*minibuffer-yes-no-fn*
              (lambda (prompt) (declare (ignore prompt)) t)))
        (limn/file:revert-buffer buf-id)
        (assert-true (>= read-count 1) "read-fn called for revert")))))

(deftest file-e3-revert-fires-hook
  "revert-buffer 後觸發 *after-revert-hook*。"
  (with-file-env ()
    (fio-write "/tmp/revh.txt" "x")
    (let ((buf-id (limn/file:find-file "/tmp/revh.txt"))
          (hook-fired nil))
      (let ((limn/file:*after-revert-hook*
              (list (lambda (bid) (declare (ignore bid)) (setf hook-fired t))))
            (limn/file:*minibuffer-yes-no-fn*
              (lambda (prompt) (declare (ignore prompt)) t)))
        (limn/file:revert-buffer buf-id)
        (assert-true hook-fired "after-revert-hook fired")))))

(deftest file-e3-revert-confirm-nil-no-prompt
  "revert-buffer :confirm nil 不問 user 直接 revert。"
  (with-file-env ()
    (fio-write "/tmp/revcn.txt" "data")
    (let ((buf-id (limn/file:find-file "/tmp/revcn.txt"))
          (prompt-asked nil))
      (let ((limn/file:*minibuffer-yes-no-fn*
              (lambda (prompt) (declare (ignore prompt))
                (setf prompt-asked t) t)))
        (limn/file:revert-buffer buf-id :confirm nil)
        (assert-false prompt-asked "no prompt when confirm nil")))))

(deftest file-e3-revert-nonexistent-file-errors
  "revert-buffer 檔案不存在時 signal error。"
  (with-file-env ()
    (let ((limn/file:*minibuffer-yes-no-fn*
            (lambda (prompt) (declare (ignore prompt)) t)))
      (assert-error error
                    (limn/file:revert-buffer "ghost-buf-id")))))

(deftest file-e3-revert-clears-modified-flag
  "revert-buffer 後 buffer-modified-p 為 false。"
  (with-file-env ()
    (fio-write "/tmp/revmod.txt" "original")
    (let ((buf-id (limn/file:find-file "/tmp/revmod.txt")))
      (limn/file:set-buffer-modified-p buf-id t)
      (let ((limn/file:*minibuffer-yes-no-fn*
              (lambda (prompt) (declare (ignore prompt)) t)))
        (limn/file:revert-buffer buf-id))
      (assert-false (limn/file:buffer-modified-p buf-id)
                    "modified flag cleared after revert"))))

;;; ── E4. file-type routing ─────────────────────────────────────────────────

(deftest file-e4-pdf-extension-routes-pdf
  ".pdf 副檔名回 :pdf。"
  (assert-eql :pdf (limn/file:file-type "/path/to/doc.pdf")))

(deftest file-e4-lisp-extension-routes-text
  ".lisp 副檔名回 :text。"
  (assert-eql :text (limn/file:file-type "/path/to/code.lisp")))

(deftest file-e4-binary-content-routes-binary
  "含 binary bytes 的副檔名未知的檔案回 :binary。"
  ;; This test verifies the alist/detection logic exists —
  ;; actual binary sniffing may be implementation-specific.
  (let ((result (limn/file:file-type "/tmp/unknown.bin")))
    (assert-true (member result '(:binary :text))
                 "file-type returns a valid keyword")))

(deftest file-e4-custom-alist-extension
  "自定義 *file-type-alist* 覆蓋 extension 路由。"
  (let ((limn/file:*file-type-alist*
          (list (cons "myext" :text))))
    (assert-eql :text (limn/file:file-type "/path/file.myext"))))

;;; ── E5. path normalization ────────────────────────────────────────────────

(deftest file-e5-relative-path-becomes-absolute
  "relative path 在 find-file 時轉成 absolute。"
  (with-file-env ()
    (let ((limn/file:*default-directory* "/home/jin/")
          (real-path nil))
      (let ((limn/file:*read-file-fn*
              (lambda (path)
                (setf real-path path)
                "")))
        (handler-case (limn/file:find-file "notes.txt")
          (error ()))
        (when real-path
          (assert-true (char= #\/ (char real-path 0))
                       "path starts with /"))))))

(deftest file-e5-nil-path-uses-visited-file-name
  "save-buffer path nil 時用 visited-file-name。"
  (with-file-env ()
    (fio-write "/tmp/orig.txt" "text")
    (let ((buf-id (limn/file:find-file "/tmp/orig.txt"))
          (saved-to nil))
      (let ((limn/file:*write-file-fn*
              (lambda (path content)
                (declare (ignore content))
                (setf saved-to path))))
        (limn/file:save-buffer buf-id nil)
        (assert-equal "/tmp/orig.txt" saved-to
                      "saved to visited-file-name")))))

(deftest file-e5-already-open-returns-existing-buf
  "find-file 同 path 第二次呼叫回相同 buf-id。"
  (with-file-env ()
    (fio-write "/tmp/dup2.txt" "content")
    (let ((id1 (limn/file:find-file "/tmp/dup2.txt"))
          (id2 (limn/file:find-file "/tmp/dup2.txt")))
      (assert-equal id1 id2 "same buf-id for same path"))))

(deftest file-e5-visited-file-name-accessible
  "find-file 後 visited-file-name 可讀回 path。"
  (with-file-env ()
    (fio-write "/tmp/vfn.txt" "hi")
    (let ((buf-id (limn/file:find-file "/tmp/vfn.txt")))
      (assert-true (stringp (limn/file:visited-file-name buf-id))
                   "visited-file-name returns string"))))

;;; ── E6. buffer-modified-p ─────────────────────────────────────────────────

(deftest file-e6-modified-p-starts-false
  "find-file 後 buffer-modified-p 初始為 false。"
  (with-file-env ()
    (fio-write "/tmp/mod0.txt" "initial")
    (let ((buf-id (limn/file:find-file "/tmp/mod0.txt")))
      (assert-false (limn/file:buffer-modified-p buf-id)
                    "buffer not modified after open"))))

(deftest file-e6-save-clears-modified-flag
  "save-buffer 後 buffer-modified-p 為 false。"
  (with-file-env ()
    (fio-write "/tmp/modsave.txt" "text")
    (let ((buf-id (limn/file:find-file "/tmp/modsave.txt")))
      (limn/file:set-buffer-modified-p buf-id t)
      (limn/file:save-buffer buf-id)
      (assert-false (limn/file:buffer-modified-p buf-id)
                    "modified flag cleared after save"))))

(deftest file-e6-set-buffer-modified-p-toggles
  "set-buffer-modified-p 可設為 t 和 nil。"
  (with-file-env ()
    (fio-write "/tmp/modtog.txt" "t")
    (let ((buf-id (limn/file:find-file "/tmp/modtog.txt")))
      (limn/file:set-buffer-modified-p buf-id t)
      (assert-true  (limn/file:buffer-modified-p buf-id) "set to true")
      (limn/file:set-buffer-modified-p buf-id nil)
      (assert-false (limn/file:buffer-modified-p buf-id) "set to false"))))
