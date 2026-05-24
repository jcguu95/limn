;;;; limn-mark — mark / push-mark / pop-mark / exchange-point-and-mark
;;;; / global-mark-ring (v0.24 §B).
;;;;
;;;; A "mark" is a per-buffer integer offset. Each buffer has its own
;;;; mark-ring (history of past marks, bounded by *mark-ring-max*).
;;;; A global ring (*global-mark-ring*) keeps (buf-id . offset) entries
;;;; across buffers for pop-global-mark-style navigation.
;;;;
;;;; The cursor I/O vtable (*buffer-cursor-fn* / *buffer-set-cursor-fn*)
;;;; lets unit tests swap a mock buffer in without a running bridge.

(defpackage #:limn/mark
  (:use #:cl)
  (:export #:*mark-ring-max*
           #:*global-mark-ring* #:*global-mark-ring-max*
           #:set-mark #:mark
           #:push-mark #:pop-mark
           #:exchange-point-and-mark
           #:pop-global-mark
           #:*buffer-cursor-fn* #:*buffer-set-cursor-fn*
           #:reset-marks #:mark-ring-for))

(in-package #:limn/mark)

(defvar *mark-ring-max* 16)
(defvar *global-mark-ring* '())
(defvar *global-mark-ring-max* 16)

(defvar *buffer-cursor-fn*     (lambda (bid) (declare (ignore bid)) 0))
(defvar *buffer-set-cursor-fn* (lambda (bid off) (declare (ignore bid off))))

(defstruct bm
  (mark nil)
  (ring '()))

(defvar *bufs* (make-hash-table :test 'equal))

(defun %bm (buf-id)
  (or (gethash buf-id *bufs*)
      (setf (gethash buf-id *bufs*) (make-bm))))

(defun reset-marks (buf-id)
  "Reset all per-buffer mark state for BUF-ID (test isolation)."
  (remhash buf-id *bufs*)
  nil)

(defun mark-ring-for (buf-id)
  "Return the mark ring (list of integer offsets, newest first) for BUF-ID."
  (bm-ring (%bm buf-id)))

(defun set-mark (pos buf-id)
  "Set the mark in BUF-ID to POS, overwriting any previous mark."
  (setf (bm-mark (%bm buf-id)) pos))

(defun mark (buf-id &key error-on-nil)
  "Return the current mark of BUF-ID, or nil if none. With :error-on-nil
   t, signal an error when no mark is set."
  (let ((m (bm-mark (%bm buf-id))))
    (cond ((and (null m) error-on-nil)
           (error "limn/mark: no mark set in ~s" buf-id))
          (t m))))

(defun %push-global (buf-id pos)
  (push (cons buf-id pos) *global-mark-ring*)
  (when (and *global-mark-ring-max*
             (> (length *global-mark-ring*) *global-mark-ring-max*))
    (setf *global-mark-ring*
          (subseq *global-mark-ring* 0 *global-mark-ring-max*))))

(defun push-mark (buf-id &key pos)
  "Push a mark to the mark-ring of BUF-ID. With :pos, push that
   position; otherwise push the current cursor. Also pushes a
   (buf-id . pos) entry on *global-mark-ring*."
  (let* ((cur (funcall *buffer-cursor-fn* buf-id))
         (p   (or pos cur))
         (st  (%bm buf-id))
         (old (bm-mark st)))
    (when old
      (push old (bm-ring st))
      (when (and *mark-ring-max* (> (length (bm-ring st)) *mark-ring-max*))
        (setf (bm-ring st) (subseq (bm-ring st) 0 *mark-ring-max*))))
    (setf (bm-mark st) p)
    (%push-global buf-id p)
    p))

(defun pop-mark (buf-id)
  "Pop the most recent entry off BUF-ID's mark-ring into the current
   mark. No-op when the ring is empty."
  (let ((st (%bm buf-id)))
    (when (bm-ring st)
      (setf (bm-mark st) (pop (bm-ring st)))))
  nil)

(defun exchange-point-and-mark (buf-id)
  "Swap BUF-ID's cursor with its mark. Signals an error when no mark
   has been set."
  (let ((m (bm-mark (%bm buf-id))))
    (unless m
      (error "limn/mark: no mark set in ~s" buf-id))
    (let ((cur (funcall *buffer-cursor-fn* buf-id)))
      (funcall *buffer-set-cursor-fn* buf-id m)
      (setf (bm-mark (%bm buf-id)) cur))))

(defun pop-global-mark ()
  "Pop the most recent entry off *global-mark-ring* and move that
   buffer's cursor to the saved offset."
  (when *global-mark-ring*
    (let* ((entry (pop *global-mark-ring*))
           (bid   (car entry))
           (off   (cdr entry)))
      (funcall *buffer-set-cursor-fn* bid off)
      entry)))
