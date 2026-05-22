;;;; limn-undo — branching undo tree (Emacs's undo-tree style).
;;;;
;;;; Tree of state nodes. Each node has a parent and a list of children.
;;;; push-state(tree, S) creates a new node S as a child of current and
;;;; advances. undo moves to parent. redo moves to the most-recent child.
;;;; A branch is created naturally when, after undoing, you push a new
;;;; state — the original future stays around as a sibling.
;;;;
;;;; switch-branch moves between siblings of the current node's parent.

(defpackage #:limn/undo
  (:use #:cl)
  (:export #:make-tree #:push-state #:undo #:redo
           #:switch-branch #:current #:tree-shape #:tree-p
           #:mark #:jump-to-mark #:has-branches?))

(in-package #:limn/undo)

(defstruct (undo-node (:conc-name node-) (:predicate node-p))
  state
  parent
  (children '()))

(defstruct (undo-tree (:conc-name tree-) (:predicate tree-p)
                       (:copier nil))
  root
  current
  (marks (make-hash-table :test 'equal)))

(defun make-tree ()
  (let ((root (make-undo-node :state nil :parent nil :children '())))
    (make-undo-tree :root root :current root)))

(defun current (tree)
  (node-state (tree-current tree)))

(defun push-state (tree state)
  (let* ((cur  (tree-current tree))
         (new  (make-undo-node :state state :parent cur :children '())))
    (push new (node-children cur))
    (setf (tree-current tree) new)
    state))

(defun undo (tree)
  (let ((cur (tree-current tree)))
    (when (and cur (node-parent cur))
      (setf (tree-current tree) (node-parent cur))
      (node-state (tree-current tree)))))

(defun redo (tree)
  (let* ((cur (tree-current tree))
         (kids (node-children cur)))
    (when kids
      (setf (tree-current tree) (first kids))
      (node-state (tree-current tree)))))

(defun switch-branch (tree direction)
  "Rotate the children list of the CURRENT node so that a subsequent (redo)
   picks a different child. After undo, this is how you reach the alternate
   future on a different branch.
     :left  → rotate so the next child becomes 'first to redo'
     :right → rotate in the opposite direction"
  (let* ((cur (tree-current tree))
         (kids (node-children cur))
         (n (length kids)))
    (when (>= n 2)
      (setf (node-children cur)
            (case direction
              (:left  (append (rest kids) (list (first kids))))
              (:right (cons (car (last kids)) (butlast kids)))
              (t      kids))))
    (node-state cur)))

(defun mark (tree name)
  (setf (gethash name (tree-marks tree)) (tree-current tree))
  name)

(defun jump-to-mark (tree name)
  (let ((node (gethash name (tree-marks tree))))
    (when node
      (setf (tree-current tree) node)
      (node-state node))))

(defun has-branches? (tree)
  (labels ((walk (n)
             (or (>= (length (node-children n)) 2)
                 (some #'walk (node-children n)))))
    (walk (tree-root tree))))

(defun tree-shape (tree)
  "Returns recursive (state . children-list) starting from root."
  (labels ((walk (n)
             (cons (node-state n) (mapcar #'walk (node-children n)))))
    (walk (tree-root tree))))
