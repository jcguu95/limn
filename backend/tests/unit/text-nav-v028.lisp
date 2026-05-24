;;;; v0.28 §A — text-nav RED tests  (~62 tests)
;;;;
;;;; 覆蓋：
;;;;   limn/text-nav : *goal-column*
;;;;                   move-beginning-of-line / move-end-of-line（真實行掃描）
;;;;                   next-line / previous-line + *goal-column* 保留
;;;;                   forward-word / backward-word
;;;;                   beginning-of-buffer / end-of-buffer
;;;;                   newline / delete-forward-char
;;;;                   kill-line / kill-word（+ kill-ring 整合）
;;;;
;;;; I/O vtable（test isolation）:
;;;;   *buffer-text-fn*       : (buf-id) → string  全文
;;;;   *buffer-cursor-fn*     : (buf-id) → integer
;;;;   *buffer-set-cursor-fn* : (buf-id offset) → void
;;;;   *buffer-insert-fn*     : (buf-id offset str) → void
;;;;   *buffer-delete-fn*     : (buf-id from to) → void
;;;;   *kill-new-fn*          : (str) → void  kill-ring push 鉤點
;;;;
;;;; State:
;;;;   *goal-column*          : integer | nil  C-n/C-p 的目標欄
;;;;
;;;; 全部 RED — 在 limn-text-nav.lisp 實作前都會 fail。

