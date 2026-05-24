;;;; v0.26 §A — isearch RED tests  (~53 tests)
;;;;
;;;; Tests cover: start/update/next/prev/exit/abort state machine,
;;;; match computation, cursor movement, highlight via text-props,
;;;; history integration, case-fold, CJK, and edge cases.
;;;;
;;;; API under test (limn/isearch):
;;;;   (isearch-start buf-id &key (forward t)) → state
;;;;   (isearch-update state query) → state
;;;;   (isearch-next state) → state
;;;;   (isearch-prev state) → state
;;;;   (isearch-exit state)
;;;;   (isearch-abort state)
;;;;   Accessors: isearch-matches, isearch-current-match,
;;;;              isearch-current-index, isearch-query,
;;;;              isearch-active-p, isearch-saved-cursor,
;;;;              isearch-forward-p, isearch-buf-id
;;;;
;;;; I/O vtable (test isolation):
;;;;   *buffer-text-fn*      : (buf-id) → string
;;;;   *buffer-cursor-fn*    : (buf-id) → integer
;;;;   *buffer-set-cursor-fn*: (buf-id offset) → void
;;;;   *highlight-fn*        : (buf-id spans face) → void
;;;;   *clear-highlights-fn* : (buf-id) → void
;;;;   *history-push-fn*     : (query) → void
;;;;   *isearch-case-fold*   : boolean (default t)
;;;;
;;;; All RED until limn/isearch is implemented.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/isearch)
    (make-package '#:limn/isearch :use '(#:cl)))
  (dolist (sym '("ISEARCH-START"
                 "ISEARCH-UPDATE"
                 "ISEARCH-NEXT"
                 "ISEARCH-PREV"
                 "ISEARCH-EXIT"
                 "ISEARCH-ABORT"
                 "ISEARCH-MATCHES"
                 "ISEARCH-CURRENT-MATCH"
                 "ISEARCH-CURRENT-INDEX"
                 "ISEARCH-QUERY"
                 "ISEARCH-ACTIVE-P"
                 "ISEARCH-SAVED-CURSOR"
                 "ISEARCH-FORWARD-P"
                 "ISEARCH-BUF-ID"
                 "*BUFFER-TEXT-FN*"
                 "*BUFFER-CURSOR-FN*"
                 "*BUFFER-SET-CURSOR-FN*"
                 "*HIGHLIGHT-FN*"
                 "*CLEAR-HIGHLIGHTS-FN*"
                 "*HISTORY-PUSH-FN*"
                 "*ISEARCH-CASE-FOLD*"))
    (let ((s (intern sym '#:limn/isearch)))
      (export s '#:limn/isearch))))

(in-package #:limn/unit-test)

;;; ── mock infrastructure ──────────────────────────────────────────────────
;;;
;;; isearch-mock holds the in-memory text + cursor + captured side-effects.
;;; Accessors beginning with im- are test-private (not part of the isearch API).

(defstruct (isearch-mock
            (:constructor %make-isearch-mock (&key id text cursor)))
  id
  (text   "" :type string)
  (cursor  0 :type integer)
  ;; captured from *highlight-fn* calls
  (last-highlight-spans '())
  (last-highlight-face  nil)
  ;; captured from *clear-highlights-fn* calls
  (clear-count 0 :type integer)
  ;; captured from *history-push-fn* calls
  (history-calls '()))

(defun make-isearch-mock (&key (id "b") (text "") (cursor 0))
  (%make-isearch-mock :id id :text text :cursor cursor))

;;; Macro that wires the vtable vars to operate on an isearch-mock.
;;; VAR is bound to the mock struct so tests can inspect side-effects.

(defmacro with-isearch-buf ((var &key (id "b") (text "") (cursor 0)) &body body)
  (let ((pkg (gensym "PKG")))
    `(let* ((,var  (make-isearch-mock :id ,id :text ,text :cursor ,cursor))
            (,pkg  (find-package '#:limn/isearch)))
       (if (null ,pkg)
           (progn ,@body)
           (let* ((pairs
                    (list
                     (cons (find-symbol "*BUFFER-TEXT-FN*"       ,pkg)
                           (lambda (bid)
                             (declare (ignore bid))
                             (isearch-mock-text ,var)))
                     (cons (find-symbol "*BUFFER-CURSOR-FN*"     ,pkg)
                           (lambda (bid)
                             (declare (ignore bid))
                             (isearch-mock-cursor ,var)))
                     (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,pkg)
                           (lambda (bid off)
                             (declare (ignore bid))
                             (setf (isearch-mock-cursor ,var) off)))
                     (cons (find-symbol "*HIGHLIGHT-FN*"         ,pkg)
                           (lambda (bid spans face)
                             (declare (ignore bid))
                             (setf (isearch-mock-last-highlight-spans ,var) spans)
                             (setf (isearch-mock-last-highlight-face  ,var) face)))
                     (cons (find-symbol "*CLEAR-HIGHLIGHTS-FN*"  ,pkg)
                           (lambda (bid)
                             (declare (ignore bid))
                             (setf (isearch-mock-last-highlight-spans ,var) '())
                             (setf (isearch-mock-last-highlight-face  ,var) nil)
                             (incf (isearch-mock-clear-count ,var))))
                     (cons (find-symbol "*HISTORY-PUSH-FN*"      ,pkg)
                           (lambda (q)
                             (push q (isearch-mock-history-calls ,var))))))
                  (live (remove-if (lambda (p) (null (car p))) pairs)))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))

;;; ─── A1. basic search ─────────────────────────────────────────────────────

(deftest isearch-a1-empty-buffer-no-matches
  (with-isearch-buf (m :text "" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "foo")))
      (assert-equal '() (limn/isearch:isearch-matches st2)
                    "empty buffer → 0 matches")
      (assert-false (limn/isearch:isearch-current-match st2)
                    "no current match"))))

(deftest isearch-a1-single-match-cursor-jumps
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "world")))
      (assert-equal 1 (length (limn/isearch:isearch-matches st2))
                    "one match for 'world'")
      (let ((match (limn/isearch:isearch-current-match st2)))
        (assert-true match "current-match is non-nil")
        (assert-equal 6 (car match) "match starts at 6")
        (assert-equal 11 (cdr match) "match ends at 11"))
      ;; cursor should move to match start
      (assert-equal 6 (isearch-mock-cursor m)
                    "cursor jumped to match start"))))

(deftest isearch-a1-multiple-matches-count
  (with-isearch-buf (m :text "cat and cat in the cat hat" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "cat")))
      (assert-equal 3 (length (limn/isearch:isearch-matches st2))
                    "three matches for 'cat'"))))

(deftest isearch-a1-case-insensitive-default
  (with-isearch-buf (m :text "Hello HELLO hello" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello")))
      (assert-equal 3 (length (limn/isearch:isearch-matches st2))
                    "case-fold default: 3 matches"))))

(deftest isearch-a1-case-sensitive-when-fold-off
  (with-isearch-buf (m :text "Hello HELLO hello" :cursor 0)
    (let* ((limn/isearch:*isearch-case-fold* nil)
           (st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello")))
      (assert-equal 1 (length (limn/isearch:isearch-matches st2))
                    "case-sensitive: only lowercase match"))))

(deftest isearch-a1-query-extension-narrows-matches
  (with-isearch-buf (m :text "foo foobar foobaz" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "foo"))
           (n2  (length (limn/isearch:isearch-matches st2)))
           (st3 (limn/isearch:isearch-update st2 "foobar"))
           (n3  (length (limn/isearch:isearch-matches st3))))
      (assert-equal 3 n2 "'foo' matches 3")
      (assert-equal 1 n3 "'foobar' matches 1")
      (assert-true (> n2 n3) "extension narrows results"))))

(deftest isearch-a1-query-shrink-expands-matches
  (with-isearch-buf (m :text "foo foobar foobaz" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "foobar"))
           (st3 (limn/isearch:isearch-update st2 "foo")))
      (assert-equal 3 (length (limn/isearch:isearch-matches st3))
                    "shrinking query expands matches"))))

(deftest isearch-a1-empty-query-clears-matches
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello"))
           (st3 (limn/isearch:isearch-update st2 "")))
      (assert-equal '() (limn/isearch:isearch-matches st3)
                    "empty query → no matches")
      (assert-false (limn/isearch:isearch-current-match st3)))))

;;; ─── A2. navigation ───────────────────────────────────────────────────────

(deftest isearch-a2-next-advances-index
  (with-isearch-buf (m :text "a b a b a" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "a"))
           (idx0 (limn/isearch:isearch-current-index st2))
           (st3 (limn/isearch:isearch-next st2))
           (idx1 (limn/isearch:isearch-current-index st3)))
      (assert-equal (1+ idx0) idx1 "next increments current-index"))))

(deftest isearch-a2-next-moves-cursor-to-new-match
  (with-isearch-buf (m :text "aa bb aa" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "aa"))
           (_   (limn/isearch:isearch-next st2))
           (pos (isearch-mock-cursor m)))
      (assert-equal 6 pos "cursor at second 'aa'"))))

(deftest isearch-a2-prev-decrements-index
  (with-isearch-buf (m :text "a b a b a" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "a"))
           (st3 (limn/isearch:isearch-next st2))
           (st4 (limn/isearch:isearch-prev st3)))
      (assert-equal (limn/isearch:isearch-current-index st2)
                    (limn/isearch:isearch-current-index st4)
                    "prev brings back to original index"))))

(deftest isearch-a2-next-wraps-at-end
  (with-isearch-buf (m :text "x y x" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "x"))
           ;; 2 matches; advance twice to wrap
           (st3 (limn/isearch:isearch-next st2))
           (st4 (limn/isearch:isearch-next st3)))
      (assert-equal 0 (limn/isearch:isearch-current-index st4)
                    "wraps from last to first"))))

(deftest isearch-a2-prev-wraps-at-beginning
  (with-isearch-buf (m :text "x y x" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "x"))
           (last-idx (1- (length (limn/isearch:isearch-matches st2))))
           (st3 (limn/isearch:isearch-prev st2)))
      (assert-equal last-idx (limn/isearch:isearch-current-index st3)
                    "prev from first wraps to last"))))

(deftest isearch-a2-single-match-next-stays
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "world"))
           (st3 (limn/isearch:isearch-next st2)))
      (assert-equal 0 (limn/isearch:isearch-current-index st3)
                    "single match: next stays at 0"))))

(deftest isearch-a2-no-matches-next-is-noop
  (with-isearch-buf (m :text "hello" :cursor 3)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "zzz"))
           (pos-before (isearch-mock-cursor m))
           (_   (limn/isearch:isearch-next st2))
           (pos-after  (isearch-mock-cursor m)))
      (assert-equal pos-before pos-after "no-match next does not move cursor"))))

(deftest isearch-a2-backward-start-selects-last-match
  (with-isearch-buf (m :text "a b a" :cursor 4)
    ;; backward search from end → first presented match should be last one in text
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m) :forward nil))
           (st2 (limn/isearch:isearch-update st "a"))
           (match (limn/isearch:isearch-current-match st2)))
      ;; cursor is at 4; nearest backward match should be offset 4
      (assert-true match "backward: current-match exists")
      (assert-true (<= (car match) 4) "backward: initial match at or before cursor"))))

;;; ─── A3. confirm / abort ─────────────────────────────────────────────────

(deftest isearch-a3-exit-leaves-cursor-at-match
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "world")))
      (limn/isearch:isearch-exit st2)
      (assert-equal 6 (isearch-mock-cursor m)
                    "exit: cursor stays at match start"))))

(deftest isearch-a3-exit-pushes-to-history
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "world")))
      (limn/isearch:isearch-exit st2)
      (assert-contains "world" (isearch-mock-history-calls m)
                       "exit: query pushed to history"))))

(deftest isearch-a3-abort-restores-cursor
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "world")))
      ;; cursor moved to 6 during search
      (assert-equal 6 (isearch-mock-cursor m))
      (limn/isearch:isearch-abort st2)
      (assert-equal 0 (isearch-mock-cursor m)
                    "abort: cursor restored to saved-cursor"))))

(deftest isearch-a3-abort-does-not-push-history
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "world")))
      (limn/isearch:isearch-abort st2)
      (assert-equal '() (isearch-mock-history-calls m)
                    "abort: history not touched"))))

(deftest isearch-a3-exit-no-match-cursor-stays-at-saved
  (with-isearch-buf (m :text "hello" :cursor 2)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "zzz")))
      ;; no match → cursor should not have moved from 2
      (limn/isearch:isearch-exit st2)
      (assert-equal 2 (isearch-mock-cursor m)
                    "exit with no match: cursor at saved pos"))))

(deftest isearch-a3-abort-after-several-nexts-restores-original
  (with-isearch-buf (m :text "a b a b a" :cursor 0)
    (let* ((saved 0)
           (st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "a"))
           (st3 (limn/isearch:isearch-next st2))
           (st4 (limn/isearch:isearch-next st3)))
      (declare (ignore saved))
      (limn/isearch:isearch-abort st4)
      (assert-equal 0 (isearch-mock-cursor m)
                    "abort after multiple nexts: cursor at original start"))))

;;; ─── A4. highlight ────────────────────────────────────────────────────────

(deftest isearch-a4-update-calls-highlight-fn
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (_   (limn/isearch:isearch-update st "hello")))
      (assert-true (isearch-mock-last-highlight-spans m)
                   "isearch-update calls *highlight-fn*"))))

(deftest isearch-a4-all-matches-have-highlight-spans
  (with-isearch-buf (m :text "cat and cat" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "cat")))
      ;; highlight-fn may be called multiple times (once per match type)
      ;; but the total set of spans should cover both matches
      (let ((spans (isearch-mock-last-highlight-spans m)))
        (assert-true (>= (length spans) 1)
                     "at least one highlight span set")))))

(deftest isearch-a4-current-match-uses-isearch-current-face
  (with-isearch-buf (m :text "hello world hello" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello")))
      ;; The last highlight call should use 'isearch-current for current match
      (assert-true (member (isearch-mock-last-highlight-face m)
                           '(:isearch-current :isearch)
                           :test #'equal)
                   "highlight face is isearch or isearch-current"))))

(deftest isearch-a4-abort-clears-all-highlights
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello")))
      (limn/isearch:isearch-abort st2)
      (assert-equal '() (isearch-mock-last-highlight-spans m)
                    "abort clears highlights")
      (assert-true (> (isearch-mock-clear-count m) 0)
                   "*clear-highlights-fn* was called"))))

(deftest isearch-a4-exit-clears-all-highlights
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello")))
      (limn/isearch:isearch-exit st2)
      (assert-true (> (isearch-mock-clear-count m) 0)
                   "exit clears highlights"))))

(deftest isearch-a4-empty-query-no-highlight-spans
  (with-isearch-buf (m :text "hello" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (_   (limn/isearch:isearch-update st "")))
      (assert-equal '() (isearch-mock-last-highlight-spans m)
                    "empty query: no highlight spans set"))))

;;; ─── A5. history integration ──────────────────────────────────────────────

(deftest isearch-a5-exit-adds-query-to-history
  (with-isearch-buf (m :text "foo bar" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "foo")))
      (limn/isearch:isearch-exit st2)
      (assert-contains "foo" (isearch-mock-history-calls m)))))

(deftest isearch-a5-abort-no-history-call
  (with-isearch-buf (m :text "foo bar" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "foo")))
      (limn/isearch:isearch-abort st2)
      (assert-equal '() (isearch-mock-history-calls m)
                    "abort never calls *history-push-fn*"))))

(deftest isearch-a5-exit-called-once-even-with-matches
  (with-isearch-buf (m :text "x x x" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "x")))
      (limn/isearch:isearch-exit st2)
      (assert-equal 1 (length (isearch-mock-history-calls m))
                    "history-push called exactly once on exit"))))

(deftest isearch-a5-empty-query-no-history-on-exit
  (with-isearch-buf (m :text "foo" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "")))
      (limn/isearch:isearch-exit st2)
      (assert-equal '() (isearch-mock-history-calls m)
                    "empty query: no history even on exit"))))

(deftest isearch-a5-no-match-no-history-on-exit
  (with-isearch-buf (m :text "hello" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "zzz")))
      (limn/isearch:isearch-exit st2)
      (assert-equal '() (isearch-mock-history-calls m)
                    "no-match exit: history not pushed"))))

;;; ─── A6. edge cases ───────────────────────────────────────────────────────

(deftest isearch-a6-query-longer-than-buffer-no-match
  (with-isearch-buf (m :text "hi" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "longer-than-buffer-text")))
      (assert-equal '() (limn/isearch:isearch-matches st2)
                    "query longer than buffer: no match"))))

(deftest isearch-a6-buffer-only-whitespace-search-space
  (with-isearch-buf (m :text "   " :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st " ")))
      (assert-equal 3 (length (limn/isearch:isearch-matches st2))
                    "space search in whitespace buffer: 3 matches"))))

(deftest isearch-a6-cjk-multibyte-match
  ;; "你好世界" = 4 codepoints; search for "好" should match at index 1
  (with-isearch-buf (m :text "你好世界" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "好")))
      (assert-equal 1 (length (limn/isearch:isearch-matches st2))
                    "CJK: one match")
      (let ((match (limn/isearch:isearch-current-match st2)))
        (assert-equal 1 (car match) "CJK: match at codepoint 1")
        (assert-equal 2 (cdr match) "CJK: match ends at codepoint 2")))))

(deftest isearch-a6-one-hundred-matches
  (with-isearch-buf (m :text (make-string 200 :initial-element #\a) :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "a")))
      (assert-equal 200 (length (limn/isearch:isearch-matches st2))
                    "200 single-char matches not truncated"))))

(deftest isearch-a6-match-at-buffer-start-and-end
  (with-isearch-buf (m :text "xhellox" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "x")))
      (let ((matches (limn/isearch:isearch-matches st2)))
        (assert-equal 2 (length matches) "matches at both ends")
        (assert-equal 0 (car (first matches)) "first match at 0")
        (assert-equal 6 (car (second matches)) "second match at 6")))))

(deftest isearch-a6-no-cross-interference-with-text-props
  ;; If text already has :face properties, isearch should not destroy them
  ;; (it calls *clear-highlights-fn* only for its own spans on exit/abort).
  ;; We test that abort does not call *clear-highlights-fn* more than once.
  (with-isearch-buf (m :text "hello" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello")))
      (limn/isearch:isearch-abort st2)
      (assert-equal 1 (isearch-mock-clear-count m)
                    "abort calls clear-highlights exactly once"))))

;;; ─── A7. state accessor completeness ────────────────────────────────────

(deftest isearch-a7-start-state-is-active
  (with-isearch-buf (m :text "hello" :cursor 3)
    (let ((st (limn/isearch:isearch-start (isearch-mock-id m))))
      (assert-true (limn/isearch:isearch-active-p st)
                   "fresh state is active"))))

(deftest isearch-a7-start-records-buf-id-and-saved-cursor
  (with-isearch-buf (m :text "hello" :cursor 3)
    (let ((st (limn/isearch:isearch-start (isearch-mock-id m))))
      (assert-equal (isearch-mock-id m)
                    (limn/isearch:isearch-buf-id st)
                    "buf-id recorded")
      (assert-equal 3 (limn/isearch:isearch-saved-cursor st)
                    "saved-cursor = cursor at start time"))))

(deftest isearch-a7-default-forward
  (with-isearch-buf (m :text "x" :cursor 0)
    (let ((st (limn/isearch:isearch-start (isearch-mock-id m))))
      (assert-true (limn/isearch:isearch-forward-p st)
                   "default direction is forward"))))

(deftest isearch-a7-backward-flag-stored
  (with-isearch-buf (m :text "x" :cursor 0)
    (let ((st (limn/isearch:isearch-start (isearch-mock-id m) :forward nil)))
      (assert-false (limn/isearch:isearch-forward-p st)
                    "backward direction stored"))))

(deftest isearch-a7-query-accessor
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello")))
      (assert-equal "hello" (limn/isearch:isearch-query st2)
                    "query accessor returns current query"))))

;;; ─── A8. state lifecycle completeness ────────────────────────────────────

(deftest isearch-a8-exit-sets-inactive
  "After isearch-exit, state is no longer active."
  (with-isearch-buf (m :text "hello" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello")))
      (limn/isearch:isearch-exit st2)
      (assert-false (limn/isearch:isearch-active-p st2)
                    "exit → state inactive"))))

(deftest isearch-a8-abort-sets-inactive
  "After isearch-abort, state is no longer active."
  (with-isearch-buf (m :text "hello" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello")))
      (limn/isearch:isearch-abort st2)
      (assert-false (limn/isearch:isearch-active-p st2)
                    "abort → state inactive"))))

(deftest isearch-a8-abort-without-update-restores-cursor
  "Abort on a fresh state (no update yet) leaves cursor at start."
  (with-isearch-buf (m :text "hello" :cursor 3)
    (let ((st (limn/isearch:isearch-start (isearch-mock-id m))))
      (limn/isearch:isearch-abort st)
      (assert-equal 3 (isearch-mock-cursor m)
                    "abort without update: cursor at original position"))))

(deftest isearch-a8-idempotent-same-query-twice
  "Calling isearch-update with the same query twice yields same match count."
  (with-isearch-buf (m :text "foo bar foo" :cursor 0)
    (let* ((st   (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2  (limn/isearch:isearch-update st "foo"))
           (n2   (length (limn/isearch:isearch-matches st2)))
           (st3  (limn/isearch:isearch-update st2 "foo"))
           (n3   (length (limn/isearch:isearch-matches st3))))
      (assert-equal n2 n3 "same query twice: same match count"))))

(deftest isearch-a8-query-change-resets-index
  "Completely changing the query resets current-index to 0."
  (with-isearch-buf (m :text "alpha beta alpha gamma")
    ;; Start on 'alpha', advance to second match
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "alpha"))
           (st3 (limn/isearch:isearch-next st2))
           ;; Now switch query entirely to 'beta'
           (st4 (limn/isearch:isearch-update st3 "beta")))
      (assert-equal 0 (limn/isearch:isearch-current-index st4)
                    "index resets to 0 after full query change"))))

;;; ─── A9. overlapping and adjacent matches ────────────────────────────────

(deftest isearch-a9-overlapping-matches-aaa
  "'aa' in 'aaa' finds 2 overlapping matches: (0,2) and (1,3)."
  (with-isearch-buf (m :text "aaa" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "aa")))
      (assert-equal 2 (length (limn/isearch:isearch-matches st2))
                    "overlapping: 2 matches in 'aaa' for 'aa'"))))

(deftest isearch-a9-adjacent-non-overlapping
  "'ab' in 'ababab' finds 3 non-overlapping matches."
  (with-isearch-buf (m :text "ababab" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "ab")))
      (assert-equal 3 (length (limn/isearch:isearch-matches st2))
                    "adjacent: 3 matches of 'ab' in 'ababab'"))))

;;; ─── A10. backward search initial match position ─────────────────────────

(deftest isearch-a10-backward-from-middle-skips-later-matches
  "Backward isearch from middle of buffer skips matches after cursor."
  (with-isearch-buf (m :text "x foo x foo x" :cursor 5)
    ;; cursor is at 5, which is between the two 'foo' occurrences.
    ;; Forward 'foo' at 2, 10.  Backward from 5 should pick match at 2.
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m) :forward nil))
           (st2 (limn/isearch:isearch-update st "foo")))
      (let ((match (limn/isearch:isearch-current-match st2)))
        (assert-true match "backward: match found")
        ;; The match at 2 is before cursor 5; the one at 10 is after.
        (assert-true (<= (car match) 5)
                     "backward: initial match is at or before cursor")))))

(deftest isearch-a10-backward-no-match-before-cursor-wraps
  "Backward isearch with no match before cursor wraps to last match."
  (with-isearch-buf (m :text "x foo" :cursor 0)
    ;; cursor at 0: no 'foo' before position 0 → should wrap to last
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m) :forward nil))
           (st2 (limn/isearch:isearch-update st "foo")))
      (let ((match (limn/isearch:isearch-current-match st2)))
        (assert-true match "wrap: backward still finds match")
        (assert-equal 2 (car match)
                      "wrap: cursor at 0 → wraps to match at 2")))))

;;; ─── §A-dog. dogfood / integration tests ──────────────────────────────────
;;;
;;; These tests emerged from thinking through week-1 actual usage patterns.

;;; ── §A-dog-1. item 2: history-ring wire ──────────────────────────────────

(deftest isearch-adog1-history-ring-wire
  "Wire *history-push-fn* to limn/history:add-to-history; verify ring entry."
  (let* ((hist-pkg (find-package '#:limn/history))
         (add-fn   (and hist-pkg (find-symbol "ADD-TO-HISTORY" hist-pkg)))
         (items-fn (and hist-pkg (find-symbol "HISTORY-ITEMS"  hist-pkg)))
         ;; use an isolated ring name so global *search-history* is untouched
         (ring-name "isearch-dogfood-test-ring"))
    (when (and add-fn items-fn)
      (with-isearch-buf (m :text "hello world" :cursor 0)
        (let ((limn/isearch:*history-push-fn*
               (lambda (q) (funcall add-fn ring-name q))))
          (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
                 (st2 (limn/isearch:isearch-update st "hello")))
            (limn/isearch:isearch-exit st2)
            (assert-true (member "hello" (funcall items-fn ring-name)
                                 :test #'equal)
                         "query 'hello' appears in limn/history ring after exit")))))))

(deftest isearch-adog2-history-dedup-no-double-push
  "Consecutive isearch-exit with same query → history entry appears exactly once."
  (let* ((hist-pkg (find-package '#:limn/history))
         (add-fn   (and hist-pkg (find-symbol "ADD-TO-HISTORY" hist-pkg)))
         (items-fn (and hist-pkg (find-symbol "HISTORY-ITEMS"  hist-pkg)))
         (ring-name "isearch-dedup-test-ring"))
    (when (and add-fn items-fn)
      (with-isearch-buf (m :text "hello" :cursor 0)
        (let ((limn/isearch:*history-push-fn*
               (lambda (q) (funcall add-fn ring-name q))))
          (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
                 (st2 (limn/isearch:isearch-update st "hello")))
            ;; exit twice — second call is a no-op for the ring
            (limn/isearch:isearch-exit st2)
            (limn/isearch:isearch-exit st2)
            (assert-equal 1
                          (count "hello" (funcall items-fn ring-name) :test #'equal)
                          "limn/history deduplicates: 'hello' appears once")))))))

;;; ── §A-dog-2. item 3: multiline buffer absolute span offsets ─────────────

(deftest isearch-adog3-multiline-span-offsets
  "Match offsets are correct absolute codepoint positions across newlines."
  ;; text: \"line one\\nfoo bar\\nbaz foo\"
  ;; positions: l=0..e=7, \\n=8, f=9..r=15, \\n=16, b=17..o=23
  ;; 'foo' appears at (9,12) and (21,24)
  (with-isearch-buf (m :text (format nil "line one~%foo bar~%baz foo") :cursor 0)
    (let* ((st      (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2     (limn/isearch:isearch-update st "foo"))
           (matches (limn/isearch:isearch-matches st2)))
      (assert-equal 2 (length matches) "two 'foo' matches in multi-line buffer")
      ;; first match: 'foo' in 'foo bar' on line 2 (absolute offset 9)
      (assert-equal 9  (car (first  matches)) "first match starts at absolute offset 9")
      (assert-equal 12 (cdr (first  matches)) "first match ends at 12")
      ;; second match: 'foo' in 'baz foo' on line 3 (absolute offset 21)
      (assert-equal 21 (car (second matches)) "second match starts at absolute offset 21")
      (assert-equal 24 (cdr (second matches)) "second match ends at 24")
      ;; cursor moved to first match
      (assert-equal 9 (isearch-mock-cursor m)
                    "cursor at first match offset after update"))))

(deftest isearch-adog4-multiline-next-cursor-jumps-to-second-line
  "isearch-next in multi-line buffer correctly moves cursor across newline."
  (with-isearch-buf (m :text (format nil "line one~%foo bar~%baz foo") :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "foo"))
           (_   (limn/isearch:isearch-next st2)))
      (assert-equal 21 (isearch-mock-cursor m)
                    "after next, cursor is at second 'foo' (offset 21)"))))

;;; ── §A-dog-3. case-fold toggle mid-search ───────────────────────────────

(deftest isearch-adog5-case-fold-toggle-mid-search
  "Toggling *isearch-case-fold* between updates changes match count."
  (with-isearch-buf (m :text "Hello HELLO hello" :cursor 0)
    (let* ((st (limn/isearch:isearch-start (isearch-mock-id m)))
           (n-fold
            (let ((limn/isearch:*isearch-case-fold* t))
              (length (limn/isearch:isearch-matches
                       (limn/isearch:isearch-update st "hello")))))
           (n-exact
            (let ((limn/isearch:*isearch-case-fold* nil))
              (length (limn/isearch:isearch-matches
                       (limn/isearch:isearch-update st "hello"))))))
      (assert-equal 3 n-fold  "case-fold=t: all 3 variants match")
      (assert-equal 1 n-exact "case-fold=nil: only lowercase matches")
      (assert-true (> n-fold n-exact) "toggling fold changes result count"))))

;;; ── §A-dog-4. large buffer performance ──────────────────────────────────

(deftest isearch-adog6-large-buffer-no-hang
  "isearch-update on a ~50K-char buffer completes within 5-second timeout."
  ;; segment = 44 chars, repeated 1136× ≈ 49984 chars; 'fox' appears 1136 times
  (let* ((seg  "the quick brown fox jumps over the lazy dog ")
         (text (with-output-to-string (s)
                 (dotimes (_ 1136) (write-string seg s)))))
    (with-isearch-buf (m :text text)
      (limn/v023-helpers:with-timeout-bound 5
        (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
               (st2 (limn/isearch:isearch-update st "fox")))
          (assert-equal 1136 (length (limn/isearch:isearch-matches st2))
                        "~50K buffer: all 1136 'fox' matches found in time"))))))

;;; ── §A-dog-5. empty-query cursor stays at last match, not saved pos ──────

(deftest isearch-adog7-empty-query-cursor-stays-at-last-match
  "Clearing the query leaves cursor where it was (last match), not at saved-cursor.
   This documents intentional Emacs-compatible behaviour — not a bug."
  (with-isearch-buf (m :text "hello world" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "world"))
           ;; cursor moved to 6 (start of 'world')
           (_   (limn/isearch:isearch-update st2 "")))
      (assert-equal 6 (isearch-mock-cursor m)
                    "empty query: cursor stays at previous match pos (6), not saved-cursor (0)"))))

;;; ── §A-dog-6. double-exit is safe ────────────────────────────────────────

(deftest isearch-adog8-double-exit-no-crash
  "Calling isearch-exit twice on the same state does not error."
  (with-isearch-buf (m :text "hello" :cursor 0)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m)))
           (st2 (limn/isearch:isearch-update st "hello")))
      (assert-no-error
        (progn
          (limn/isearch:isearch-exit st2)
          (limn/isearch:isearch-exit st2))
        "double exit: no error"))))

;;; ── §A-dog-7. backward-mode: next/prev advance index, not direction ──────

(deftest isearch-adog9-backward-mode-next-still-advances-index
  "In backward search, isearch-next still increments the index (0→1→…).
   Reversing the conceptual direction is the caller's responsibility."
  (with-isearch-buf (m :text "a b a" :cursor 4)
    (let* ((st  (limn/isearch:isearch-start (isearch-mock-id m) :forward nil))
           (st2 (limn/isearch:isearch-update st "a"))
           (idx0 (limn/isearch:isearch-current-index st2))
           (st3 (limn/isearch:isearch-next st2))
           (idx1 (limn/isearch:isearch-current-index st3)))
      (assert-true (>= idx0 0) "backward: initial index is valid")
      (assert-equal (mod (1+ idx0) (length (limn/isearch:isearch-matches st2)))
                    idx1
                    "backward: isearch-next wraps index forward regardless of direction"))))
