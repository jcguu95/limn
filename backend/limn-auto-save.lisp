;;;; limn-auto-save — periodic sidecar writes + recovery (v0.24 §F).
;;;;
;;;; Two triggers feed auto-save:
;;;;   1. Timer (idle *auto-save-timeout* seconds) — wired by runtime.
;;;;   2. Keystroke counter (every *auto-save-interval* dispatched keys).
;;;;
;;;; Sidecar naming: /dir/name → /dir/#name#. The sidecar lives next to
;;;; the original; a normal save deletes it.
;;;;
;;;; All disk I/O is mediated by a vtable so unit tests can use a
;;;; virtual store.

(defpackage #:limn/auto-save
  (:use #:cl)
  (:export #:auto-save-buffer #:auto-save-all-buffers
           #:auto-save-file-name #:delete-auto-save-file
           #:recover-file #:recover-session
           #:tick #:reset-counter
           #:*auto-save-timeout* #:*auto-save-interval*
           #:*auto-save-counter*
           #:*auto-save-list-file* #:*delete-auto-save-files*
           #:*write-auto-save-fn* #:*read-auto-save-fn*
           #:*auto-save-exists-p-fn* #:*auto-save-newer-p-fn*
           #:*minibuffer-yes-no-fn*
           #:*buffer-content-fn* #:*buffer-modified-p-fn*
           #:*visited-file-name-fn*
           #:*delete-auto-save-fn* #:*buffer-list-fn*))

(in-package #:limn/auto-save)

(defvar *auto-save-timeout*  30)
(defvar *auto-save-interval* 300)
(defvar *auto-save-counter*  0)
(defvar *auto-save-list-file* "~/.limn/auto-save-list")
(defvar *delete-auto-save-files* t)

(defvar *write-auto-save-fn*
  (lambda (path content)
    (with-open-file (s path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
      (write-string content s))))

(defvar *read-auto-save-fn*
  (lambda (path)
    (when (probe-file path)
      (with-open-file (s path :direction :input)
        (let ((buf (make-string (file-length s))))
          (read-sequence buf s)
          buf)))))

(defvar *auto-save-exists-p-fn*
  (lambda (path) (and (probe-file path) t)))

(defvar *auto-save-newer-p-fn*
  (lambda (orig sidecar)
    (and (probe-file sidecar)
         (or (not (probe-file orig))
             (> (file-write-date sidecar) (file-write-date orig))))))

(defvar *minibuffer-yes-no-fn*
  (lambda (prompt) (declare (ignore prompt)) nil))

(defvar *buffer-content-fn*
  (lambda (bid) (declare (ignore bid)) ""))

(defvar *buffer-modified-p-fn*
  (lambda (bid) (declare (ignore bid)) nil))

(defvar *visited-file-name-fn*
  (lambda (bid) (declare (ignore bid)) nil))

(defvar *delete-auto-save-fn*
  (lambda (path)
    (handler-case (delete-file path) (error () nil))))

(defvar *buffer-list-fn*
  (lambda () '()))

(defun %dirname (path)
  (let ((slash (position #\/ path :from-end t)))
    (if slash (subseq path 0 (1+ slash)) "")))

(defun %basename (path)
  (let ((slash (position #\/ path :from-end t)))
    (if slash (subseq path (1+ slash)) path)))

(defun %sidecar-for-path (path)
  "Compute the auto-save sidecar path for a file path: /dir/name → /dir/#name#."
  (concatenate 'string (%dirname path) "#" (%basename path) "#"))

(defun auto-save-file-name (buf-id)
  "Return the sidecar path for BUF-ID's visited file, or nil when the
   buffer has no visited file."
  (let ((vfn (funcall *visited-file-name-fn* buf-id)))
    (when vfn (%sidecar-for-path vfn))))

(defun auto-save-buffer (buf-id)
  "Write BUF-ID's content to its sidecar — provided the buffer is
   modified and has a visited file."
  (let ((sidecar (auto-save-file-name buf-id)))
    (when (and sidecar (funcall *buffer-modified-p-fn* buf-id))
      (let ((content (funcall *buffer-content-fn* buf-id)))
        (funcall *write-auto-save-fn* sidecar content))))
  nil)

(defun delete-auto-save-file (buf-id)
  "Remove BUF-ID's sidecar (called by save-buffer when
   *delete-auto-save-files* is true)."
  (let ((sidecar (auto-save-file-name buf-id)))
    (when sidecar
      (funcall *delete-auto-save-fn* sidecar)))
  nil)

(defun auto-save-all-buffers ()
  "Iterate every buffer reported by *buffer-list-fn* and auto-save
   each one. Safe when the list is empty."
  (dolist (bid (funcall *buffer-list-fn*))
    (handler-case (auto-save-buffer bid)
      (error () nil)))
  nil)

(defun reset-counter ()
  (setf *auto-save-counter* 0))

(defun tick ()
  "Bump the keystroke counter. Trigger auto-save-all-buffers when the
   counter reaches *auto-save-interval* (nil disables the threshold)."
  (incf *auto-save-counter*)
  (when (and *auto-save-interval*
             (integerp *auto-save-interval*)
             (>= *auto-save-counter* *auto-save-interval*))
    (setf *auto-save-counter* 0)
    (auto-save-all-buffers))
  *auto-save-counter*)

(defun recover-file (path)
  "Offer to restore PATH from its sidecar if the sidecar exists and
   is newer than the original."
  (let ((sidecar (%sidecar-for-path path)))
    (when (and (funcall *auto-save-exists-p-fn* sidecar)
               (funcall *auto-save-newer-p-fn* path sidecar)
               (funcall *minibuffer-yes-no-fn*
                        (format nil "Recover ~a from auto-save?" path)))
      (funcall *read-auto-save-fn* sidecar)))
  nil)

(defun recover-session ()
  "Scan *auto-save-list-file* for paths needing recovery. Stub for v0.24."
  nil)