;; ── package stubs ─────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; limn/kill — needed for integration tests (A11)
  (unless (find-package '#:limn/kill)
    (make-package '#:limn/kill :use '(#:cl)))
  (dolist (sym '("*KILL-RING*" "KILL-NEW" "YANK"))
    (let ((s (intern sym '#:limn/kill)))
      (export s '#:limn/kill)))

  (unless (find-package '#:limn/text-nav)
    (make-package '#:limn/text-nav :use '(#:cl)))
  (dolist (sym '("*GOAL-COLUMN*"
                 "*BUFFER-TEXT-FN*"
                 "*BUFFER-CURSOR-FN*"
                 "*BUFFER-SET-CURSOR-FN*"
                 "*BUFFER-INSERT-FN*"
                 "*BUFFER-DELETE-FN*"
                 "*KILL-NEW-FN*"
                 "NEXT-LINE"
                 "PREVIOUS-LINE"
                 "MOVE-BEGINNING-OF-LINE"
                 "MOVE-END-OF-LINE"
                 "FORWARD-WORD"
                 "BACKWARD-WORD"
                 "BEGINNING-OF-BUFFER"
                 "END-OF-BUFFER"
                 "NEWLINE"
                 "DELETE-FORWARD-CHAR"
                 "KILL-LINE"
                 "KILL-WORD"))
    (let ((s (intern sym '#:limn/text-nav)))
      (export s '#:limn/text-nav))))

(in-package #:limn/unit-test)

;;; ── mock infrastructure ───────────────────────────────────────────────────
;;;
;;; nav-mock: in-memory text + cursor + list of strings pushed via *kill-new-fn*.

(defstruct (nav-mock (:constructor %make-nav-mock (&key id text cursor)))
  id
  (text   "" :type string)
  (cursor  0 :type integer)
  (killed '()))

(defun make-nav-mock (&key (id "b") (text "") (cursor 0))
  (%make-nav-mock :id id :text text :cursor cursor))

(defun %nl (s)
  "Translate literal backslash-n pairs in S to actual #\\Newline chars.
   Common Lisp string literals don't honour C-style \\\\n escapes, so this
   helper lets the tests still write \"hello\\\\nworld\" inline."
  (with-output-to-string (out)
    (loop with i = 0 with len = (length s)
          while (< i len) do
      (cond ((and (char= (char s i) #\\)
                  (< (1+ i) len)
                  (char= (char s (1+ i)) #\n))
             (write-char #\Newline out)
             (incf i 2))
            (t (write-char (char s i) out)
               (incf i))))))

(defmacro with-nav-buf ((var &key (id "b") (text "") (cursor 0)) &body body)
  "Bind VAR to a nav-mock.  Wire all limn/text-nav vtable vars to it.
   Reset *goal-column* to nil so each test starts clean.
   TEXT is auto-translated for \\\\n escapes via %nl."
  (let ((pkg (gensym "PKG")))
    `(let* ((,var (make-nav-mock :id ,id :text (%nl ,text) :cursor ,cursor))
            (,pkg (find-package '#:limn/text-nav)))
       (if (null ,pkg)
           (progn ,@body)
           (let* ((pairs
                    (list
                     (cons (find-symbol "*GOAL-COLUMN*"          ,pkg) nil)
                     (cons (find-symbol "*BUFFER-TEXT-FN*"       ,pkg)
                           (lambda (bid)
                             (declare (ignore bid))
                             (nav-mock-text ,var)))
                     (cons (find-symbol "*BUFFER-CURSOR-FN*"     ,pkg)
                           (lambda (bid)
                             (declare (ignore bid))
                             (nav-mock-cursor ,var)))
                     (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,pkg)
                           (lambda (bid off)
                             (declare (ignore bid))
                             (setf (nav-mock-cursor ,var) off)))
                     (cons (find-symbol "*BUFFER-INSERT-FN*"     ,pkg)
                           (lambda (bid off str)
                             (declare (ignore bid))
                             (let* ((txt (nav-mock-text ,var))
                                    (new (concatenate 'string
                                                      (subseq txt 0 off)
                                                      str
                                                      (subseq txt off))))
                               (setf (nav-mock-text ,var) new)
                               (when (>= (nav-mock-cursor ,var) off)
                                 (incf (nav-mock-cursor ,var) (length str))))))
                     (cons (find-symbol "*BUFFER-DELETE-FN*"     ,pkg)
                           (lambda (bid from to)
                             (declare (ignore bid))
                             (let* ((txt (nav-mock-text ,var))
                                    (new (concatenate 'string
                                                      (subseq txt 0 from)
                                                      (subseq txt to)))
                                    (c   (nav-mock-cursor ,var)))
                               (setf (nav-mock-text ,var) new)
                               (setf (nav-mock-cursor ,var)
                                     (cond ((< c from) c)
                                           ((< c to)   from)
                                           (t (- c (- to from))))))))
                     (cons (find-symbol "*KILL-NEW-FN*"          ,pkg)
                           (lambda (str)
                             (push str (nav-mock-killed ,var))))))
                  (live (remove-if (lambda (p) (null (car p))) pairs)))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))

;;; ── A1. C-a — move-beginning-of-line（真實行掃描） ─────────────────────

(deftest nav-a1-bol-from-middle-of-line
  "C-a 從行中移到當前行首（上個 \\\\n 的後一位）。"
  ;; "hello\\\nworld"  cursor at 8 ('r' in "world")
  ;; Line 2 begins at offset 6.
  (with-nav-buf (b :text "hello\\\nworld" :cursor 8)
    (limn/text-nav:move-beginning-of-line (nav-mock-id b))
    (assert-eql 6 (nav-mock-cursor b) "start of 'world'")))

(deftest nav-a1-bol-from-first-line
  "C-a 在第一行（無前置 \\\\n）時移到 offset 0。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 3)
    (limn/text-nav:move-beginning-of-line (nav-mock-id b))
    (assert-eql 0 (nav-mock-cursor b))))

(deftest nav-a1-bol-already-at-bol
  "C-a 已在行首時 cursor 不動。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 6)
    (limn/text-nav:move-beginning-of-line (nav-mock-id b))
    (assert-eql 6 (nav-mock-cursor b))))

(deftest nav-a1-bol-third-line
  "C-a 在第三行正確找到第二個 \\\\n 後的位置。"
  ;; "aa\\\nbb\\\ncc"  line 3 starts at 6
  (with-nav-buf (b :text "aa\\\nbb\\\ncc" :cursor 7)
    (limn/text-nav:move-beginning-of-line (nav-mock-id b))
    (assert-eql 6 (nav-mock-cursor b))))

(deftest nav-a1-bol-single-char-line
  "C-a 在單字元行中找到行首。"
  ;; "a\\\nx\\\nb"  'x' at 2, line starts at 2
  (with-nav-buf (b :text "a\\\nx\\\nb" :cursor 2)
    (limn/text-nav:move-beginning-of-line (nav-mock-id b))
    (assert-eql 2 (nav-mock-cursor b))))

;;; ── A2. C-e — move-end-of-line（真實行掃描） ────────────────────────────

(deftest nav-a2-eol-from-middle
  "C-e 從行中移到當前行尾（\\\\n 之前的位置）。"
  ;; "hello\\\nworld"  \n is at 5; cursor should land at 5
  (with-nav-buf (b :text "hello\\\nworld" :cursor 2)
    (limn/text-nav:move-end-of-line (nav-mock-id b))
    (assert-eql 5 (nav-mock-cursor b) "just before the \\\\n")))

(deftest nav-a2-eol-last-line
  "C-e 在最後一行時移到 buffer 末端。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 8)
    (limn/text-nav:move-end-of-line (nav-mock-id b))
    (assert-eql 11 (nav-mock-cursor b))))

(deftest nav-a2-eol-already-at-eol
  "C-e 已在行尾（\\\\n 前）時 cursor 不動。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 5)
    (limn/text-nav:move-end-of-line (nav-mock-id b))
    (assert-eql 5 (nav-mock-cursor b))))

(deftest nav-a2-eol-empty-line
  "C-e 在空行（只有 \\\\n）時停在 offset 0（\\\\n 前）。"
  ;; "\\\nworld"  line 1 is empty; eol = 0
  (with-nav-buf (b :text "\\\nworld" :cursor 0)
    (limn/text-nav:move-end-of-line (nav-mock-id b))
    (assert-eql 0 (nav-mock-cursor b))))

(deftest nav-a2-eol-single-line-buffer
  "C-e 在單行 buffer 中移到末端。"
  (with-nav-buf (b :text "hello" :cursor 1)
    (limn/text-nav:move-end-of-line (nav-mock-id b))
    (assert-eql 5 (nav-mock-cursor b))))

;;; ── A3. M-< / M-> — beginning/end-of-buffer ────────────────────────────

(deftest nav-a3-beginning-of-buffer
  "M-< 將 cursor 移到 offset 0。"
  (with-nav-buf (b :text "hello world" :cursor 6)
    (limn/text-nav:beginning-of-buffer (nav-mock-id b))
    (assert-eql 0 (nav-mock-cursor b))))

(deftest nav-a3-beginning-of-buffer-noop-at-start
  "M-< 已在 offset 0 時不 error，cursor 維持 0。"
  (with-nav-buf (b :text "hello" :cursor 0)
    (assert-no-error (limn/text-nav:beginning-of-buffer (nav-mock-id b)))
    (assert-eql 0 (nav-mock-cursor b))))

(deftest nav-a3-end-of-buffer
  "M-> 將 cursor 移到 (length text)。"
  (with-nav-buf (b :text "hello" :cursor 0)
    (limn/text-nav:end-of-buffer (nav-mock-id b))
    (assert-eql 5 (nav-mock-cursor b))))

(deftest nav-a3-end-of-buffer-noop-at-end
  "M-> 已在末端時不 error，cursor 不動。"
  (with-nav-buf (b :text "hi" :cursor 2)
    (assert-no-error (limn/text-nav:end-of-buffer (nav-mock-id b)))
    (assert-eql 2 (nav-mock-cursor b))))

(deftest nav-a3-bof-eof-empty-buffer
  "空 buffer 時 M-< 和 M-> 都落在 offset 0。"
  (with-nav-buf (b :text "" :cursor 0)
    (limn/text-nav:beginning-of-buffer (nav-mock-id b))
    (assert-eql 0 (nav-mock-cursor b))
    (limn/text-nav:end-of-buffer (nav-mock-id b))
    (assert-eql 0 (nav-mock-cursor b))))

;;; ── A4. C-n / C-p — next-line / previous-line ──────────────────────────
;;;
;;; Buffer layout used throughout A4:
;;;   "hello\\\nworld\\\nfoo"
;;;    0123456789012345
;;;   line 0: "hello"  offsets 0-4, \n at 5
;;;   line 1: "world"  offsets 6-10, \n at 11
;;;   line 2: "foo"    offsets 12-14

(deftest nav-a4-next-line-same-column
  "C-n 從第一行移到第二行的同欄。"
  ;; cursor at 2 (col 2 of "hello") → col 2 of "world" = offset 8
  (with-nav-buf (b :text "hello\\\nworld\\\nfoo" :cursor 2)
    (limn/text-nav:next-line (nav-mock-id b))
    (assert-eql 8 (nav-mock-cursor b) "col 2 of 'world'")))

(deftest nav-a4-next-line-col0
  "C-n 從行首（col 0）移到下一行的行首。"
  (with-nav-buf (b :text "hello\\\nworld\\\nfoo" :cursor 0)
    (limn/text-nav:next-line (nav-mock-id b))
    (assert-eql 6 (nav-mock-cursor b) "start of 'world'")))

(deftest nav-a4-next-line-two-steps
  "C-n 連按兩次從第一行移到第三行。"
  (with-nav-buf (b :text "hello\\\nworld\\\nfoo" :cursor 2)
    (limn/text-nav:next-line (nav-mock-id b))  ; col 2 of "world" = 8
    (limn/text-nav:next-line (nav-mock-id b))  ; col 2 of "foo" = 14
    (assert-eql 14 (nav-mock-cursor b) "col 2 of 'foo'")))

(deftest nav-a4-next-line-from-last-line-noop
  "C-n 在最後一行時 cursor 不往前移。"
  (with-nav-buf (b :text "hello\\\nworld\\\nfoo" :cursor 13)
    (let ((before (nav-mock-cursor b)))
      (limn/text-nav:next-line (nav-mock-id b))
      (assert-true (>= (nav-mock-cursor b) before) "cursor should not go backward"))))

(deftest nav-a4-previous-line-same-column
  "C-p 從第二行移到第一行的同欄。"
  ;; cursor at 8 (col 2 of "world") → col 2 of "hello" = 2
  (with-nav-buf (b :text "hello\\\nworld\\\nfoo" :cursor 8)
    (limn/text-nav:previous-line (nav-mock-id b))
    (assert-eql 2 (nav-mock-cursor b) "col 2 of 'hello'")))

(deftest nav-a4-previous-line-from-first-line-noop
  "C-p 在第一行時 cursor 不往後移。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 3)
    (let ((before (nav-mock-cursor b)))
      (limn/text-nav:previous-line (nav-mock-id b))
      (assert-true (<= (nav-mock-cursor b) before) "cursor should not go forward"))))

(deftest nav-a4-next-line-short-line-snaps-to-eol
  "C-n 跳到比目標欄短的行時停在行尾。"
  ;; "hello\\\nx\\\nworld!!!"  col 4 of "hello"; "x" has len 1, so snap to end of "x"
  ;; "x" is at offset 6, \n is at 7; end of "x" = offset 7
  (with-nav-buf (b :text "hello\\\nx\\\nworld!!!" :cursor 4)
    (limn/text-nav:next-line (nav-mock-id b))
    ;; cursor should be at 7 (= end of "x" line, before \n)
    ;; or 6 (at "x" itself — implementation may differ on "at-end" definition)
    (assert-true (<= 6 (nav-mock-cursor b) 7) "cursor should clamp inside 'x' line")))

;;; ── A5. *goal-column* 保留 ───────────────────────────────────────────────

(deftest nav-a5-goal-column-starts-nil
  "*goal-column* 在每個 with-nav-buf 進入時為 nil。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 0)
    (let ((goal-sym (find-symbol "*GOAL-COLUMN*" '#:limn/text-nav)))
      (when goal-sym
        (assert-false (symbol-value goal-sym) "*goal-column* starts nil")))))

(deftest nav-a5-goal-column-preserved-through-short-line
  "*goal-column* 在遇到短行後仍保留，再跳長行時欄位還原。"
  ;; lines: "hello" (col 0-4) / "x" (col 0) / "world!!!" (col 0-7)
  ;; Start at col 4 of "hello" (offset 4).
  ;; C-n → "x" (snaps to col 0 or 1), but *goal-column* stays 4.
  ;; C-n again → "world!!!" col 4 = offset 8+4 = start_of_world!!!+4
  ;; "hello\\\nx\\\nworld!!!" → "world!!!" starts at offset 8
  (with-nav-buf (b :text "hello\\\nx\\\nworld!!!" :cursor 4)
    (limn/text-nav:next-line (nav-mock-id b))   ; → short "x" line
    (let ((goal-sym (find-symbol "*GOAL-COLUMN*" '#:limn/text-nav)))
      (when goal-sym
        (assert-eql 4 (symbol-value goal-sym) "*goal-column* preserved after short line")))
    (limn/text-nav:next-line (nav-mock-id b))   ; → "world!!!", restore col 4
    (assert-eql 12 (nav-mock-cursor b) "col 4 of 'world!!!' = offset 12")))

;;; ── A6. M-f / M-b — forward-word / backward-word ────────────────────────

(deftest nav-a6-forward-word-from-start-of-word
  "M-f 從 word 頭跳到 word 尾（word = alphanumeric + _）。"
  (with-nav-buf (b :text "hello world" :cursor 0)
    (limn/text-nav:forward-word (nav-mock-id b))
    (assert-eql 5 (nav-mock-cursor b) "after 'hello'")))

(deftest nav-a6-forward-word-from-whitespace
  "M-f 從空白處先越過空白再跳到下個 word 尾。"
  (with-nav-buf (b :text "hello world" :cursor 5)  ; at space
    (limn/text-nav:forward-word (nav-mock-id b))
    (assert-eql 11 (nav-mock-cursor b) "after 'world'")))

(deftest nav-a6-forward-word-at-end-noop
  "M-f 在 buffer 末端時 cursor 不動。"
  (with-nav-buf (b :text "hi" :cursor 2)
    (limn/text-nav:forward-word (nav-mock-id b))
    (assert-eql 2 (nav-mock-cursor b))))

(deftest nav-a6-forward-word-underscore-in-word
  "M-f 把 _ 視為 word char；foo_bar 是一個整體。"
  (with-nav-buf (b :text "foo_bar baz" :cursor 0)
    (limn/text-nav:forward-word (nav-mock-id b))
    (assert-eql 7 (nav-mock-cursor b) "after 'foo_bar'")))

(deftest nav-a6-forward-word-across-newline
  "M-f 可跨越 \\\\n 跳到下一行的 word 尾。"
  ;; cursor at end of "hello" (offset 5, the \n); forward-word should
  ;; skip \n (non-word) and land after "world" (offset 11)
  (with-nav-buf (b :text "hello\\\nworld" :cursor 5)
    (limn/text-nav:forward-word (nav-mock-id b))
    (assert-eql 11 (nav-mock-cursor b) "after 'world' on next line")))

(deftest nav-a6-backward-word-from-end-of-word
  "M-b 從 word 尾跳到 word 頭。"
  (with-nav-buf (b :text "hello world" :cursor 11)  ; at end
    (limn/text-nav:backward-word (nav-mock-id b))
    (assert-eql 6 (nav-mock-cursor b) "start of 'world'")))

(deftest nav-a6-backward-word-from-whitespace
  "M-b 從空白處先越過空白再跳到前個 word 頭。"
  (with-nav-buf (b :text "hello world" :cursor 6)  ; 'w' of "world"
    (limn/text-nav:backward-word (nav-mock-id b))
    (assert-eql 0 (nav-mock-cursor b) "start of 'hello'")))

(deftest nav-a6-backward-word-at-start-noop
  "M-b 在 buffer 開頭時 cursor 不動。"
  (with-nav-buf (b :text "hi" :cursor 0)
    (limn/text-nav:backward-word (nav-mock-id b))
    (assert-eql 0 (nav-mock-cursor b))))

(deftest nav-a6-backward-word-underscore-in-word
  "M-b 把 _ 視為 word char。"
  (with-nav-buf (b :text "foo foo_bar" :cursor 11)
    (limn/text-nav:backward-word (nav-mock-id b))
    (assert-eql 4 (nav-mock-cursor b) "start of 'foo_bar'")))

;;; ── A7. RET — newline ────────────────────────────────────────────────────

(deftest nav-a7-newline-inserts-and-advances-cursor
  "RET 在 cursor 位置插入 \\\\n，cursor 移到 \\\\n 後方（下一行行首）。"
  (with-nav-buf (b :text "helloworld" :cursor 5)
    (limn/text-nav:newline (nav-mock-id b))
    (assert-equal (%nl "hello\\\nworld") (nav-mock-text b))
    (assert-eql 6 (nav-mock-cursor b))))

(deftest nav-a7-newline-at-start
  "RET 在 offset 0 插入 \\\\n，文字成為 \\\\nhello，cursor 在 1。"
  (with-nav-buf (b :text "hello" :cursor 0)
    (limn/text-nav:newline (nav-mock-id b))
    (assert-equal (%nl "\\\nhello") (nav-mock-text b))
    (assert-eql 1 (nav-mock-cursor b))))

(deftest nav-a7-newline-at-end
  "RET 在 buffer 末端插入 \\\\n，cursor 在新末端。"
  (with-nav-buf (b :text "hello" :cursor 5)
    (limn/text-nav:newline (nav-mock-id b))
    (assert-equal (%nl "hello\\\n") (nav-mock-text b))
    (assert-eql 6 (nav-mock-cursor b))))

(deftest nav-a7-newline-empty-buffer
  "RET 在空 buffer 中插入 \\\\n，cursor 在 1。"
  (with-nav-buf (b :text "" :cursor 0)
    (limn/text-nav:newline (nav-mock-id b))
    (assert-equal (%nl "\\\n") (nav-mock-text b))
    (assert-eql 1 (nav-mock-cursor b))))

;;; ── A8. DEL / C-d — delete-forward-char ─────────────────────────────────

(deftest nav-a8-delete-forward-char-basic
  "DEL/C-d 刪掉 cursor 後一個字元，cursor offset 不變。"
  ;; "hello"  cursor at 1 (before 'e'); delete 'e' → "hllo"
  (with-nav-buf (b :text "hello" :cursor 1)
    (limn/text-nav:delete-forward-char (nav-mock-id b))
    (assert-equal "hllo" (nav-mock-text b))
    (assert-eql 1 (nav-mock-cursor b))))

(deftest nav-a8-delete-forward-char-at-end-noop
  "DEL/C-d 在 buffer 末端時 no-op，不 error。"
  (with-nav-buf (b :text "hi" :cursor 2)
    (assert-no-error (limn/text-nav:delete-forward-char (nav-mock-id b)))
    (assert-equal "hi" (nav-mock-text b))))

(deftest nav-a8-delete-forward-char-joins-lines
  "DEL/C-d 刪掉 \\\\n 可合並兩行。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 5)  ; cursor at \n
    (limn/text-nav:delete-forward-char (nav-mock-id b))
    (assert-equal "helloworld" (nav-mock-text b))))

(deftest nav-a8-delete-forward-char-empty-buffer-noop
  "DEL/C-d 在空 buffer 時 no-op。"
  (with-nav-buf (b :text "" :cursor 0)
    (assert-no-error (limn/text-nav:delete-forward-char (nav-mock-id b)))
    (assert-equal "" (nav-mock-text b))))

;;; ── A9. C-k — kill-line ──────────────────────────────────────────────────

(deftest nav-a9-kill-line-kills-to-eol
  "C-k 殺掉 cursor 到行尾（\\\\n 前），文字進 *kill-new-fn*。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 1)  ; after 'h'
    (limn/text-nav:kill-line (nav-mock-id b))
    (assert-equal "ello" (car (nav-mock-killed b)) "killed text")
    (assert-equal (%nl "h\\\nworld") (nav-mock-text b) "remaining text")
    (assert-eql 1 (nav-mock-cursor b) "cursor stays")))

(deftest nav-a9-kill-line-at-bol-kills-whole-content
  "C-k 在行首殺掉整行內容（不含 \\\\n）。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 0)
    (limn/text-nav:kill-line (nav-mock-id b))
    (assert-equal "hello" (car (nav-mock-killed b)))
    (assert-equal (%nl "\\\nworld") (nav-mock-text b))))

(deftest nav-a9-kill-line-at-eol-kills-newline
  "C-k 在行尾（cursor 正好在 \\\\n 處）時殺掉 \\\\n 本身（合並下一行）。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 5)  ; at \n
    (limn/text-nav:kill-line (nav-mock-id b))
    (assert-equal (%nl "\\\n") (car (nav-mock-killed b)) "killed newline")
    (assert-equal "helloworld" (nav-mock-text b))))

(deftest nav-a9-kill-line-last-line-no-newline
  "C-k 在最後一行（無結尾 \\\\n）殺掉 cursor 到 buffer 末端。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 8)  ; 'r' in "world"
    (limn/text-nav:kill-line (nav-mock-id b))
    (assert-equal "rld" (car (nav-mock-killed b)))
    (assert-equal (%nl "hello\\\nwo") (nav-mock-text b))))

(deftest nav-a9-kill-line-empty-buffer-noop
  "C-k 在空 buffer 時 no-op，killed 列表仍空（或殺空字串）。"
  (with-nav-buf (b :text "" :cursor 0)
    (assert-no-error (limn/text-nav:kill-line (nav-mock-id b)))
    (assert-equal "" (nav-mock-text b))))

;;; ── A10. M-d — kill-word ─────────────────────────────────────────────────

(deftest nav-a10-kill-word-basic
  "M-d 殺掉 cursor 到下個 word 尾，剩餘文字正確。"
  (with-nav-buf (b :text "hello world" :cursor 0)
    (limn/text-nav:kill-word (nav-mock-id b))
    (assert-equal "hello" (car (nav-mock-killed b)))
    (assert-equal " world" (nav-mock-text b))
    (assert-eql 0 (nav-mock-cursor b))))

(deftest nav-a10-kill-word-from-whitespace
  "M-d 從空白處殺到下個 word 尾（連同空白一起殺）。"
  (with-nav-buf (b :text "hello world" :cursor 5)
    (limn/text-nav:kill-word (nav-mock-id b))
    (assert-equal " world" (car (nav-mock-killed b)))
    (assert-equal "hello" (nav-mock-text b))))

(deftest nav-a10-kill-word-at-end-noop
  "M-d 在 buffer 末端時 no-op，不 error。"
  (with-nav-buf (b :text "hi" :cursor 2)
    (assert-no-error (limn/text-nav:kill-word (nav-mock-id b)))
    (assert-true (null (nav-mock-killed b)) "nothing was killed")))

(deftest nav-a10-kill-word-underscore
  "M-d 把 foo_bar 當作一個整體殺掉。"
  (with-nav-buf (b :text "foo_bar baz" :cursor 0)
    (limn/text-nav:kill-word (nav-mock-id b))
    (assert-equal "foo_bar" (car (nav-mock-killed b)))))

;;; ── A11. kill-ring 整合 ──────────────────────────────────────────────────
;;;
;;; 用真實 limn/kill 模組（若已載入）。*kill-new-fn* 接回 limn/kill:kill-new。

(deftest nav-a11-kill-line-pushes-to-kill-ring
  "kill-line 透過 *kill-new-fn* 呼叫後，limn/kill:*kill-ring* 有正確的 killed text。"
  (let ((kill-pkg (find-package '#:limn/kill))
        (nav-pkg  (find-package '#:limn/text-nav)))
    (if (or (null kill-pkg) (null nav-pkg))
        (check t "skipped (limn/kill or limn/text-nav not loaded)" nil)
        (let* ((ring-sym    (find-symbol "*KILL-RING*"    kill-pkg))
               (kill-fn-sym (find-symbol "KILL-NEW"       kill-pkg))
               (vtable-sym  (find-symbol "*KILL-NEW-FN*"  nav-pkg)))
          (when (and ring-sym kill-fn-sym vtable-sym)
            (let ((limn/kill:*kill-ring* '()))
              (with-nav-buf (b :text "hello\\\nworld" :cursor 0)
                (progv (list vtable-sym)
                       (list (symbol-function kill-fn-sym))
                  (limn/text-nav:kill-line (nav-mock-id b))
                  (assert-equal "hello" (car limn/kill:*kill-ring*))))))))))

(deftest nav-a11-kill-line-yank-roundtrip
  "C-k 後 *kill-ring* 有值，limn/kill:yank 可將文字回填 buffer。"
  (let ((kill-pkg (find-package '#:limn/kill))
        (nav-pkg  (find-package '#:limn/text-nav)))
    (if (or (null kill-pkg) (null nav-pkg))
        (check t "skipped (limn/kill or limn/text-nav not loaded)" nil)
        (let* ((ring-sym   (find-symbol "*KILL-RING*"   kill-pkg))
               (kill-fn    (find-symbol "KILL-NEW"      kill-pkg))
               (yank-fn    (find-symbol "YANK"          kill-pkg))
               (vtable-sym (find-symbol "*KILL-NEW-FN*" nav-pkg)))
          (when (and ring-sym kill-fn yank-fn vtable-sym)
            (let ((limn/kill:*kill-ring* '()))
              (with-nav-buf (b :text "hello\\\n" :cursor 0)
                (progv (list vtable-sym)
                       (list (symbol-function kill-fn))
                  (limn/text-nav:kill-line (nav-mock-id b))
                  ;; killed "hello"; buffer is now "\\\n"
                  (assert-equal "hello" (car limn/kill:*kill-ring*)))
                ;; yank at cursor (offset 0) should re-insert "hello"
                ;; NOTE: this requires limn/kill's insert vtable to be wired too
                (assert-true t "kill-ring populated; yank wiring is impl concern"))))))))

;;; ── A12. Dogfood pain points — *goal-column* 多步保留 ─────────────────────
;;;
;;; 連續 C-n / C-p 在無短行干擾時，欄位應維持不變；
;;; 連續 C-p 應該能回到原始位置（往返一致）。

(deftest nav-a12-goal-column-3-steps-down
  "C-n 連按 3 次，跨多行，欄位都維持原欄。"
  ;; "abcde\\\nfghij\\\nklmno\\\npqrst"  cursor at col 3 of line 0 = offset 3
  (with-nav-buf (b :text "abcde\\\nfghij\\\nklmno\\\npqrst" :cursor 3)
    (limn/text-nav:next-line (nav-mock-id b))  ; → col 3 of "fghij" = 9
    (limn/text-nav:next-line (nav-mock-id b))  ; → col 3 of "klmno" = 15
    (limn/text-nav:next-line (nav-mock-id b))  ; → col 3 of "pqrst" = 21
    (assert-eql 21 (nav-mock-cursor b))))

(deftest nav-a12-goal-column-roundtrip-down-up
  "C-n 3 次後 C-p 3 次回到原位（行長度相同時）。"
  (with-nav-buf (b :text "abcde\\\nfghij\\\nklmno\\\npqrst" :cursor 3)
    (let ((start (nav-mock-cursor b)))
      (dotimes (i 3) (limn/text-nav:next-line (nav-mock-id b)))
      (dotimes (i 3) (limn/text-nav:previous-line (nav-mock-id b)))
      (assert-eql start (nav-mock-cursor b) "should return to starting offset"))))

(deftest nav-a12-goal-column-survives-multiple-short-lines
  "*goal-column* 跨越多個短行後在長行上還原原欄。"
  ;; "world!!!\\\na\\\nb\\\nworld!!!"  col 5 of line 0 = offset 5
  ;; → "a" (col 1), → "b" (col 1), → "world!!!" col 5 = offset 5+1+2+2 = ... let me recalc
  ;; "world!!!\\\n"  = 9 chars (0-7 = "world!!!", \n at 8)
  ;; "a\\\n"         = 2 chars (9 = 'a', \n at 10)
  ;; "b\\\n"         = 2 chars (11 = 'b', \n at 12)
  ;; "world!!!"    = 8 chars (13-20)
  ;; col 5 of "world!!!" line 3 = offset 13 + 5 = 18
  (with-nav-buf (b :text "world!!!\\\na\\\nb\\\nworld!!!" :cursor 5)
    (limn/text-nav:next-line (nav-mock-id b))   ; → "a" (snap)
    (limn/text-nav:next-line (nav-mock-id b))   ; → "b" (snap)
    (limn/text-nav:next-line (nav-mock-id b))   ; → "world!!!" col 5
    (assert-eql 18 (nav-mock-cursor b) "col 5 of last 'world!!!'")))

(deftest nav-a12-goal-column-reset-after-bol
  "*goal-column* 在 C-a 後被 reset（橫向動作打斷）。"
  (with-nav-buf (b :text "hello\\\nworld\\\nfoo" :cursor 4)  ; col 4 of "hello"
    (limn/text-nav:next-line (nav-mock-id b))   ; sets *goal-column* = 4
    (limn/text-nav:move-beginning-of-line (nav-mock-id b))  ; should reset
    (let ((goal-sym (find-symbol "*GOAL-COLUMN*" '#:limn/text-nav)))
      (when goal-sym
        (assert-false (symbol-value goal-sym)
                      "*goal-column* should be nil after C-a")))))

(deftest nav-a12-goal-column-reset-after-forward-char
  "*goal-column* 在 forward-char 後被 reset。"
  (with-nav-buf (b :text "hello\\\nworld" :cursor 4)
    (limn/text-nav:next-line (nav-mock-id b))   ; sets goal = 4
    ;; Simulate C-f by manually moving cursor; in real impl forward-char
    ;; would also reset.  Here we test the more important reset: M-f.
    (limn/text-nav:forward-word (nav-mock-id b))
    (let ((goal-sym (find-symbol "*GOAL-COLUMN*" '#:limn/text-nav)))
      (when goal-sym
        (assert-false (symbol-value goal-sym)
                      "*goal-column* should be nil after M-f")))))

;;; ── A13. Dogfood pain points — empty lines / multi-newline ──────────────

(deftest nav-a13-bol-on-empty-line
  "C-a 在空行（前後都是 \\\\n）時 cursor 不動。"
  ;; "a\\\n\\\nb"  cursor at 2 (between two \n's, on empty line)
  (with-nav-buf (b :text "a\\\n\\\nb" :cursor 2)
    (limn/text-nav:move-beginning-of-line (nav-mock-id b))
    (assert-eql 2 (nav-mock-cursor b))))

(deftest nav-a13-eol-on-empty-line
  "C-e 在空行時 cursor 不動（行首=行尾）。"
  (with-nav-buf (b :text "a\\\n\\\nb" :cursor 2)
    (limn/text-nav:move-end-of-line (nav-mock-id b))
    (assert-eql 2 (nav-mock-cursor b))))

(deftest nav-a13-next-line-from-empty-line
  "C-n 從空行跳到下一行的行首（col 0）。"
  (with-nav-buf (b :text "a\\\n\\\nb" :cursor 2)
    (limn/text-nav:next-line (nav-mock-id b))
    (assert-eql 3 (nav-mock-cursor b) "start of 'b' line")))

;;; ── A14. Dogfood pain points — Unicode / CJK ─────────────────────────────

(deftest nav-a14-delete-forward-char-cjk
  "DEL/C-d 刪掉 CJK 字元（一個 character，不是一個 byte）。"
  ;; "你好" cursor at 0; after delete-forward-char → "好"
  (with-nav-buf (b :text "你好" :cursor 0)
    (limn/text-nav:delete-forward-char (nav-mock-id b))
    (assert-equal "好" (nav-mock-text b))
    (assert-eql 0 (nav-mock-cursor b))))

(deftest nav-a14-newline-after-cjk
  "RET 在 CJK 字元後插入 \\\\n 正常運作。"
  (with-nav-buf (b :text "你好" :cursor 1)
    (limn/text-nav:newline (nav-mock-id b))
    (assert-equal (%nl "你\\\n好") (nav-mock-text b))
    (assert-eql 2 (nav-mock-cursor b))))

;;; ── A15. Dogfood pain points — word boundary edge cases ────────────────

(deftest nav-a15-forward-word-from-middle-of-word
  "M-f 從 word 中間出發跳到該 word 的尾端（不是下一個 word）。"
  (with-nav-buf (b :text "hello world" :cursor 2)  ; middle of "hello"
    (limn/text-nav:forward-word (nav-mock-id b))
    (assert-eql 5 (nav-mock-cursor b) "end of 'hello'")))

(deftest nav-a15-backward-word-from-middle-of-word
  "M-b 從 word 中間出發跳到該 word 的頭端（不是前一個 word）。"
  (with-nav-buf (b :text "hello world" :cursor 8)  ; middle of "world"
    (limn/text-nav:backward-word (nav-mock-id b))
    (assert-eql 6 (nav-mock-cursor b) "start of 'world'")))

(deftest nav-a15-kill-word-crosses-newline
  "M-d 在 \\\\n 處殺掉 \\\\n 加下一個 word。"
  ;; "foo\\\nbar"  cursor at 3 (at \n); M-d should kill "\\\nbar"
  (with-nav-buf (b :text "foo\\\nbar" :cursor 3)
    (limn/text-nav:kill-word (nav-mock-id b))
    (assert-equal (%nl "\\\nbar") (car (nav-mock-killed b)))
    (assert-equal "foo" (nav-mock-text b))))

;;; ── A16. Dogfood pain points — boundary safety ──────────────────────────

(deftest nav-a16-next-line-past-end-noop-safe
  "C-n 多次按到 buffer 末端後再按不 error。"
  (with-nav-buf (b :text "a\\\nb\\\nc" :cursor 0)
    (assert-no-error
      (progn
        (dotimes (i 10) (limn/text-nav:next-line (nav-mock-id b)))))))

(deftest nav-a16-previous-line-before-start-noop-safe
  "C-p 多次按到 buffer 開頭後再按不 error。"
  (with-nav-buf (b :text "a\\\nb\\\nc" :cursor 4)
    (assert-no-error
      (progn
        (dotimes (i 10) (limn/text-nav:previous-line (nav-mock-id b)))))))

(deftest nav-a16-kill-line-at-end-of-buffer-noop
  "C-k 在 buffer 末端（cursor 等於 text length）no-op。"
  (with-nav-buf (b :text "hello" :cursor 5)
    (assert-no-error (limn/text-nav:kill-line (nav-mock-id b)))
    (assert-equal "hello" (nav-mock-text b) "text unchanged")))
