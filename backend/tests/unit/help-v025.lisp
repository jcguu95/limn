;;;; v0.25 §E — help / describe RED tests  (~13 tests)
;;;;
;;;; Tests cover: describe-function/variable (content, *Help* buffer),
;;;; describe-key (simple and prefix-chain), describe-mode, apropos.
;;;; All RED until limn/help is implemented.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/help)
    (make-package '#:limn/help :use '(#:cl)))
  (dolist (sym '("DESCRIBE-FUNCTION" "DESCRIBE-VARIABLE"
                 "DESCRIBE-KEY" "DESCRIBE-MODE"
                 "APROPOS" "APROPOS-COMMAND" "APROPOS-VARIABLE"
                 "HELP-BUFFER-CONTENTS"))
    (let ((s (intern sym '#:limn/help)))
      (export s '#:limn/help))))

(in-package #:limn/unit-test)

;;; ─── E1. describe-function ────────────────────────────────────────

(defun %test-documented-fn ()
  "A function with a docstring, used by help tests."
  42)

(deftest help-e1-describe-function-returns-content
  (let ((content (limn/help:describe-function '%test-documented-fn)))
    (assert-true (stringp content)
                 "describe-function should return a string")))

(deftest help-e1-describe-function-includes-docstring
  (let ((content (limn/help:describe-function '%test-documented-fn)))
    (assert-true (search "A function with a docstring" content)
                 "output should include the function's docstring")))

(deftest help-e1-describe-function-includes-name
  (let ((content (limn/help:describe-function '%test-documented-fn)))
    (assert-true (search "%TEST-DOCUMENTED-FN" (string-upcase content))
                 "output should include the function name")))

(deftest help-e1-describe-function-undefined-signals
  (assert-error error
    (limn/help:describe-function 'limn-help-test--no-such-fn-xyz)
    "describe-function on undefined symbol should signal error"))

;;; ─── E2. describe-variable ────────────────────────────────────────

(defvar *help-test-var* 99 "A variable for help tests.")

(deftest help-e2-describe-variable-includes-value
  (let ((content (limn/help:describe-variable '*help-test-var*)))
    (assert-true (search "99" content)
                 "describe-variable should show current value")))

(deftest help-e2-describe-variable-includes-docstring
  (let ((content (limn/help:describe-variable '*help-test-var*)))
    (assert-true (search "A variable for help tests" content)
                 "describe-variable should show docstring")))

;;; ─── E3. describe-key ─────────────────────────────────────────────

(deftest help-e3-describe-key-simple-binding
  ;; Assumes describe-key queries the live keymap system (limn/keys).
  ;; Returns a string; does not need a running Qt process (pure Lisp).
  (let ((content (limn/help:describe-key "C-x C-f")))
    (assert-true (stringp content)
                 "describe-key should return a string")))

(deftest help-e3-describe-key-undefined
  (let ((content (limn/help:describe-key "C-M-F24")))
    (assert-true (search "not defined" (string-downcase content))
                 "unbound key should say 'not defined'")))

;;; ─── E4. describe-mode ────────────────────────────────────────────

(deftest help-e4-describe-mode-returns-string
  (let ((content (limn/help:describe-mode)))
    (assert-true (stringp content)
                 "describe-mode should return a string")))

;;; ─── E5. apropos ──────────────────────────────────────────────────

(defun limn-help-test--apropos-target () "a test function" nil)
(defvar *limn-help-test--apropos-var* "found")

(deftest help-e5-apropos-finds-fbound
  (let ((results (limn/help:apropos "limn-help-test--apropos")))
    (assert-contains 'limn-help-test--apropos-target results
                     "apropos should find fbound symbol")))

(deftest help-e5-apropos-finds-bound-variable
  (let ((results (limn/help:apropos "limn-help-test--apropos")))
    (assert-contains '*limn-help-test--apropos-var* results
                     "apropos should find bound variable")))

(deftest help-e5-apropos-command-filters-to-commands
  ;; apropos-command returns only interactive commands
  (let ((results (limn/help:apropos-command "limn-help-test")))
    (assert-false (find '*limn-help-test--apropos-var* results)
                  "apropos-command must not return variables")))
