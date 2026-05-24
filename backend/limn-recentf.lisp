;;;; limn-recentf — recently opened files LRU + sidecar persistence
;;;; (v0.24 §H).
;;;;
;;;; *recentf-list* is a list of paths, newest first, deduplicated, with
;;;; length capped by *recentf-max-saved-items*. Sidecar format is a
;;;; single Lisp form (:recentf-list ("path1" "path2" …)).

(defpackage #:limn/recentf
  (:use #:cl)
  (:export #:*recentf-list* #:*recentf-max-saved-items*
           #:*recentf-save-file*
           #:recentf-push #:recentf-save #:recentf-load
           #:recentf-open #:recentf-clear #:recentf-remove
           #:*recentf-write-fn* #:*recentf-read-fn*
           #:*find-file-fn*))

(in-package #:limn/recentf)

(defvar *recentf-list* '())
(defvar *recentf-max-saved-items* 50)
(defvar *recentf-save-file* "~/.limn/recentf.lisp")

(defvar *recentf-write-fn*
  (lambda (path content)
    (with-open-file (s path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
      (write-string content s))))

(defvar *recentf-read-fn*
  (lambda (path)
    (when (probe-file path)
      (with-open-file (s path :direction :input)
        (let ((buf (make-string (file-length s))))
          (read-sequence buf s)
          buf)))))

(defvar *find-file-fn*
  (lambda (path)
    (let ((pkg (find-package '#:limn/file)))
      (when pkg
        (let ((ff (find-symbol "FIND-FILE" pkg)))
          (when ff (funcall ff path)))))))

(defun %trim ()
  (when (and *recentf-max-saved-items*
             (> (length *recentf-list*) *recentf-max-saved-items*))
    (setf *recentf-list*
          (subseq *recentf-list* 0 *recentf-max-saved-items*))))

(defun recentf-push (path)
  "Push PATH to the front of *recentf-list*, dedup, then trim to max."
  (when (and path (stringp path) (plusp (length path)))
    (setf *recentf-list*
          (cons path (remove path *recentf-list* :test #'equal)))
    (%trim))
  *recentf-list*)

(defun recentf-clear ()
  (setf *recentf-list* '()))

(defun recentf-remove (pred)
  "Remove every path for which (PRED path) is non-nil."
  (setf *recentf-list*
        (remove-if (lambda (p) (handler-case (funcall pred p) (error () nil)))
                   *recentf-list*))
  *recentf-list*)

(defun recentf-save ()
  "Serialize *recentf-list* to *recentf-save-file*."
  (let ((content (prin1-to-string (list :recentf-list *recentf-list*))))
    (funcall *recentf-write-fn* *recentf-save-file* content))
  t)

(defun recentf-load ()
  "Restore *recentf-list* from *recentf-save-file*. No-op when the
   sidecar is absent or unreadable."
  (let ((raw (funcall *recentf-read-fn* *recentf-save-file*)))
    (when (and raw (stringp raw) (plusp (length raw)))
      (handler-case
          (let* ((form  (read-from-string raw))
                 (paths (getf form :recentf-list)))
            (when (listp paths)
              (setf *recentf-list* paths)))
        (error () nil))))
  *recentf-list*)

(defun recentf-open (&optional (n 1))
  "Open the N-th entry of *recentf-list* (1-based) via *find-file-fn*.
   Silent no-op when out of range or the list is empty."
  (when (and (integerp n) (>= n 1)
             *recentf-list*
             (<= n (length *recentf-list*)))
    (let ((path (nth (1- n) *recentf-list*)))
      (when path
        (handler-case (funcall *find-file-fn* path)
          (error () nil)))))
  nil)
