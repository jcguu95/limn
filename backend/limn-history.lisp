;;;; limn-history — named history rings with sidecar persistence.
;;;;
;;;; Pure Lisp. v0.25 §D.
;;;; Emacs-compatible semantics: consecutive duplicates not stored;
;;;; ring wraps at max-size; sidecar at ~/.limn/history/<name>.lisp.

(defpackage #:limn/history
  (:use #:cl)
  (:export #:define-history #:add-to-history #:history-items
           #:history-max-size
           #:*minibuffer-history* #:*command-history* #:*search-history*
           #:history-sidecar-path
           #:save-history #:load-history))

(in-package #:limn/history)

(defstruct history-ring
  name
  (max-size 50 :type integer)
  (items '() :type list))

(defvar *registry* (make-hash-table :test 'equal))

(defun %key (name)
  (etypecase name
    (symbol (symbol-name name))
    (string name)))

(defun define-history (name &key (size 50))
  (setf (gethash (%key name) *registry*)
        (make-history-ring :name name :max-size size))
  name)

(defun add-to-history (name item)
  (unless (gethash (%key name) *registry*)
    (define-history name :size 50))  ; auto-create with default size
  (let ((ring (gethash (%key name) *registry*)))
    (let ((items (history-ring-items ring)))
      (unless (and items (equal (first items) item))
        (let ((new-items (cons item items)))
          (when (> (length new-items) (history-ring-max-size ring))
            (setf new-items (subseq new-items 0 (history-ring-max-size ring))))
          (setf (history-ring-items ring) new-items)))))
  item)

(defun history-items (name)
  (let ((ring (gethash (%key name) *registry*)))
    (if ring (history-ring-items ring) '())))

(defun history-max-size (name)
  (let ((ring (gethash (%key name) *registry*)))
    (if ring (history-ring-max-size ring) 0)))

;;; ─── sidecar persistence ──────────────────────────────────────────

(defun history-sidecar-path (name)
  (let* ((home (or (sb-posix:getenv "HOME")
                   (namestring (user-homedir-pathname))))
         (slug (string-downcase
                (etypecase name
                  (symbol (let ((s (symbol-name name)))
                            ;; strip surrounding *…*
                            (string-trim "*" s)))
                  (string name)))))
    (format nil "~a/.limn/history/~a.lisp" home slug)))

(defun save-history (name path)
  (let ((items (history-items name)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write items :stream out :readably t))))

(defun load-history (name path)
  (when (probe-file path)
    (with-open-file (in path :direction :input)
      (let ((items (read in nil nil)))
        (when items
          (let ((ring (gethash (%key name) *registry*)))
            (when ring
              (setf (history-ring-items ring)
                    (subseq items 0
                            (min (length items)
                                 (history-ring-max-size ring)))))))))))

;;; ─── built-in rings ───────────────────────────────────────────────

(define-history '*minibuffer-history* :size 100)
(define-history '*command-history*    :size 100)
(define-history '*search-history*     :size 50)

(defvar *minibuffer-history* (gethash "%MINIBUFFER-HISTORY%" *registry*)
  "Pre-defined history ring for minibuffer input.")
(defvar *command-history*    (gethash "%COMMAND-HISTORY%"    *registry*)
  "Pre-defined history ring for M-x commands.")
(defvar *search-history*     (gethash "%SEARCH-HISTORY%"     *registry*)
  "Pre-defined history ring for search strings.")

;; Ensure they're in the registry under their own names too
(eval-when (:load-toplevel :execute)
  (unless (gethash "*MINIBUFFER-HISTORY*" *registry*)
    (define-history '*minibuffer-history* :size 100))
  (unless (gethash "*COMMAND-HISTORY*" *registry*)
    (define-history '*command-history* :size 100))
  (unless (gethash "*SEARCH-HISTORY*" *registry*)
    (define-history '*search-history* :size 50))
  (setf *minibuffer-history* (gethash "*MINIBUFFER-HISTORY*" *registry*)
        *command-history*    (gethash "*COMMAND-HISTORY*"    *registry*)
        *search-history*     (gethash "*SEARCH-HISTORY*"     *registry*)))
