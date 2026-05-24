;;;; v0.24 shared test helpers
;;;;
;;;; cursor-aware mock buffer (mock-buf24) used by kill-ring, mark-ring,
;;;; and kmacro unit tests.  Extends v023-helpers (don't duplicate
;;;; with-timeout-bound etc., just use the v023 package directly).
;;;;
;;;; Also provides with-kill-buf / with-mark-buf macros that rebind the
;;;; I/O vtable dynamic vars that limn/kill and limn/mark expose for
;;;; test isolation — the same pattern limn/cmd uses for *minibuffer-read*.

(defpackage #:limn/v024-helpers
  (:use #:cl)
  (:export
   ;; cursor-aware mock buffer
   #:make-mock-buf24 #:mbuf-id #:mbuf-text #:mbuf-cursor
   #:mbuf-insert-at! #:mbuf-delete! #:mbuf-subseq
   ;; macro helpers
   #:with-kill-buf #:with-mark-buf))

(in-package #:limn/v024-helpers)

;;; ─── cursor-aware mock buffer ─────────────────────────────────────────────
;;;
;;; Tracks (id, text, cursor).  Operations keep cursor semantically
;;; consistent with Emacs conventions:
;;;   - insert before cursor → cursor shifts right
;;;   - delete overlapping cursor → cursor snaps to deletion start

(defstruct (mock-buf24 (:conc-name mbuf-)
                       (:constructor make-mock-buf24
                           (&key (id "b") (text "") (cursor 0))))
  id
  (text   "" :type string)
  (cursor  0 :type integer))

(defun mbuf-insert-at! (buf offset str)
  "Insert STR at OFFSET in BUF, adjusting cursor."
  (let ((txt (mbuf-text buf)))
    (setf (mbuf-text buf)
          (concatenate 'string
                       (subseq txt 0 offset)
                       str
                       (subseq txt offset)))
    ;; cursor at or past insertion point shifts right
    (when (>= (mbuf-cursor buf) offset)
      (incf (mbuf-cursor buf) (length str)))))

(defun mbuf-delete! (buf from len)
  "Delete LEN chars starting at FROM, adjusting cursor."
  (let* ((txt (mbuf-text buf))
         (to  (min (+ from len) (length txt))))
    (setf (mbuf-text buf)
          (concatenate 'string (subseq txt 0 from) (subseq txt to)))
    (let ((c (mbuf-cursor buf))
          (actual-len (- to from)))
      (setf (mbuf-cursor buf)
            (cond ((< c from) c)
                  ((< c to)   from)
                  (t          (- c actual-len)))))))

(defun mbuf-subseq (buf from to)
  "Return the substring [FROM, TO) from BUF's text."
  (subseq (mbuf-text buf) from to))

;;; ─── with-kill-buf ────────────────────────────────────────────────────────
;;;
;;; Rebind limn/kill's I/O vtable vars to operate on a fresh mock-buf24.
;;; Tests that call kill-region / yank / yank-pop use this macro.

(defmacro with-kill-buf ((var &key (id "b") (text "") (cursor 0)) &body body)
  "Bind VAR to a fresh mock-buf24.  Rebind limn/kill I/O fns to target it."
  (let ((pkg (gensym "PKG")))
    `(let* ((,var (make-mock-buf24 :id ,id :text ,text :cursor ,cursor))
            (,pkg (find-package '#:limn/kill)))
       (if (null ,pkg)
           ;; limn/kill not loaded yet (RED phase): just run body
           (progn ,@body)
           (let* ((pairs
                    (list (cons (find-symbol "*BUFFER-INSERT-FN*"     ,pkg)
                                (lambda (bid off str)
                                  (declare (ignore bid))
                                  (mbuf-insert-at! ,var off str)))
                          (cons (find-symbol "*BUFFER-DELETE-FN*"     ,pkg)
                                (lambda (bid from len)
                                  (declare (ignore bid))
                                  (mbuf-delete! ,var from len)))
                          (cons (find-symbol "*BUFFER-CURSOR-FN*"     ,pkg)
                                (lambda (bid)
                                  (declare (ignore bid))
                                  (mbuf-cursor ,var)))
                          (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,pkg)
                                (lambda (bid off)
                                  (declare (ignore bid))
                                  (setf (mbuf-cursor ,var) off)))
                          (cons (find-symbol "*BUFFER-TEXT-FN*"       ,pkg)
                                (lambda (bid from to)
                                  (declare (ignore bid))
                                  (mbuf-subseq ,var from to)))))
                  (live (remove-if (lambda (p) (null (car p))) pairs)))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))

;;; ─── with-mark-buf ────────────────────────────────────────────────────────
;;;
;;; Like with-kill-buf but rebinds limn/mark's cursor vtable instead.

(defmacro with-mark-buf ((var &key (id "b") (text "") (cursor 0)) &body body)
  "Bind VAR to a fresh mock-buf24.  Rebind limn/mark cursor fns to target it."
  (let ((pkg (gensym "PKG")))
    `(let* ((,var (make-mock-buf24 :id ,id :text ,text :cursor ,cursor))
            (,pkg (find-package '#:limn/mark)))
       (if (null ,pkg)
           (progn ,@body)
           (let* ((pairs
                    (list (cons (find-symbol "*BUFFER-CURSOR-FN*"     ,pkg)
                                (lambda (bid)
                                  (declare (ignore bid))
                                  (mbuf-cursor ,var)))
                          (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,pkg)
                                (lambda (bid off)
                                  (declare (ignore bid))
                                  (setf (mbuf-cursor ,var) off)))))
                  (live (remove-if (lambda (p) (null (car p))) pairs)))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))
