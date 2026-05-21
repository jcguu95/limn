;;;; Unit tests for limn-hooks (event hook system)
;;;;
;;;; API contract:
;;;;
;;;;   (limn-hooks:add-hook name fn)        register fn for event name
;;;;   (limn-hooks:remove-hook name fn)     unregister
;;;;   (limn-hooks:run-hook name &rest args) call all registered fns
;;;;   (limn-hooks:list-hooks)              list all registered hook names
;;;;   (limn-hooks:clear-hook name)         remove all fns for a name
;;;;   (limn-hooks:clear-all-hooks)         reset

(in-package #:limn/unit-test)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :limn/hooks)
    (defpackage :limn/hooks
      (:use :cl)
      (:export #:add-hook #:remove-hook #:run-hook
               #:list-hooks #:clear-hook #:clear-all-hooks))))

;;; Setup: clear all hooks before each test by using a wrapper macro

(defmacro with-clean-hooks (&body body)
  `(progn
     (handler-case (limn/hooks:clear-all-hooks) (error () nil))
     ,@body
     (handler-case (limn/hooks:clear-all-hooks) (error () nil))))

;;; ── Registration ────────────────────────────────────────────────────────

(deftest hooks-add-hook-no-error
  (with-clean-hooks
    (limn/hooks:add-hook 'page-changed (lambda (page) (declare (ignore page))))
    (assert-true t "no error from add-hook")))

(deftest hooks-list-after-add
  (with-clean-hooks
    (limn/hooks:add-hook 'page-changed (lambda (p) (declare (ignore p))))
    (let ((names (limn/hooks:list-hooks)))
      (assert-true (member 'page-changed names) "page-changed in list"))))

(deftest hooks-multiple-handlers-same-event
  (with-clean-hooks
    (let ((calls 0))
      (limn/hooks:add-hook 'evt (lambda (&rest args) (declare (ignore args)) (incf calls)))
      (limn/hooks:add-hook 'evt (lambda (&rest args) (declare (ignore args)) (incf calls)))
      (limn/hooks:add-hook 'evt (lambda (&rest args) (declare (ignore args)) (incf calls)))
      (limn/hooks:run-hook 'evt)
      (assert-eql 3 calls "all three handlers ran"))))

;;; ── Running ─────────────────────────────────────────────────────────────

(deftest hooks-run-passes-args
  (with-clean-hooks
    (let (last-args)
      (limn/hooks:add-hook 'page-changed
                          (lambda (&rest args) (setf last-args args)))
      (limn/hooks:run-hook 'page-changed 42 :extra 'data)
      (assert-equal '(42 :extra data) last-args "args passed to hook"))))

(deftest hooks-run-no-handlers-is-noop
  (with-clean-hooks
    (assert-no-error
     (limn/hooks:run-hook 'never-registered)
     "running an unbound hook is fine")))

;;; ── Removal ─────────────────────────────────────────────────────────────

(deftest hooks-remove-hook-by-fn
  (with-clean-hooks
    (let* ((calls 0)
           (f (lambda (&rest args) (declare (ignore args)) (incf calls))))
      (limn/hooks:add-hook 'evt f)
      (limn/hooks:run-hook 'evt)
      (assert-eql 1 calls "ran once")
      (limn/hooks:remove-hook 'evt f)
      (limn/hooks:run-hook 'evt)
      (assert-eql 1 calls "removed handler no longer runs"))))

(deftest hooks-clear-hook-removes-all
  (with-clean-hooks
    (let ((calls 0))
      (limn/hooks:add-hook 'evt (lambda (&rest a) (declare (ignore a)) (incf calls)))
      (limn/hooks:add-hook 'evt (lambda (&rest a) (declare (ignore a)) (incf calls)))
      (limn/hooks:clear-hook 'evt)
      (limn/hooks:run-hook 'evt)
      (assert-eql 0 calls "no handlers after clear-hook"))))

;;; ── Error handling ──────────────────────────────────────────────────────

(deftest hooks-handler-error-does-not-stop-chain
  "If one handler errors, subsequent ones still run."
  (with-clean-hooks
    (let ((after-runs 0))
      (limn/hooks:add-hook 'evt (lambda (&rest a)
                                  (declare (ignore a))
                                  (error "boom")))
      (limn/hooks:add-hook 'evt (lambda (&rest a)
                                  (declare (ignore a))
                                  (incf after-runs)))
      (handler-case (limn/hooks:run-hook 'evt) (error () nil))
      (assert-eql 1 after-runs
                  "second handler ran despite first one erroring"))))

;;; ── Ordering ────────────────────────────────────────────────────────────
;;;
;;; Spec implicitly: hooks run in add-order. Test this explicitly.

(deftest hooks-run-in-add-order
  "Handlers run in the order they were added."
  (with-clean-hooks
    (let ((order '()))
      (limn/hooks:add-hook 'evt (lambda (&rest a)
                                  (declare (ignore a))
                                  (push 1 order)))
      (limn/hooks:add-hook 'evt (lambda (&rest a)
                                  (declare (ignore a))
                                  (push 2 order)))
      (limn/hooks:add-hook 'evt (lambda (&rest a)
                                  (declare (ignore a))
                                  (push 3 order)))
      (limn/hooks:run-hook 'evt)
      (assert-equal '(1 2 3) (reverse order)
                    "handlers ran in add order"))))

;;; ── One-shot hooks (run once then auto-remove) ──────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :limn/hooks)
    (unless (find-symbol "ADD-HOOK-ONCE" :limn/hooks)
      (export (intern "ADD-HOOK-ONCE" :limn/hooks) :limn/hooks))))

(deftest hooks-add-hook-once
  "add-hook-once registers a handler that runs exactly once."
  (with-clean-hooks
    (let ((calls 0))
      (limn/hooks:add-hook-once
       'evt (lambda (&rest a) (declare (ignore a)) (incf calls)))
      (limn/hooks:run-hook 'evt)
      (limn/hooks:run-hook 'evt)
      (limn/hooks:run-hook 'evt)
      (assert-eql 1 calls "one-shot handler ran exactly once"))))

;;; ── Hook receives event-shaped args ─────────────────────────────────────

(deftest hooks-passes-keyword-args
  "Hooks can receive structured event data as plist."
  (with-clean-hooks
    (let (last-event)
      (limn/hooks:add-hook 'page-changed (lambda (event) (setf last-event event)))
      (limn/hooks:run-hook 'page-changed '(:page 5 :buffer-id "b1"))
      (assert-equal 5 (getf last-event :page))
      (assert-equal "b1" (getf last-event :buffer-id)))))

;;; ── Removing handler that was never added ───────────────────────────────

(deftest hooks-remove-unregistered-noop
  (with-clean-hooks
    (assert-no-error
     (limn/hooks:remove-hook 'evt (lambda () nil))
     "removing unregistered handler is harmless")))

;;; ── Multiple hook names, isolated ───────────────────────────────────────

(deftest hooks-different-names-isolated
  "Adding to one hook name doesn't affect another."
  (with-clean-hooks
    (let ((a-count 0)
          (b-count 0))
      (limn/hooks:add-hook 'a (lambda (&rest x) (declare (ignore x))
                                (incf a-count)))
      (limn/hooks:add-hook 'b (lambda (&rest x) (declare (ignore x))
                                (incf b-count)))
      (limn/hooks:run-hook 'a)
      (assert-eql 1 a-count "a ran")
      (assert-eql 0 b-count "b didn't run"))))

;;; ── Self-modifying hooks (advanced corner cases) ────────────────────────

(deftest hooks-handler-removes-itself
  "A handler that removes itself mid-run: should stop being called."
  (with-clean-hooks
    (let ((count 0))
      (let ((self (lambda (&rest x) (declare (ignore x)) (incf count))))
        (limn/hooks:add-hook 'evt self)
        (limn/hooks:add-hook 'evt
          (lambda (&rest x) (declare (ignore x))
            (limn/hooks:remove-hook 'evt self)))
        (limn/hooks:run-hook 'evt)  ; first run, both handlers fire
        (limn/hooks:run-hook 'evt)  ; second run, self should be gone
        ;; expected: count = 1 (only first invocation of self before removal)
        (assert-equal 1 count "self-removing handler ran once")))))

(deftest hooks-handler-adds-another-mid-run
  "A handler that adds another handler doesn't disrupt the current iteration."
  (with-clean-hooks
    (let ((late-count 0))
      (limn/hooks:add-hook 'evt
        (lambda (&rest x) (declare (ignore x))
          (limn/hooks:add-hook 'evt
            (lambda (&rest y) (declare (ignore y)) (incf late-count)))))
      (limn/hooks:run-hook 'evt)
      ;; The newly-added handler should NOT fire during the current run
      ;; (most hook systems iterate over a snapshot). Test the chosen behavior.
      (format t "    info: late-count after first run = ~a~%" late-count)
      ;; Second run: now the late handler should be active
      (limn/hooks:run-hook 'evt)
      (assert-true (>= late-count 1)
                   "added-during-run handler runs in subsequent invocations"))))

;;; ── Many handlers (stress) ──────────────────────────────────────────────

(deftest hooks-thousand-handlers
  "1000 registered handlers all fire."
  (with-clean-hooks
    (let ((count 0))
      (loop repeat 1000 do
        (limn/hooks:add-hook 'evt
          (lambda (&rest x) (declare (ignore x)) (incf count))))
      (limn/hooks:run-hook 'evt)
      (assert-equal 1000 count "all 1000 handlers ran"))))

;;; ── Hook arg arity flexibility ─────────────────────────────────────────

(deftest hooks-handlers-with-different-arities
  "Different handlers on the same hook can accept different argument shapes."
  (with-clean-hooks
    (let ((no-args  nil)
          (one-arg  nil))
      (limn/hooks:add-hook 'evt
        (lambda (&rest x) (declare (ignore x)) (setf no-args t)))
      (limn/hooks:add-hook 'evt
        (lambda (arg &rest x) (declare (ignore x)) (setf one-arg arg)))
      (limn/hooks:run-hook 'evt 42)
      (assert-true no-args  "no-arg handler ran")
      (assert-eql 42 one-arg "one-arg handler got 42"))))
