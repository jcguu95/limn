;;;; Unit tests for limn-undo (undo tree, not linear undo)
;;;;
;;;; API contract specified here:
;;;;
;;;;   (limn-undo:make-tree)
;;;;     → new undo tree with one root node
;;;;
;;;;   (limn-undo:push-state tree state)
;;;;     → record a new state, makes a child of current node, moves current
;;;;
;;;;   (limn-undo:undo tree)
;;;;     → move current pointer to parent, return that node's state, or nil
;;;;
;;;;   (limn-undo:redo tree)
;;;;     → move current pointer to current's "latest child" branch
;;;;
;;;;   (limn-undo:switch-branch tree direction)
;;;;     → if current node has siblings (alt branches), switch to neighbor
;;;;
;;;;   (limn-undo:current tree)
;;;;     → state of currently active node
;;;;
;;;;   (limn-undo:tree-shape tree)
;;;;     → list of (state . children-list) recursively, for visualization

(in-package #:limn/unit-test)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :limn/undo)
    (defpackage :limn/undo
      (:use :cl)
      (:export #:make-tree #:push-state #:undo #:redo
               #:switch-branch #:current #:tree-shape
               #:tree-p))))

;;; ── Tree creation ───────────────────────────────────────────────────────

(deftest undo-make-tree-creates-empty-tree
  (let ((tree (limn/undo:make-tree)))
    (assert-true tree)
    (assert-true (limn/undo:tree-p tree))))

(deftest undo-empty-tree-undo-returns-nil
  (let ((tree (limn/undo:make-tree)))
    (assert-eq nil (limn/undo:undo tree)
               "undo on empty tree returns nil")))

;;; ── Linear undo / redo ──────────────────────────────────────────────────

(deftest undo-push-and-current
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :state-a)
    (assert-eq :state-a (limn/undo:current tree))))

(deftest undo-push-then-undo
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :a)
    (limn/undo:push-state tree :b)
    (assert-eq :b (limn/undo:current tree))
    (limn/undo:undo tree)
    (assert-eq :a (limn/undo:current tree))))

(deftest undo-redo-restores
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :a)
    (limn/undo:push-state tree :b)
    (limn/undo:undo tree)
    (assert-eq :a (limn/undo:current tree))
    (limn/undo:redo tree)
    (assert-eq :b (limn/undo:current tree))))

(deftest undo-redo-without-undo-is-noop
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :a)
    (let ((before (limn/undo:current tree)))
      (limn/undo:redo tree)
      (assert-eq before (limn/undo:current tree)
                 "redo with no future is noop"))))

;;; ── Branching ───────────────────────────────────────────────────────────

(deftest undo-branch-on-new-action-after-undo
  "Pushing a new state after undo creates a branch (doesn't overwrite)."
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :a)
    (limn/undo:push-state tree :b)
    (limn/undo:undo tree)            ; back to :a
    (limn/undo:push-state tree :c)   ; branch from :a
    (assert-eq :c (limn/undo:current tree))
    ;; original :b should still be reachable via switch-branch
    (limn/undo:undo tree)            ; back to :a
    (limn/undo:switch-branch tree :left)
    (limn/undo:redo tree)
    (assert-eq :b (limn/undo:current tree)
               ":b still reachable via the alt branch")))

(deftest undo-deep-branches
  "Multiple branchings at different depths preserve all history."
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :a)
    (limn/undo:push-state tree :b)
    (limn/undo:push-state tree :c)
    ;; Linear: nil → a → b → c
    (limn/undo:undo tree)            ; b
    (limn/undo:undo tree)            ; a
    (limn/undo:push-state tree :d)   ; branch from a: a → d
    (limn/undo:push-state tree :e)   ; a → d → e
    (assert-eq :e (limn/undo:current tree))
    ;; Walk back up: e → d → a → nil
    (limn/undo:undo tree)
    (assert-eq :d (limn/undo:current tree))
    (limn/undo:undo tree)
    (assert-eq :a (limn/undo:current tree))))

;;; ── Tree shape (for visualization) ──────────────────────────────────────

(deftest undo-tree-shape-empty
  (let ((tree (limn/undo:make-tree)))
    (let ((shape (limn/undo:tree-shape tree)))
      (assert-true (or (null shape) (listp shape))
                   "tree-shape returns nil or list"))))

(deftest undo-tree-shape-linear
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :a)
    (limn/undo:push-state tree :b)
    (let ((shape (limn/undo:tree-shape tree)))
      ;; Whatever the exact format, it should be non-empty and reflect the path.
      (assert-true shape "tree-shape non-nil after pushes"))))

;;; ── Real-state values ──────────────────────────────────────────────────
;;; Earlier tests used keyword symbols (:a, :b). Real Limn states are
;;; plists like (:page 5 :zoom 1.5 :offset-y 234.0). Verify these work.

(deftest undo-state-as-plist
  "States can be arbitrary Lisp values, including plists."
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree '(:page 0 :zoom 1.0))
    (limn/undo:push-state tree '(:page 5 :zoom 2.0))
    (let ((cur (limn/undo:current tree)))
      (assert-equal 5   (getf cur :page))
      (assert-equal 2.0 (getf cur :zoom)))))

