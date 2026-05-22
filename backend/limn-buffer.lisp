;;;; limn-buffer — Lisp-side buffer registry.
;;;;
;;;; Each buffer has an id, a path, an engine name, and a per-buffer
;;;; metadata bag (used for client-side state like scroll position,
;;;; bookmarks, etc.).
;;;;
;;;; Pure data structure — no I/O.

(defpackage #:limn/buffer
  (:use #:cl)
  (:export #:register #:unregister #:lookup #:list-all
           #:path #:engine
           #:metadata-set #:metadata-get
           #:clear-all
           #:buffer-p
           #:count-buffers #:map-buffers
           #:find-by-path))

(in-package #:limn/buffer)

(defstruct buffer
  id
  path
  engine
  (metadata (make-hash-table :test 'equal)))

(defvar *buffers* (make-hash-table :test 'equal))

(defun register (id path engine)
  (let ((b (make-buffer :id id :path path :engine engine)))
    (setf (gethash id *buffers*) b)
    b))

(defun unregister (id)
  (remhash id *buffers*))

(defun lookup (id)
  (gethash id *buffers*))

(defun list-all ()
  (let ((ids '()))
    (maphash (lambda (k v) (declare (ignore v)) (push k ids)) *buffers*)
    ids))

(defun path (b) (buffer-path b))
(defun engine (b) (buffer-engine b))

(defun metadata-set (b key value)
  (setf (gethash key (buffer-metadata b)) value))

(defun metadata-get (b key)
  (gethash key (buffer-metadata b)))

(defun clear-all ()
  (clrhash *buffers*))

(defun count-buffers ()
  (hash-table-count *buffers*))

(defun map-buffers (fn)
  (maphash (lambda (k v) (declare (ignore k)) (funcall fn v)) *buffers*))

(defun find-by-path (p)
  (let (found)
    (maphash (lambda (k v)
               (declare (ignore k))
               (when (and (not found) (equal (buffer-path v) p))
                 (setf found v)))
             *buffers*)
    found))
