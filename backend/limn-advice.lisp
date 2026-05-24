;;;; limn-advice — nadvice system, Emacs-compatible.
;;;;
;;;; Pure Lisp. v0.25 §F.
;;;; Supports: :before :after :around :override :filter-args :filter-return.
;;;; Multiple advice on the same place applied in add-order (FIFO).
;;;; advice-remove restores original fdefinition when advice list is empty.

(defpackage #:limn/advice
  (:use #:cl)
  (:export #:advice-add #:advice-remove #:advice-mapc))

(in-package #:limn/advice)

;;; Registry entry: (:original fn :entries (list of (fn . where)))
(defvar *table* (make-hash-table))

;;; ─── internal ─────────────────────────────────────────────────────

(defun %entry (place)
  (gethash place *table*))

(defun %set-entry (place orig entries)
  (setf (gethash place *table*)
        (list :original orig :entries entries)))

(defun %remove-entry (place)
  (remhash place *table*))

(defun %build-advised-fn (original entries)
  "Return a closure that applies ENTRIES around ORIGINAL."
  (lambda (&rest args)
    ;; 1. :filter-args  (each transforms the whole args list)
    (dolist (e entries)
      (when (eq (cdr e) :filter-args)
        (setf args (apply (car e) (list args)))))

    ;; 2. :before  (FIFO)
    (dolist (e entries)
      (when (eq (cdr e) :before)
        (apply (car e) args)))

    ;; 3. base: :override beats original
    (let* ((override (find :override entries :key #'cdr))
           (base (if override (car override) original))
           ;; 4. :around chain (FIFO = first-added is outermost)
           (arounds (remove-if-not (lambda (e) (eq (cdr e) :around)) entries))
           (call-fn (lambda (&rest inner-args)
                      (apply base inner-args))))
      (dolist (e (reverse arounds))
        (let ((inner call-fn)
              (adv-fn (car e)))
          (setf call-fn
                (lambda (&rest a)
                  (apply adv-fn inner a)))))

      (let ((result (apply call-fn args)))

        ;; 5. :after  (FIFO)
        (dolist (e entries)
          (when (eq (cdr e) :after)
            (apply (car e) args)))

        ;; 6. :filter-return
        (dolist (e entries)
          (when (eq (cdr e) :filter-return)
            (setf result (funcall (car e) result))))

        result))))

(defun %rebuild (place)
  (let* ((entry (%entry place))
         (original (getf entry :original))
         (entries  (getf entry :entries)))
    (setf (fdefinition place)
          (%build-advised-fn original entries))))

;;; ─── public API ───────────────────────────────────────────────────

(defun advice-add (place where function)
  "Add FUNCTION as WHERE advice on PLACE (a symbol with an fdefinition)."
  (let ((existing (%entry place)))
    (let ((original (if existing
                        (getf existing :original)
                        (fdefinition place)))
          (entries  (if existing
                        (getf existing :entries)
                        '())))
      (%set-entry place original
                  (append entries (list (cons function where))))
      (%rebuild place)))
  place)

(defun advice-remove (place function)
  "Remove FUNCTION from PLACE's advice (matched by EQ). No error if absent."
  (let ((existing (%entry place)))
    (when existing
      (let* ((original (getf existing :original))
             (entries  (remove-if (lambda (e) (eq (car e) function))
                                  (getf existing :entries))))
        (if entries
            (progn
              (%set-entry place original entries)
              (%rebuild place))
            (progn
              ;; All advice removed: restore original
              (setf (fdefinition place) original)
              (%remove-entry place))))))
  place)

(defun advice-mapc (function place)
  "Call FUNCTION with (adv-fn where) for each advice on PLACE."
  (let ((existing (%entry place)))
    (when existing
      ;; Copy list so FUNCTION can safely call advice-remove
      (dolist (e (copy-list (getf existing :entries)))
        (funcall function (car e) (cdr e)))))
  nil)
