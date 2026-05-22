;;;; Unit tests for limn/cmd — defcommand + interactive (SPEC §9.2).
;;;;
;;;; Every test is RED until v0.7 implements limn-cmd.lisp.
;;;;
;;;; The idea (SPEC §9.2):
;;;;
;;;;   (defcommand my-search (:interactive "sSearch: " :mode pdf-mode)
;;;;     (lambda (query) ...))
;;;;
;;;; - defcommand registers a NAMED command with its interactive spec
;;;; - find-command retrieves it
;;;; - call-interactively does the spec-driven I/O and invokes the body
;;;;
;;;; For unit tests we mock the minibuffer interaction with a per-test
;;;; "what would the user type" override.

(in-package #:limn/unit-test)

(deftest test-defcommand-registers-and-finds
  (limn/cmd:defcommand my-noop (:interactive nil)
    (lambda () :noop-result))
  (let ((c (limn/cmd:find-command 'my-noop)))
    (assert-true c "find-command returns the registered command")
    (assert-equal 'my-noop (limn/cmd:command-name c))
    (assert-equal nil (limn/cmd:command-spec c))))

(deftest test-defcommand-records-mode
  (limn/cmd:defcommand my-search (:interactive "sSearch: " :mode pdf-mode)
    (lambda (query) (declare (ignore query)) :ok))
  (let ((c (limn/cmd:find-command 'my-search)))
    (assert-equal "sSearch: " (limn/cmd:command-spec c))
    (assert-equal 'pdf-mode   (limn/cmd:command-mode c))))

(deftest test-call-interactively-no-input
  "Command with no interactive spec runs body with no args."
  (limn/cmd:defcommand my-noop (:interactive nil)
    (lambda () 42))
  (assert-equal 42 (limn/cmd:call-interactively 'my-noop)))

(deftest test-call-interactively-string-spec
  "Command with 'sPrompt: ' spec reads a string and passes it to body.
   Tests provide the 'user input' via a parameter override on
   limn/cmd:*minibuffer-read* (the indirection the framework uses to
   talk to the minibuffer)."
  (limn/cmd:defcommand echo-thrice (:interactive "sQuery: ")
    (lambda (q) (concatenate 'string q q q)))
  (let ((limn/cmd::*minibuffer-read* (lambda (prompt)
                                       (declare (ignore prompt))
                                       "ha")))
    (assert-equal "hahaha" (limn/cmd:call-interactively 'echo-thrice))))

(deftest test-call-interactively-prefix-arg
  "Spec 'p' receives a numeric prefix arg."
  (limn/cmd:defcommand jump-page-by (:interactive "p")
    (lambda (n) (* n 10)))
  (let ((limn/cmd::*prefix-arg* 5))
    (assert-equal 50 (limn/cmd:call-interactively 'jump-page-by))))

(deftest test-call-interactively-unknown-command-errors
  (assert-error error
    (limn/cmd:call-interactively 'definitely-not-defined-9999)))
