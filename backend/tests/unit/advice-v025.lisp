;;;; v0.25 §F — advice system RED tests  (~17 tests)
;;;;
;;;; Tests cover: before/after/around/override/:filter-args/:filter-return,
;;;; ordering of multiple advice, remove, and advice-mapc.
;;;; Follows Emacs nadvice semantics exactly.
;;;; All RED until limn/advice is implemented.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/advice)
    (make-package '#:limn/advice :use '(#:cl)))
  (dolist (sym '("ADVICE-ADD" "ADVICE-REMOVE" "ADVICE-MAPC"))
    (let ((s (intern sym '#:limn/advice)))
      (export s '#:limn/advice))))

(in-package #:limn/unit-test)

;;; ─── helpers ──────────────────────────────────────────────────────
;;; Each test defines its own target function so tests don't interfere.

(defmacro with-clean-advice (fn-name &body body)
  "Run BODY then remove all advice from FN-NAME."
  `(unwind-protect
       (progn ,@body)
     (limn/advice:advice-mapc
      (lambda (f _where) (limn/advice:advice-remove ',fn-name f))
      ',fn-name)))

;;; ─── F1. :before ──────────────────────────────────────────────────

(defun advice-target-before (x) (* x 2))

(deftest advice-f1-before-runs-before-original
  (let ((log '()))
    (with-clean-advice advice-target-before
      (limn/advice:advice-add 'advice-target-before :before
                              (lambda (&rest _) (push :before log)))
      (advice-target-before 3)
      (assert-equal '(:before) log "before advice must fire"))))

(deftest advice-f1-before-does-not-change-return-value
  (with-clean-advice advice-target-before
    (limn/advice:advice-add 'advice-target-before :before
                            (lambda (&rest _) 999))
    (assert-equal 6 (advice-target-before 3)
                  ":before must not affect return value")))

;;; ─── F2. :after ───────────────────────────────────────────────────

(defun advice-target-after (x) (+ x 1))

(deftest advice-f2-after-runs-after-original
  (let ((log '()))
    (with-clean-advice advice-target-after
      (limn/advice:advice-add 'advice-target-after :after
                              (lambda (&rest _) (push :after log)))
      (advice-target-after 5)
      (assert-equal '(:after) log ":after advice must fire"))))

(deftest advice-f2-after-does-not-change-return-value
  (with-clean-advice advice-target-after
    (limn/advice:advice-add 'advice-target-after :after
                            (lambda (&rest _) :ignored))
    (assert-equal 6 (advice-target-after 5)
                  ":after must not affect return value")))

;;; ─── F3. :around ──────────────────────────────────────────────────

(defun advice-target-around (x) (* x 3))

(deftest advice-f3-around-can-call-original
  (with-clean-advice advice-target-around
    (limn/advice:advice-add 'advice-target-around :around
                            (lambda (orig &rest args)
                              (apply orig args)))
    (assert-equal 9 (advice-target-around 3)
                  ":around calling orig must return original value")))

(deftest advice-f3-around-can-modify-result
  (with-clean-advice advice-target-around
    (limn/advice:advice-add 'advice-target-around :around
                            (lambda (orig &rest args)
                              (+ 100 (apply orig args))))
    (assert-equal 109 (advice-target-around 3)
                  ":around can add 100 to result")))

(deftest advice-f3-around-can-skip-original
  (with-clean-advice advice-target-around
    (limn/advice:advice-add 'advice-target-around :around
                            (lambda (_orig &rest _args) :skipped))
    (assert-eq :skipped (advice-target-around 3)
               ":around can prevent original from running")))

;;; ─── F4. :override ────────────────────────────────────────────────

(defun advice-target-override (x) x)

(deftest advice-f4-override-replaces-original
  (with-clean-advice advice-target-override
    (limn/advice:advice-add 'advice-target-override :override
                            (lambda (&rest _) :overridden))
    (assert-eq :overridden (advice-target-override 42)
               ":override should completely replace original")))

;;; ─── F5. :filter-args / :filter-return ───────────────────────────

(defun advice-target-filter (x) (* x 2))

(deftest advice-f5-filter-args-modifies-args
  (with-clean-advice advice-target-filter
    (limn/advice:advice-add 'advice-target-filter :filter-args
                            (lambda (args) (list (* 10 (first args)))))
    (assert-equal 20 (advice-target-filter 1)
                  ":filter-args 1→10, then *2 = 20")))

(deftest advice-f5-filter-return-modifies-result
  (with-clean-advice advice-target-filter
    (limn/advice:advice-add 'advice-target-filter :filter-return
                            (lambda (ret) (+ ret 1000)))
    (assert-equal 1004 (advice-target-filter 2)
                  ":filter-return adds 1000 to result (2*2+1000)")))

;;; ─── F6. ordering of multiple advice ─────────────────────────────

(defun advice-target-order (x) x)

(deftest advice-f6-multiple-before-fifo-order
  (let ((log '()))
    (with-clean-advice advice-target-order
      (limn/advice:advice-add 'advice-target-order :before
                              (lambda (&rest _) (push 1 log)))
      (limn/advice:advice-add 'advice-target-order :before
                              (lambda (&rest _) (push 2 log)))
      (advice-target-order 0)
      ;; Emacs: later-added :before runs first (innermost)
      (assert-equal '(1 2) (reverse log)
                    "before advice fires in add-order"))))

;;; ─── F7. advice-remove / advice-mapc ─────────────────────────────

(defun advice-target-remove (x) x)

(deftest advice-f7-advice-remove-removes
  (with-clean-advice advice-target-remove
    (let ((fired nil)
          (adv (lambda (&rest _) (setf fired t))))
      (limn/advice:advice-add 'advice-target-remove :before adv)
      (limn/advice:advice-remove 'advice-target-remove adv)
      (advice-target-remove 1)
      (assert-false fired "removed advice must not fire"))))

(deftest advice-f7-remove-nonexistent-no-error
  (assert-no-error
    (limn/advice:advice-remove 'advice-target-remove
                               (lambda () :phantom))
    "removing absent advice should not signal an error"))

(deftest advice-f7-advice-mapc-iterates-all
  (with-clean-advice advice-target-remove
    (let ((count 0)
          (a1 (lambda (&rest _) nil))
          (a2 (lambda (&rest _) nil)))
      (limn/advice:advice-add 'advice-target-remove :before a1)
      (limn/advice:advice-add 'advice-target-remove :after  a2)
      (limn/advice:advice-mapc
       (lambda (_fn _where) (incf count))
       'advice-target-remove)
      (assert-equal 2 count "mapc should visit all 2 advice"))))
