;;;; limn-kill — kill-ring / yank / yank-pop (v0.24 §A).
;;;;
;;;; *kill-ring* is a Lisp list, newest entry first. kill-new prepends;
;;;; kill-append modifies the head entry. kill-region / copy-region-as-kill
;;;; read text from the buffer via the I/O vtable and push to the ring.
;;;; yank inserts at point and records the inserted region in
;;;; *yank-from* / *yank-to*; yank-pop uses those to replace the previous
;;;; yank with another entry — only when *last-command* is yank or yank-pop.
;;;;
;;;; The I/O vtable (*buffer-insert-fn* etc.) lets unit tests swap a
;;;; mock buffer in without a running bridge. The runtime layer installs
;;;; real wire-call functions at startup.

(defpackage #:limn/kill
  (:use #:cl)
  (:export #:*kill-ring* #:*kill-ring-max*
           #:kill-new #:kill-append
           #:kill-region #:copy-region-as-kill
           #:yank #:yank-pop
           #:*interprogram-cut-function* #:*interprogram-paste-function*
           #:*buffer-insert-fn* #:*buffer-delete-fn*
           #:*buffer-cursor-fn* #:*buffer-set-cursor-fn*
           #:*buffer-text-fn*
           #:*yank-from* #:*yank-to*))

(in-package #:limn/kill)

(defvar *kill-ring* '())
(defvar *kill-ring-max* 60)

(defvar *interprogram-cut-function*   nil)
(defvar *interprogram-paste-function* nil)

(defvar *buffer-insert-fn*     (lambda (bid off str) (declare (ignore bid off str))))
(defvar *buffer-delete-fn*     (lambda (bid from len) (declare (ignore bid from len))))
(defvar *buffer-cursor-fn*     (lambda (bid) (declare (ignore bid)) 0))
(defvar *buffer-set-cursor-fn* (lambda (bid off) (declare (ignore bid off))))
(defvar *buffer-text-fn*       (lambda (bid from to) (declare (ignore bid from to)) ""))

(defvar *yank-from* nil)
(defvar *yank-to*   nil)

(defun %trim-ring ()
  (when (and *kill-ring-max* (> (length *kill-ring*) *kill-ring-max*))
    (setf *kill-ring* (subseq *kill-ring* 0 *kill-ring-max*))))

(defun kill-new (str)
  "Push STR onto the kill ring as a new entry."
  (push str *kill-ring*)
  (%trim-ring)
  (when *interprogram-cut-function*
    (handler-case (funcall *interprogram-cut-function* str)
      (error () nil)))
  str)

(defun kill-append (str &key before-p)
  "Append STR to the head of the kill ring. With :before-p t, prepend
   STR to the head entry. If the ring is empty, behave like kill-new."
  (cond
    ((null *kill-ring*)
     (kill-new str))
    (t
     (let ((head (car *kill-ring*)))
       (setf (car *kill-ring*)
             (if before-p
                 (concatenate 'string str head)
                 (concatenate 'string head str))))
     (car *kill-ring*))))

(defun copy-region-as-kill (buf-id from to)
  "Copy buffer text in [FROM, TO) onto the kill ring without deleting."
  (when (and (integerp from) (integerp to) (< from to))
    (let ((text (funcall *buffer-text-fn* buf-id from to)))
      (kill-new text)))
  nil)

(defun kill-region (buf-id from to)
  "Delete buffer text in [FROM, TO) and push it onto the kill ring."
  (when (and (integerp from) (integerp to) (< from to))
    (let ((text (funcall *buffer-text-fn* buf-id from to)))
      (kill-new text)
      (funcall *buffer-delete-fn* buf-id from (- to from))))
  nil)

(defun %nth-kill (n)
  "1-based index into the kill ring; nil if out of range or empty."
  (when (and (integerp n) (>= n 1) *kill-ring*
             (<= n (length *kill-ring*)))
    (nth (1- n) *kill-ring*)))

(defun %set-last-command (sym)
  "Set limn/cmd:*last-command* if the package is loaded."
  (let ((pkg (find-package '#:limn/cmd)))
    (when pkg
      (let ((s (find-symbol "*LAST-COMMAND*" pkg)))
        (when (and s (boundp s)) (setf (symbol-value s) sym))))))

(defun yank (buf-id &optional (n 1))
  "Insert the N-th kill ring entry (1-based) at point in BUF-ID.
   If *interprogram-paste-function* is non-nil and returns a string,
   use that string instead. Records the inserted region in *yank-from*
   / *yank-to* for yank-pop."
  (let ((text
          (or (and *interprogram-paste-function*
                   (handler-case (funcall *interprogram-paste-function*)
                     (error () nil)))
              (%nth-kill n))))
    (when text
      (let ((pos (funcall *buffer-cursor-fn* buf-id)))
        (funcall *buffer-insert-fn* buf-id pos text)
        (setf *yank-from* pos
              *yank-to*   (+ pos (length text)))
        (%set-last-command 'yank))))
  nil)

(defun yank-pop (buf-id)
  "Replace the previously yanked text with another kill ring entry.
   No-op unless *last-command* is YANK or YANK-POP."
  (let* ((cmd-pkg (find-package '#:limn/cmd))
         (last    (and cmd-pkg
                       (let ((s (find-symbol "*LAST-COMMAND*" cmd-pkg)))
                         (and s (boundp s) (symbol-value s))))))
    (when (and *kill-ring* *yank-from* *yank-to*
               (member last '(yank yank-pop
                              limn/kill:yank limn/kill:yank-pop)))
      (let ((new-text (car *kill-ring*))
            (from *yank-from*)
            (old-len (- *yank-to* *yank-from*)))
        (funcall *buffer-delete-fn* buf-id from old-len)
        (funcall *buffer-insert-fn* buf-id from new-text)
        (setf *yank-from* from
              *yank-to*   (+ from (length new-text)))
        (%set-last-command 'yank-pop)
        ;; Rotate so successive pops cycle through entries.
        (setf *kill-ring*
              (append (rest *kill-ring*) (list (first *kill-ring*)))))))
  nil)
