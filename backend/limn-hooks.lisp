;;;; limn-hooks — event hook registry.
;;;;
;;;; A hook is a named bag of functions. Multiple handlers can register for
;;;; the same name; run-hook fires them all in add-order. Errors in one
;;;; handler do not stop the chain (each handler's error is swallowed).
;;;;
;;;; add-hook-once registers a handler that auto-removes after first firing.
;;;;
;;;; Pure Lisp; no I/O or threads.

(defpackage #:limn/hooks
  (:use #:cl)
  (:export #:add-hook #:remove-hook #:run-hook
           #:list-hooks #:clear-hook #:clear-all-hooks
           #:add-hook-once))

(in-package #:limn/hooks)

;; name → list of (handler-fn . once-p)
(defvar *hooks* (make-hash-table :test 'equal))

(defun add-hook (name fn)
  (let ((existing (gethash name *hooks*)))
    (setf (gethash name *hooks*)
          (append existing (list (cons fn nil)))))
  name)

(defun add-hook-once (name fn)
  (let ((existing (gethash name *hooks*)))
    (setf (gethash name *hooks*)
          (append existing (list (cons fn t)))))
  name)

(defun remove-hook (name fn)
  (let ((existing (gethash name *hooks*)))
    (setf (gethash name *hooks*)
          (remove-if (lambda (pair) (eq (car pair) fn)) existing)))
  name)

(defun clear-hook (name)
  (remhash name *hooks*)
  name)

(defun clear-all-hooks ()
  (clrhash *hooks*))

(defun list-hooks ()
  (let ((names '()))
    (maphash (lambda (k v) (declare (ignore v)) (push k names)) *hooks*)
    names))

(defun run-hook (name &rest args)
  ;; Snapshot the list so self-modifications during the run don't disturb
  ;; the current iteration. Once-handlers are removed after firing.
  (let ((snapshot (copy-list (gethash name *hooks*))))
    (dolist (pair snapshot)
      (let ((fn (car pair)))
        (handler-case (apply fn args)
          (error () nil))))
    ;; After running, drop any once-handlers that fired. Operate on the
    ;; LIVE list (which may have been mutated during the run).
    (let ((live (gethash name *hooks*)))
      (dolist (pair snapshot)
        (when (cdr pair)            ; was a once-handler
          (setf live (remove pair live :test #'eq))))
      (setf (gethash name *hooks*) live)))
  name)
