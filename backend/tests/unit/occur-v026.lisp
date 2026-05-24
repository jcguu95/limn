;;;; v0.26 §B — occur RED tests  (~28 tests)
;;;;
;;;; Tests cover: occur search producing match records, line formatting,
;;;; navigation (next/prev), source-buffer jump, regexp mode, and edge cases.
;;;;
;;;; API under test (limn/occur):
;;;;   (occur buf-id pattern &key regexp) → state
;;;;   (occur-results state) → list of occur-match structs
;;;;   (occur-count state) → integer
;;;;   (occur-current state) → integer (0-based), nil if no results
;;;;   (occur-source-buf-id state) → string
;;;;   (occur-occur-buf-id state) → string (always "*occur*")
;;;;   (occur-next state) → state
;;;;   (occur-prev state) → state
;;;;   (occur-jump state) → integer (cursor offset in source buf)
;;;;   (occur-match-p x) → boolean
;;;;   (occur-match-line-num match) → integer (1-based)
;;;;   (occur-match-line-text match) → string
;;;;   (occur-match-start match) → integer (within line)
;;;;   (occur-match-end match) → integer (within line, exclusive)
;;;;   (occur-match-offset match) → integer (codepoint offset from buf start)
;;;;   (format-occur-results state) → string
;;;;   (format-occur-line num text start end) → string
;;;;
;;;; I/O vtable (test isolation):
;;;;   *buffer-text-fn*      : (buf-id) → string
;;;;   *buffer-set-cursor-fn*: (buf-id offset) → void
;;;;   *occur-write-fn*      : (occur-buf-id content) → void
;;;;
;;;; All RED until limn/occur is implemented.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/occur)
    (make-package '#:limn/occur :use '(#:cl)))
  (dolist (sym '("OCCUR"
                 "OCCUR-RESULTS"
                 "OCCUR-COUNT"
                 "OCCUR-CURRENT"
                 "OCCUR-SOURCE-BUF-ID"
                 "OCCUR-OCCUR-BUF-ID"
                 "OCCUR-NEXT"
                 "OCCUR-PREV"
                 "OCCUR-JUMP"
                 "OCCUR-MATCH-P"
                 "OCCUR-MATCH-LINE-NUM"
                 "OCCUR-MATCH-LINE-TEXT"
                 "OCCUR-MATCH-START"
                 "OCCUR-MATCH-END"
                 "OCCUR-MATCH-OFFSET"
                 "FORMAT-OCCUR-RESULTS"
                 "FORMAT-OCCUR-LINE"
                 "*BUFFER-TEXT-FN*"
                 "*BUFFER-SET-CURSOR-FN*"
                 "*OCCUR-WRITE-FN*"))
    (let ((s (intern sym '#:limn/occur)))
      (export s '#:limn/occur))))

(in-package #:limn/unit-test)

;;; ── mock for occur ─────────────────────────────────────────────────────────

(defstruct (occur-mock
            (:constructor %make-occur-mock (&key id text)))
  id
  (text "" :type string)
  (cursor 0 :type integer)
  (occur-written nil)   ; last content passed to *occur-write-fn*
  )

(defun make-occur-mock (&key (id "b") (text ""))
  (%make-occur-mock :id id :text text))

(defmacro with-occur-buf ((var &key (id "b") (text "")) &body body)
  (let ((pkg (gensym "PKG")))
    `(let* ((,var  (make-occur-mock :id ,id :text ,text))
            (,pkg  (find-package '#:limn/occur)))
       (if (null ,pkg)
           (progn ,@body)
           (let* ((pairs
                    (list
                     (cons (find-symbol "*BUFFER-TEXT-FN*"       ,pkg)
                           (lambda (bid)
                             (declare (ignore bid))
                             (occur-mock-text ,var)))
                     (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,pkg)
                           (lambda (bid off)
                             (declare (ignore bid))
                             (setf (occur-mock-cursor ,var) off)))
                     (cons (find-symbol "*OCCUR-WRITE-FN*"       ,pkg)
                           (lambda (obid content)
                             (declare (ignore obid))
                             (setf (occur-mock-occur-written ,var) content)))))
                  (live (remove-if (lambda (p) (null (car p))) pairs)))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))

;;; ─── B1. basic occur search ────────────────────────────────────────────────

(deftest occur-b1-three-line-match
  (with-occur-buf (m :text (format nil "alpha~%beta alpha~%gamma"))
    (let* ((st (limn/occur:occur (occur-mock-id m) "alpha")))
      (assert-equal 2 (limn/occur:occur-count st)
                    "two lines containing 'alpha'"))))

(deftest occur-b1-zero-matches-empty-result
  (with-occur-buf (m :text (format nil "hello world~%foo bar"))
    (let* ((st (limn/occur:occur (occur-mock-id m) "zzz")))
      (assert-equal 0 (limn/occur:occur-count st)
                    "no matches → count 0")
      (assert-equal '() (limn/occur:occur-results st)
                    "no matches → empty results list"))))

(deftest occur-b1-result-line-numbers-are-correct
  (with-occur-buf (m :text (format nil "line1~%line2 match~%line3~%line4 match"))
    (let* ((st      (limn/occur:occur (occur-mock-id m) "match"))
           (results (limn/occur:occur-results st)))
      (assert-equal 2 (length results))
      (assert-equal 2 (limn/occur:occur-match-line-num (first results))
                    "first match on line 2")
      (assert-equal 4 (limn/occur:occur-match-line-num (second results))
                    "second match on line 4"))))

(deftest occur-b1-result-line-text
  (with-occur-buf (m :text (format nil "hello world~%goodbye world"))
    (let* ((st      (limn/occur:occur (occur-mock-id m) "world"))
           (results (limn/occur:occur-results st)))
      (assert-equal "hello world"   (limn/occur:occur-match-line-text (first results)))
      (assert-equal "goodbye world" (limn/occur:occur-match-line-text (second results))))))

(deftest occur-b1-match-start-end-within-line
  (with-occur-buf (m :text "hello world")
    (let* ((st      (limn/occur:occur (occur-mock-id m) "world"))
           (match   (first (limn/occur:occur-results st))))
      (assert-equal 6 (limn/occur:occur-match-start match)
                    "match-start offset within line")
      (assert-equal 11 (limn/occur:occur-match-end match)
                    "match-end offset within line"))))

(deftest occur-b1-occur-write-fn-called-with-content
  (with-occur-buf (m :text (format nil "hello world~%hello again"))
    (limn/occur:occur (occur-mock-id m) "hello")
    (assert-true (occur-mock-occur-written m)
                 "*occur-write-fn* was called")
    (assert-true (stringp (occur-mock-occur-written m))
                 "content is a string")))

;;; ─── B2. navigation and source jump ──────────────────────────────────────

(deftest occur-b2-initial-current-is-zero
  (with-occur-buf (m :text (format nil "a match~%b match"))
    (let* ((st (limn/occur:occur (occur-mock-id m) "match")))
      (assert-equal 0 (limn/occur:occur-current st)
                    "initial current-index is 0"))))

(deftest occur-b2-next-advances-current
  (with-occur-buf (m :text (format nil "a match~%b match~%c match"))
    (let* ((st  (limn/occur:occur (occur-mock-id m) "match"))
           (st2 (limn/occur:occur-next st)))
      (assert-equal 1 (limn/occur:occur-current st2)
                    "next → current-index 1"))))

(deftest occur-b2-prev-decrements-current
  (with-occur-buf (m :text (format nil "a match~%b match~%c match"))
    (let* ((st  (limn/occur:occur (occur-mock-id m) "match"))
           (st2 (limn/occur:occur-next st))
           (st3 (limn/occur:occur-prev st2)))
      (assert-equal 0 (limn/occur:occur-current st3)
                    "prev → back to 0"))))

(deftest occur-b2-jump-sets-source-cursor
  (with-occur-buf (m :text (format nil "alpha~%beta match~%gamma"))
    (let* ((st  (limn/occur:occur (occur-mock-id m) "match")))
      (limn/occur:occur-jump st)
      ;; "alpha\n" = 6 chars, "beta " = 5, so "match" starts at 11
      (assert-equal 11 (occur-mock-cursor m)
                    "jump sets cursor to match offset in source"))))

(deftest occur-b2-next-then-jump-correct-offset
  (with-occur-buf (m :text (format nil "match here~%and another match"))
    (let* ((st  (limn/occur:occur (occur-mock-id m) "match"))
           (st2 (limn/occur:occur-next st)))
      (limn/occur:occur-jump st2)
      ;; "match here\n" = 11 chars, "and another " = 12 chars → "match" at 23
      (assert-equal 23 (occur-mock-cursor m)
                    "jump after next lands on second match"))))

(deftest occur-b2-empty-results-next-is-noop
  (with-occur-buf (m :text "hello")
    (let* ((st  (limn/occur:occur (occur-mock-id m) "zzz"))
           (st2 (limn/occur:occur-next st)))
      (assert-equal nil (limn/occur:occur-current st2)
                    "empty results: current stays nil after next"))))

;;; ─── B3. regexp mode ──────────────────────────────────────────────────────

(deftest occur-b3-regexp-basic-match
  (with-occur-buf (m :text (format nil "foo123~%bar456~%foo789"))
    (let* ((st (limn/occur:occur (occur-mock-id m) "foo" :regexp t)))
      (assert-equal 2 (limn/occur:occur-count st)
                    "regexp 'foo' matches 2 lines"))))

(deftest occur-b3-regexp-digit-class
  (with-occur-buf (m :text (format nil "abc~%123~%xyz~%456"))
    (let* ((st (limn/occur:occur (occur-mock-id m) "[0-9]+" :regexp t)))
      (assert-equal 2 (limn/occur:occur-count st)
                    "regexp digit class matches 2 lines"))))

(deftest occur-b3-invalid-regexp-no-crash
  (with-occur-buf (m :text "hello")
    (assert-no-error
      (limn/occur:occur (occur-mock-id m) "[[invalid" :regexp t)
      "invalid regexp: no crash, returns state")))

(deftest occur-b3-cjk-pattern
  (with-occur-buf (m :text (format nil "你好世界~%hello world~%你好"))
    (let* ((st (limn/occur:occur (occur-mock-id m) "你好")))
      (assert-equal 2 (limn/occur:occur-count st)
                    "CJK pattern matches 2 lines"))))

;;; ─── B4. formatting ───────────────────────────────────────────────────────

(deftest occur-b4-format-occur-line-has-line-number
  (let ((line (limn/occur:format-occur-line 5 "hello world" 6 11)))
    (assert-true (search "5" line) "formatted line contains line number")))

(deftest occur-b4-format-occur-line-has-content
  (let ((line (limn/occur:format-occur-line 3 "testing 123" 0 7)))
    (assert-true (search "testing 123" line)
                 "formatted line contains the line text")))

(deftest occur-b4-format-occur-results-has-all-lines
  (with-occur-buf (m :text (format nil "match one~%no hit~%match two"))
    (let* ((st      (limn/occur:occur (occur-mock-id m) "match"))
           (content (limn/occur:format-occur-results st)))
      (assert-true (search "match one" content)
                   "formatted results contain first match line")
      (assert-true (search "match two" content)
                   "formatted results contain second match line")
      (assert-false (search "no hit" content)
                    "formatted results omit non-matching line"))))

(deftest occur-b4-format-zero-matches-no-match-message
  (with-occur-buf (m :text "hello")
    (let* ((st      (limn/occur:occur (occur-mock-id m) "zzz"))
           (content (limn/occur:format-occur-results st)))
      (assert-true (stringp content) "returns a string")
      (assert-true (> (length content) 0)
                   "non-empty even with no matches (should contain message)"))))

;;; ─── B5. cross-module: occur ∩ isearch consistency ───────────────────────

(deftest occur-b5-same-pattern-same-match-count-as-isearch
  ;; Each "apple" on its own line: occur gives 3 (3 matching lines),
  ;; isearch gives 3 (3 occurrences). Both should agree.
  (let ((text (format nil "apple~%banana~%apple~%cherry~%apple")))
    (with-occur-buf (om :text text)
      (with-isearch-buf (im :text text)
        (let* ((ost (limn/occur:occur (occur-mock-id om) "apple"))
               (ist (limn/isearch:isearch-start (isearch-mock-id im)))
               (ist2 (limn/isearch:isearch-update ist "apple")))
          (assert-equal (limn/occur:occur-count ost)
                        (length (limn/isearch:isearch-matches ist2))
                        "occur and isearch find the same count"))))))

(deftest occur-b5-occur-buf-id-is-star-occur-star
  (with-occur-buf (m :text "hello")
    (let* ((st (limn/occur:occur (occur-mock-id m) "hello")))
      (assert-equal "*occur*" (limn/occur:occur-occur-buf-id st)
                    "occur buffer id is always *occur*"))))

(deftest occur-b5-source-buf-id-preserved
  (with-occur-buf (m :id "mybuf" :text "hello world")
    (let* ((st (limn/occur:occur (occur-mock-id m) "hello")))
      (assert-equal "mybuf" (limn/occur:occur-source-buf-id st)
                    "source buf-id preserved in state"))))

(deftest occur-b5-match-p-predicate
  (with-occur-buf (m :text "hello world")
    (let* ((st      (limn/occur:occur (occur-mock-id m) "hello"))
           (results (limn/occur:occur-results st)))
      (when results
        (assert-true (limn/occur:occur-match-p (first results))
                     "occur-match-p recognises a match struct")
        (assert-false (limn/occur:occur-match-p "not a match")
                      "occur-match-p rejects non-match")))))

;;; ─── B6. edge cases ───────────────────────────────────────────────────────

(deftest occur-b6-consecutive-occur-replaces-previous
  ;; Calling occur twice should update the state, not accumulate.
  (with-occur-buf (m :text (format nil "foo~%bar~%foo"))
    (limn/occur:occur (occur-mock-id m) "foo")
    (let* ((st (limn/occur:occur (occur-mock-id m) "bar")))
      (assert-equal 1 (limn/occur:occur-count st)
                    "second occur on 'bar' yields 1, not 3"))))

(deftest occur-b6-same-line-multiple-matches-one-result
  ;; Occur is line-based: a line with 3 "x"s counts as 1 match line.
  (with-occur-buf (m :text (format nil "x x x~%y"))
    (let* ((st (limn/occur:occur (occur-mock-id m) "x")))
      (assert-equal 1 (limn/occur:occur-count st)
                    "single line with multiple matches = 1 result line"))))

(deftest occur-b6-large-buffer-no-hang
  ;; 1000 lines, pattern on every other line.
  (let* ((lines (loop for i from 1 to 1000
                      collect (if (evenp i)
                                  (format nil "line~a match" i)
                                  (format nil "line~a" i))))
         (text (format nil "~{~a~%~}" lines)))
    (with-occur-buf (m :text text)
      (limn/v023-helpers:with-timeout-bound 5
        (let* ((st (limn/occur:occur (occur-mock-id m) "match")))
          (assert-equal 500 (limn/occur:occur-count st)
                        "1000-line buffer: 500 matching lines"))))))

;;; ─── B7. next/prev wrap-around ────────────────────────────────────────────

(deftest occur-b7-next-wraps-from-last-to-first
  (with-occur-buf (m :text (format nil "a match~%b match~%c match"))
    (let* ((st   (limn/occur:occur (occur-mock-id m) "match"))
           (n    (limn/occur:occur-count st))
           ;; advance to last result
           (last (loop repeat (1- n) for s = (limn/occur:occur-next st)
                         then (limn/occur:occur-next s)
                         finally (return s)))
           (wrapped (limn/occur:occur-next last)))
      (assert-equal 0 (limn/occur:occur-current wrapped)
                    "next from last wraps to 0"))))

(deftest occur-b7-prev-wraps-from-first-to-last
  (with-occur-buf (m :text (format nil "a match~%b match~%c match"))
    (let* ((st      (limn/occur:occur (occur-mock-id m) "match"))
           (n       (limn/occur:occur-count st))
           (wrapped (limn/occur:occur-prev st)))
      (assert-equal (1- n) (limn/occur:occur-current wrapped)
                    "prev from 0 wraps to last"))))

;;; ─── B8. occur-jump with no current match ────────────────────────────────

(deftest occur-b8-jump-no-results-is-noop
  "occur-jump on empty results does not crash and cursor is unchanged."
  (with-occur-buf (m :text "hello" :id "b")
    (let* ((st (limn/occur:occur (occur-mock-id m) "zzz")))
      (assert-equal 0 (occur-mock-cursor m) "cursor at 0 before jump")
      (assert-no-error
        (limn/occur:occur-jump st)
        "occur-jump with no results: no error")
      (assert-equal 0 (occur-mock-cursor m)
                    "cursor unchanged after no-op jump"))))

;;; ─── B9. empty-buffer occur ───────────────────────────────────────────────

(deftest occur-b9-empty-buffer-zero-results
  "occur on empty buffer yields 0 results without crashing."
  (with-occur-buf (m :text "")
    (assert-no-error
      (let* ((st (limn/occur:occur (occur-mock-id m) "foo")))
        (assert-equal 0 (limn/occur:occur-count st)
                      "empty buffer → 0 results")))))

;;; ─── B10. match-start semantics: first occurrence in line ────────────────

(deftest occur-b10-match-start-is-first-occurrence
  "When a line has multiple matches, match-start points to the first one."
  (with-occur-buf (m :text "the cat and the cat")
    ;; One line. 'the' at 0 and at 12.
    (let* ((st      (limn/occur:occur (occur-mock-id m) "the"))
           (results (limn/occur:occur-results st)))
      ;; Line-based: 1 result line
      (assert-equal 1 (limn/occur:occur-count st)
                    "one result line")
      (when results
        (assert-equal 0 (limn/occur:occur-match-start (first results))
                      "match-start = first occurrence in line (offset 0)"))))

;;; ─── §B-dog. dogfood / integration tests ──────────────────────────────────

;;; ── §B-dog-1. trailing newline produces no phantom empty line ────────────

(deftest occur-bdog1-trailing-newline-no-phantom-line
  "Buffer ending with a newline does not produce an empty phantom result line."
  ;; text = \"foo\\nbar\\n\" — file-ending newline is the common case
  (with-occur-buf (m :text (format nil "foo~%bar~%"))
    (let* ((st (limn/occur:occur (occur-mock-id m) "foo")))
      (assert-equal 1 (limn/occur:occur-count st)
                    "trailing newline: exactly 1 match, no phantom line")
      (assert-equal 1 (limn/occur:occur-match-line-num
                       (first (limn/occur:occur-results st)))
                    "match is correctly on line 1"))))

(deftest occur-bdog1b-all-lines-end-newline-correct-count
  "Buffer with every line ending in a newline produces correct line count."
  (with-occur-buf (m :text (format nil "match~%skip~%match~%skip~%"))
    (let* ((st (limn/occur:occur (occur-mock-id m) "match")))
      (assert-equal 2 (limn/occur:occur-count st)
                    "4-line file with trailing newline: 2 matching lines"))))

;;; ── §B-dog-2. occur-next does NOT auto-jump ──────────────────────────────

(deftest occur-bdog2-next-does-not-auto-jump
  "occur-next advances selection but does NOT move source-buffer cursor.
   Callers must explicitly call occur-jump after navigating."
  (with-occur-buf (m :text (format nil "match a~%match b"))
    (let* ((st         (limn/occur:occur (occur-mock-id m) "match"))
           (cursor-before (occur-mock-cursor m))
           (st2        (limn/occur:occur-next st))
           (cursor-after  (occur-mock-cursor m)))
      (assert-equal 1 (limn/occur:occur-current st2)
                    "next advances selection index to 1")
      (assert-equal cursor-before cursor-after
                    "source-buffer cursor unchanged — occur-jump must be called explicitly"))))

;;; ── §B-dog-3. occur-jump uses updated current after next ─────────────────

(deftest occur-bdog3-jump-after-next-goes-to-second-match
  "occur-jump after occur-next moves cursor to the SECOND match, not the first."
  ;; text: \"match a\\nmatch b\"
  ;; 'match a' = 7 chars + \\n = 8 total; second 'match' starts at offset 8
  (with-occur-buf (m :text (format nil "match a~%match b"))
    (let* ((st  (limn/occur:occur (occur-mock-id m) "match"))
           (st2 (limn/occur:occur-next st)))
      (limn/occur:occur-jump st2)
      (assert-equal 8 (occur-mock-cursor m)
                    "cursor at offset 8 = start of second 'match'"))))

;;; ── §B-dog-4. long line in occur results does not crash ──────────────────

(deftest occur-bdog4-long-line-format-no-crash
  "format-occur-results handles a 500-character line without error."
  (let* ((body (make-string 496 :initial-element #\x))
         (text (concatenate 'string body " end")))  ; 500 chars, ends with " end"
    (with-occur-buf (m :text text)
      (assert-no-error
        (let* ((st      (limn/occur:occur (occur-mock-id m) "end"))
               (content (limn/occur:format-occur-results st)))
          (assert-equal 1 (limn/occur:occur-count st)
                        "500-char line: 1 result")
          (assert-true (> (length content) 0)
                       "format-occur-results returns non-empty string"))
        "500-char line: no crash"))))
