;;;; v0.25 §C — completion / minibuffer RED tests  (~18 tests)
;;;;
;;;; Tests cover: completing-read with list/hash/function collections,
;;;; completion styles, predicate filtering, history recording,
;;;; cancellation via quit condition, and read-from-minibuffer primitives.
;;;;
;;;; Qt-tier (actual minibuffer widget focus) is tested in OS-tier batch.
;;;; These unit tests exercise the pure-Lisp matching/selection logic.
;;;; All RED until limn/completion is implemented.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/completion)
    (make-package '#:limn/completion :use '(#:cl)))
  (dolist (sym '("COMPLETING-READ"
                 "READ-FROM-MINIBUFFER"
                 "MINIBUFFER-PROMPT" "MINIBUFFER-CONTENTS"
                 "MINIBUFFER-COMPLETION-HELP"
                 "*COMPLETION-STYLES*"
                 "COMPLETE-WITH-STYLES"
                 "QUIT-MINIBUFFER"))
    (let ((s (intern sym '#:limn/completion)))
      (export s '#:limn/completion))))

(in-package #:limn/unit-test)

;;; completing-read in unit tests runs in "batch" mode: given an
;;; :initial-input it returns the best match without user interaction.
;;; This lets us test matching logic without Qt.

;;; ─── C1. completing-read — list collection ────────────────────────

(deftest completion-c1-list-exact-match
  (let ((result (limn/completion:completing-read
                 "Pick: " '("alpha" "beta" "gamma")
                 :initial-input "alpha" :require-match t)))
    (assert-equal "alpha" result)))

(deftest completion-c1-list-prefix-match
  (let ((result (limn/completion:completing-read
                 "Pick: " '("alpha" "beta" "gamma")
                 :initial-input "alp" :require-match t)))
    (assert-equal "alpha" result "prefix 'alp' should complete to 'alpha'")))

(deftest completion-c1-empty-input-returns-default
  (let ((result (limn/completion:completing-read
                 "Pick: " '("alpha" "beta")
                 :initial-input "" :default "beta" :require-match nil)))
    (assert-equal "beta" result "empty input with :default returns default")))

(deftest completion-c1-require-match-rejects-invalid
  (assert-error error
    (limn/completion:completing-read
     "Pick: " '("alpha" "beta")
     :initial-input "zzz" :require-match t)
    "require-match with no match should signal error"))

;;; ─── C2. completing-read — hash / function collection ────────────

(deftest completion-c2-hash-table-collection
  (let ((table (make-hash-table :test 'equal)))
    (setf (gethash "one" table) t
          (gethash "two" table) t
          (gethash "three" table) t)
    (let ((result (limn/completion:completing-read
                   "Number: " table
                   :initial-input "tw" :require-match t)))
      (assert-equal "two" result))))

(deftest completion-c2-function-collection
  (let ((result (limn/completion:completing-read
                 "Pick: "
                 (lambda (input _pred _flag)
                   (remove-if-not (lambda (s) (search input s))
                                  '("foo" "foobar" "baz")))
                 :initial-input "foo" :require-match t)))
    (assert-true (member result '("foo" "foobar") :test #'equal)
                 "function collection should work")))

;;; ─── C3. completion styles ────────────────────────────────────────

(deftest completion-c3-substring-style
  (let ((limn/completion:*completion-styles* '(substring)))
    (let ((matches (limn/completion:complete-with-styles
                    "bar" '("foobar" "baz" "rebar"))))
      (assert-contains "foobar" matches)
      (assert-contains "rebar"  matches)
      (assert-false (find "baz" matches :test #'equal)))))

(deftest completion-c3-prefix-style
  (let ((limn/completion:*completion-styles* '(prefix)))
    (let ((matches (limn/completion:complete-with-styles
                    "foo" '("foobar" "baz" "food"))))
      (assert-contains "foobar" matches)
      (assert-contains "food"   matches)
      (assert-false (find "baz" matches :test #'equal)))))

(deftest completion-c3-flex-style
  (let ((limn/completion:*completion-styles* '(flex)))
    ;; flex: chars of input appear in order but not necessarily adjacent
    (let ((matches (limn/completion:complete-with-styles
                    "fb" '("foobar" "baz" "fab"))))
      (assert-contains "foobar" matches "fb flex-matches foobar")
      (assert-contains "fab"    matches "fb flex-matches fab"))))

;;; ─── C4. predicate filtering ──────────────────────────────────────

(deftest completion-c4-predicate-filters-candidates
  (let ((result (limn/completion:completing-read
                 "Pick: " '("alpha" "apple" "beta")
                 :predicate (lambda (s) (char= (char s 0) #\a))
                 :initial-input "alp" :require-match t)))
    (assert-equal "alpha" result))
  (assert-error error
    (limn/completion:completing-read
     "Pick: " '("alpha" "apple" "beta")
     :predicate (lambda (s) (char= (char s 0) #\b))
     :initial-input "alp" :require-match t)
    "predicate filtering 'alp' with only-b → no match → error"))

;;; ─── C5. annotation-function ──────────────────────────────────────

(deftest completion-c5-annotation-function-called
  (let ((annotated '()))
    (limn/completion:completing-read
     "Pick: " '("alpha" "beta")
     :annotation-function (lambda (s) (push s annotated) nil)
     :initial-input "")
    (assert-true (> (length annotated) 0)
                 "annotation-function should be called for each candidate")))

;;; ─── C6. history integration ──────────────────────────────────────

(deftest completion-c6-selection-added-to-history
  (let ((hist-name 'test-completion-hist))
    (limn/completion:completing-read
     "Pick: " '("alpha" "beta")
     :initial-input "alpha" :history hist-name :require-match t)
    ;; Check limn/history if loaded; otherwise verify via completing-read :history
    (when (find-package '#:limn/history)
      (let ((items (limn/history:history-items hist-name)))
        (assert-contains "alpha" items
                         "selected item should be in the history ring")))))

;;; ─── C7. quit / cancellation ──────────────────────────────────────

(deftest completion-c7-quit-minibuffer-signals-quit
  ;; quit-minibuffer should raise a condition compatible with C-g semantics
  (assert-error error
    (limn/completion:quit-minibuffer)
    "quit-minibuffer should signal a condition"))

;;; ─── C8. read-from-minibuffer primitives ─────────────────────────

(deftest completion-c8-read-from-minibuffer-returns-string
  (let ((result (limn/completion:read-from-minibuffer
                 "Prompt: " :initial-contents "prefilled")))
    (assert-true (stringp result)
                 "read-from-minibuffer should return a string")
    (assert-equal "prefilled" result
                  "initial-contents should be returned when no interaction")))

(deftest completion-c8-minibuffer-prompt-stored
  (limn/completion:read-from-minibuffer "TestPrompt: ")
  (let ((p (limn/completion:minibuffer-prompt)))
    (assert-true (search "TestPrompt" p)
                 "minibuffer-prompt should reflect the last prompt used")))
