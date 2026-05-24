;;;; limn-buffer-undo — user-facing undo/redo bound to event/buffer-modified.
;;;;
;;;; v0.23 §D. Distinct from limn/undo (v0.6 tree primitive). This
;;;; module subscribes to event/buffer-modified, keeps a per-buffer
;;;; undo tree of edit records, and exposes Emacs-style undo / redo
;;;; / undo-boundary semantics with branching when you edit after
;;;; undoing.
;;;;
;;;; The "inverse op" of an edit:
;;;;   (:insert pos len _ s)  → (:delete pos len)
;;;;   (:delete pos len s _)  → (:insert pos s)
;;;;   (:replace pos len old new) → (:replace pos (length new) new old)
;;;;
;;;; A "step" is a run of records terminated by an undo-boundary.
;;;; Undo / redo work step-at-a-time. Each step in the tree has a
;;;; unique id and timestamp.

(defpackage #:limn/buffer-undo
  (:use #:cl)
  (:export #:enable-undo #:disable-undo #:undo-disabled-p
           #:undo #:redo
           #:undo-boundary
           #:buffer-undo-list
           #:clear-undo
           #:*before-undo-hook* #:*after-undo-hook*
           #:buffer-branches #:switch-branch
           #:buffer-current-branch-id
           #:serialize-undo #:deserialize-undo
           #:install-buffer-modified-handler))

(in-package #:limn/buffer-undo)

;;; ─── Per-buffer state ───────────────────────────────────────────────

(defstruct buf-state
  (enabled t)
  (disabled-p nil)
  (lock (sb-thread:make-mutex))
  ;; Tree-as-list: each node = (:id N :parent ID :children (IDs) :ops (record*) :time UT)
  (next-id 1)
  (root-id 0)
  (current-id 0)
  (nodes (let ((h (make-hash-table :test 'eql)))
           (setf (gethash 0 h)
                 (list :id 0 :parent nil :children '() :ops nil
                       :time (get-universal-time)))
           h))
  (pending-ops nil)  ; accumulator until next undo-boundary
  (recording nil))   ; t while we're applying a programmatic undo/redo

(defvar *buffers* (make-hash-table :test 'equal))
(defvar *buffers-lock* (sb-thread:make-mutex))

(defvar *before-undo-hook* '())
(defvar *after-undo-hook* '())

(defun %state (buf-id)
  (sb-thread:with-mutex (*buffers-lock*)
    (or (gethash buf-id *buffers*)
        (setf (gethash buf-id *buffers*) (make-buf-state)))))

(defun enable-undo (buf-id)
  "Enable undo for BUF-ID. If the buffer was previously disabled,
   prior history is cleared (Emacs convention)."
  (sb-thread:with-mutex (*buffers-lock*)
    (let ((existing (gethash buf-id *buffers*)))
      (when (and existing (buf-state-disabled-p existing))
        (remhash buf-id *buffers*))))
  (let ((s (%state buf-id))) (setf (buf-state-disabled-p s) nil))
  t)

(defun disable-undo (buf-id)
  (let ((s (%state buf-id))) (setf (buf-state-disabled-p s) t)) t)

(defun undo-disabled-p (buf-id)
  (buf-state-disabled-p (%state buf-id)))

(defun clear-undo (buf-id)
  (sb-thread:with-mutex (*buffers-lock*)
    (remhash buf-id *buffers*))
  nil)

(defun buffer-undo-list (buf-id)
  "Flat list of all recorded edit records across all nodes — provided
   for introspection / test assertions, not for surgical mutation."
  (let ((s (%state buf-id))
        (acc '()))
    (maphash (lambda (k node)
               (declare (ignore k))
               (dolist (op (getf node :ops)) (push op acc)))
             (buf-state-nodes s))
    acc))

(defun buffer-current-branch-id (buf-id)
  (buf-state-current-id (%state buf-id)))

(defun buffer-branches (buf-id)
  "Return list of plists describing every node in the tree."
  (let ((s (%state buf-id))
        (acc '()))
    (maphash (lambda (k node)
               (declare (ignore k))
               (push (list :id (getf node :id)
                           :parent (getf node :parent)
                           :timestamp (getf node :time)
                           :op-count (length (getf node :ops)))
                     acc))
             (buf-state-nodes s))
    acc))

;;; ─── Recording edits ───────────────────────────────────────────────

(defun %record-op (buf-id ev)
  (let ((s (%state buf-id)))
    (sb-thread:with-mutex ((buf-state-lock s))
      (when (and (not (buf-state-disabled-p s))
                 (not (buf-state-recording s)))
        (push ev (buf-state-pending-ops s))))))

(defun undo-boundary (buf-id)
  "Seal pending ops into a new node under current. Idempotent when
   nothing has accumulated since the last boundary."
  (let ((s (%state buf-id)))
    (sb-thread:with-mutex ((buf-state-lock s))
      (when (buf-state-pending-ops s)
        (let* ((id (buf-state-next-id s))
               (cur-id (buf-state-current-id s))
               (cur (gethash cur-id (buf-state-nodes s)))
               (node (list :id id
                           :parent cur-id
                           :children '()
                           :ops (nreverse (buf-state-pending-ops s))
                           :time (get-universal-time))))
          (setf (gethash id (buf-state-nodes s)) node)
          (setf (getf cur :children)
                (append (getf cur :children) (list id)))
          (setf (gethash cur-id (buf-state-nodes s)) cur)
          (setf (buf-state-current-id s) id)
          (incf (buf-state-next-id s))
          (setf (buf-state-pending-ops s) nil)))))
  nil)

;;; ─── Applying inverse ops back to the buffer ──────────────────────

(defun %apply-inverse (buf-id op)
  "Given an edit record, send the wire command(s) that reverse it.
   In tests, the inverse is dispatched through limn/hooks under
   the name :buffer-undo/apply-inverse so a mock-buffer subscriber
   can react. Real integration with the gap buffer goes through
   bridge commands and is wired by the runtime layer."
  (let* ((op-kind (getf op :op))
         (pos     (getf op :pos))
         (len     (getf op :len))
         (before  (getf op :before))
         (after   (getf op :after))
         (inverse
           (case op-kind
             (:insert (list :op :delete :pos pos :len (length after)))
             (:delete (list :op :insert :pos pos :text before))
             (:replace (list :op :replace :pos pos :len (length after)
                             :before after :after before)))))
    (let ((hooks (find-package '#:limn/hooks)))
      (when hooks
        (funcall (find-symbol "RUN-HOOK" hooks)
                 :buffer-undo/apply-inverse buf-id inverse)))
    inverse))

(defun %seal-pending (s)
  (when (buf-state-pending-ops s)
    (undo-boundary (loop for k being each hash-key of *buffers*
                         when (eq (gethash k *buffers*) s)
                         return k))))

(defun undo (buf-id)
  (dolist (h *before-undo-hook*)
    (handler-case (funcall h buf-id) (error () nil)))
  (let ((applied nil))
    (let ((s (%state buf-id)))
      ;; Seal any pending so we never lose them.
      (sb-thread:with-mutex ((buf-state-lock s))
        (when (buf-state-pending-ops s)
          (let* ((id (buf-state-next-id s))
                 (cur-id (buf-state-current-id s))
                 (cur (gethash cur-id (buf-state-nodes s)))
                 (node (list :id id :parent cur-id :children '()
                             :ops (nreverse (buf-state-pending-ops s))
                             :time (get-universal-time))))
            (setf (gethash id (buf-state-nodes s)) node)
            (setf (getf cur :children)
                  (append (getf cur :children) (list id)))
            (setf (gethash cur-id (buf-state-nodes s)) cur)
            (setf (buf-state-current-id s) id)
            (incf (buf-state-next-id s))
            (setf (buf-state-pending-ops s) nil))))
      (let* ((cur-id (buf-state-current-id s))
             (cur (gethash cur-id (buf-state-nodes s)))
             (parent-id (getf cur :parent)))
        (when (and parent-id cur)
          (setf (buf-state-recording s) t)
          (unwind-protect
               (dolist (op (reverse (getf cur :ops)))
                 (setf applied (%apply-inverse buf-id op)))
            (setf (buf-state-recording s) nil))
          (setf (buf-state-current-id s) parent-id))))
    (dolist (h *after-undo-hook*)
      (handler-case (funcall h buf-id applied) (error () nil))))
  nil)

(defun redo (buf-id)
  (let ((s (%state buf-id)))
    (let* ((cur-id (buf-state-current-id s))
           (cur (gethash cur-id (buf-state-nodes s)))
           (children (getf cur :children)))
      (when children
        (let* ((next-id (first (last children)))
               (next (gethash next-id (buf-state-nodes s))))
          (setf (buf-state-recording s) t)
          (unwind-protect
               (dolist (op (getf next :ops))
                 (let* ((op-kind (getf op :op))
                        (pos (getf op :pos))
                        (after (getf op :after)))
                   (case op-kind
                     (:insert
                      (let ((hooks (find-package '#:limn/hooks)))
                        (when hooks
                          (funcall (find-symbol "RUN-HOOK" hooks)
                                   :buffer-undo/apply-inverse buf-id
                                   (list :op :insert :pos pos :text after)))))
                     (:delete
                      (let ((hooks (find-package '#:limn/hooks)))
                        (when hooks
                          (funcall (find-symbol "RUN-HOOK" hooks)
                                   :buffer-undo/apply-inverse buf-id
                                   (list :op :delete :pos pos
                                         :len (getf op :len))))))
                     (:replace
                      (let ((hooks (find-package '#:limn/hooks)))
                        (when hooks
                          (funcall (find-symbol "RUN-HOOK" hooks)
                                   :buffer-undo/apply-inverse buf-id
                                   (list :op :replace :pos pos
                                         :len (getf op :len)
                                         :before (getf op :before)
                                         :after after))))))))
            (setf (buf-state-recording s) nil))
          (setf (buf-state-current-id s) next-id)))))
  nil)

;;; ─── Branches ─────────────────────────────────────────────────────

(defun switch-branch (buf-id direction)
  "Rotate the children of the current node so a subsequent redo
   reaches a different reachable future. DIRECTION is :next or :prev."
  (let ((s (%state buf-id)))
    (let* ((cur-id (buf-state-current-id s))
           (cur (gethash cur-id (buf-state-nodes s)))
           (kids (getf cur :children)))
      (when (>= (length kids) 2)
        (setf (getf cur :children)
              (case direction
                (:next (append (rest kids) (list (first kids))))
                (:prev (cons (car (last kids)) (butlast kids)))
                (t kids)))
        (setf (gethash cur-id (buf-state-nodes s)) cur))))
  nil)

;;; ─── Serialize / deserialize ──────────────────────────────────────

(defun serialize-undo (buf-id)
  (let ((s (%state buf-id))
        (entries '()))
    (maphash (lambda (k v) (push (cons k v) entries))
             (buf-state-nodes s))
    (list :next-id (buf-state-next-id s)
          :current-id (buf-state-current-id s)
          :nodes entries)))

(defun deserialize-undo (buf-id blob)
  (sb-thread:with-mutex (*buffers-lock*)
    (remhash buf-id *buffers*))
  (let ((s (%state buf-id)))
    (setf (buf-state-next-id s) (getf blob :next-id))
    (setf (buf-state-current-id s) (getf blob :current-id))
    (clrhash (buf-state-nodes s))
    (dolist (cell (getf blob :nodes))
      (setf (gethash (car cell) (buf-state-nodes s)) (cdr cell))))
  nil)

;;; ─── Hook installer ───────────────────────────────────────────────

(defvar *handler-installed* nil)

(defun install-buffer-modified-handler ()
  (unless *handler-installed*
    (let ((hooks (find-package '#:limn/hooks)))
      (when hooks
        (funcall (find-symbol "ADD-HOOK" hooks)
                 :event/buffer-modified
                 (lambda (ev) (%record-op (getf ev :buf-id) ev)))
        (setf *handler-installed* t))))
  t)
