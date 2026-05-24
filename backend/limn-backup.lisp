;;;; limn-backup — make a backup of a visited file the first time
;;;; the buffer is saved during a session (v0.24 §G).
;;;;
;;;; Two strategies: copy or rename (controlled by *backup-by-copying*).
;;;; Optional numbered backups: foo.~1~, foo.~2~, … (*version-control*).
;;;; Once a buffer has been backed up during a session, repeated saves
;;;; do not re-backup (backed-up-p flag).

(defpackage #:limn/backup
  (:use #:cl)
  (:export #:make-backup-file-name #:backup-buffer
           #:backed-up-p #:set-backed-up #:clear-backed-up
           #:*make-backup-files* #:*version-control*
           #:*backup-by-copying*
           #:*kept-old-versions* #:*kept-new-versions*
           #:*before-backup-hook* #:*after-backup-hook*
           #:*buffer-path-fn*))

(in-package #:limn/backup)

(defvar *make-backup-files* t)
(defvar *version-control*   nil)
(defvar *backup-by-copying* t)
(defvar *kept-old-versions* 2)
(defvar *kept-new-versions* 2)

(defvar *before-backup-hook* '())
(defvar *after-backup-hook*  '())

(defvar *buffer-path-fn* (lambda (bid) (declare (ignore bid)) nil))

(defvar *backed-up* (make-hash-table :test 'equal))

(defun backed-up-p   (buf-id) (gethash buf-id *backed-up*))
(defun set-backed-up (buf-id) (setf (gethash buf-id *backed-up*) t))
(defun clear-backed-up (buf-id) (remhash buf-id *backed-up*))

(defun %numbered-name (path n)
  (format nil "~a.~~~a~~" path n))

(defun %next-numbered (path)
  (loop for n from 1
        for name = (%numbered-name path n)
        unless (probe-file name)
          return name))

(defun make-backup-file-name (path)
  "Return the backup path for PATH. With *version-control* t pick the
   next free .~N~ slot; otherwise return PATH with a trailing ~."
  (if *version-control*
      (%next-numbered path)
      (concatenate 'string path "~")))

(defun %copy-file (src dst)
  (with-open-file (in src :direction :input :element-type '(unsigned-byte 8))
    (with-open-file (out dst :direction :output
                             :element-type '(unsigned-byte 8)
                             :if-exists :supersede
                             :if-does-not-exist :create)
      (let ((buf (make-array 4096 :element-type '(unsigned-byte 8))))
        (loop for n = (read-sequence buf in)
              while (plusp n)
              do (write-sequence buf out :end n))))))

(defun %prune-numbered (path)
  "Trim numbered backups for PATH to keep *kept-old-versions* oldest
   and *kept-new-versions* newest. Best-effort; errors are swallowed."
  (handler-case
      (let ((existing
              (loop for n from 1 to 999
                    for name = (%numbered-name path n)
                    while (probe-file name)
                    collect (cons n name))))
        (let* ((total (length existing))
               (keep-old (or *kept-old-versions* 0))
               (keep-new (or *kept-new-versions* 0)))
          (when (> total (+ keep-old keep-new))
            (let ((to-delete (subseq existing keep-old (- total keep-new))))
              (dolist (pair to-delete)
                (handler-case (delete-file (cdr pair)) (error () nil)))))))
    (error () nil)))

(defun backup-buffer (buf-id)
  "Make a backup of BUF-ID's visited file if one has not yet been
   taken this session. No-op when *make-backup-files* is nil, when
   the buffer has no visited file, or when the original does not
   exist."
  (when (and *make-backup-files* (not (backed-up-p buf-id)))
    (let ((path (funcall *buffer-path-fn* buf-id)))
      (when (and path (probe-file path))
        (dolist (h *before-backup-hook*)
          (handler-case (funcall h buf-id) (error () nil)))
        (let ((backup (make-backup-file-name path)))
          (handler-case
              (if *backup-by-copying*
                  (%copy-file path backup)
                  (rename-file path backup))
            (error () nil)))
        (when *version-control* (%prune-numbered path))
        (set-backed-up buf-id)
        (dolist (h *after-backup-hook*)
          (handler-case (funcall h buf-id) (error () nil))))))
  nil)