(deftest undo-state-large-payload
  "States with large payloads (e.g. capturing buffer-list snapshots)."
  (let ((tree (limn/undo:make-tree))
        (big  (loop for i below 1000 collect (list :id i))))
    (limn/undo:push-state tree big)
    (assert-equal 1000 (length (limn/undo:current tree)))))

;;; ── Cross-branch redo ──────────────────────────────────────────────────

(deftest undo-cross-branch-via-switch-branch
  "After branching, switch-branch moves to the alternative branch."
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :a)
    (limn/undo:push-state tree :b)   ; a → b
    (limn/undo:undo tree)             ; back to a, b is "future"
    (limn/undo:push-state tree :c)   ; branch from a: a → c (b is now sibling)
    (assert-eq :c (limn/undo:current tree))
    (limn/undo:undo tree)             ; back to a
    ;; switch to sibling branch (which contains :b)
    (limn/undo:switch-branch tree :left)
    (limn/undo:redo tree)
    (assert-eq :b (limn/undo:current tree)
               "switch-branch + redo reaches :b on the other branch")))

;;; ── Memory bounds: very deep history ───────────────────────────────────

(deftest undo-deep-history
  "Pushing 1000 states does not stack-overflow or otherwise fail."
  (let ((tree (limn/undo:make-tree)))
    (loop for i from 1 to 1000 do
      (limn/undo:push-state tree i))
    (assert-equal 1000 (limn/undo:current tree)
                  "deep history accessible")))

;;; ── No-op behavior ─────────────────────────────────────────────────────

(deftest undo-undo-at-root-no-error
  "Undo at the root (no parent) returns nil but doesn't error."
  (let ((tree (limn/undo:make-tree)))
    (assert-no-error (limn/undo:undo tree)
                     "undo at root no-error")))

(deftest undo-redo-at-leaf-no-error
  "Redo at a leaf (no children) returns nil but doesn't error."
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :only)
    (assert-no-error (limn/undo:redo tree)
                     "redo at leaf no-error")))

;;; ── State equality / re-pushing identical state ─────────────────────────

(deftest undo-push-identical-state
  "Pushing the same value twice creates two distinct nodes."
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :same)
    (limn/undo:push-state tree :same)
    (limn/undo:undo tree)
    (limn/undo:undo tree)
    ;; should be at root (or before first push)
    (assert-no-error (limn/undo:undo tree))))

;;; ── Tree marker / mark-as-savepoint ────────────────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :limn/undo)
    (unless (find-symbol "MARK" :limn/undo)
      (export (intern "MARK" :limn/undo) :limn/undo))
    (unless (find-symbol "JUMP-TO-MARK" :limn/undo)
      (export (intern "JUMP-TO-MARK" :limn/undo) :limn/undo))))

(deftest undo-named-marker
  "limn/undo:mark labels current state; jump-to-mark restores it."
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :a)
    (limn/undo:mark tree :saved)
    (limn/undo:push-state tree :b)
    (limn/undo:push-state tree :c)
    (limn/undo:jump-to-mark tree :saved)
    (assert-eq :a (limn/undo:current tree)
               "restored to marked state")))

;;; ── Undo branch detection ─────────────────────────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-package :limn/undo)
    (unless (find-symbol "HAS-BRANCHES?" :limn/undo)
      (export (intern "HAS-BRANCHES?" :limn/undo) :limn/undo))))

(deftest undo-has-branches-detects-branching
  "has-branches? returns true once a branch has been created."
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree :a)
    (limn/undo:push-state tree :b)
    (limn/undo:undo tree)
    (assert-false (limn/undo:has-branches? tree)
                  "before second branch, no branching")
    (limn/undo:push-state tree :c)
    (limn/undo:undo tree)
    (assert-true (limn/undo:has-branches? tree)
                 "after branching, detected")))

;;; ── Long-running history ──────────────────────────────────────────────

(deftest undo-many-pushes-after-undo
  "Heavy branching: undo, push, undo, push... yields a wide tree."
  (let ((tree (limn/undo:make-tree)))
    (loop for i from 0 below 20 do
      (limn/undo:push-state tree i)
      (when (oddp i) (limn/undo:undo tree)))
    (assert-no-error (limn/undo:tree-shape tree)
                     "tree-shape works on complex history")))

;;; ── Custom equality ──────────────────────────────────────────────────

(deftest undo-state-equality-by-value
  "Two pushes with equal plist values are still distinct nodes
   (state equality is by identity / position, not by content)."
  (let ((tree (limn/undo:make-tree)))
    (limn/undo:push-state tree '(:page 0))
    (limn/undo:push-state tree '(:page 0))
    ;; Should still allow undo once
    (assert-no-error (limn/undo:undo tree))
    (let ((cur (limn/undo:current tree)))
      (assert-equal '(:page 0) cur "still on the previous identical state"))))
