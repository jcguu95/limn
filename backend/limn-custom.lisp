;;;; limn-custom — defcustom / customize, Emacs-compatible.
;;;;
;;;; Pure Lisp. v0.25 §G.
;;;; Supported :type values: boolean integer number string symbol
;;;; function hook (choice TYPE...) (repeat TYPE) color face.
;;;; Type mismatch → user-error (not a hard error), same as Emacs.

(defpackage #:limn/custom
  (:use #:cl)
  (:export #:defcustom
           #:customize-set-variable
           #:customize-save-variable
           #:custom-variable-p
           #:custom-variable-type
           #:save-customizations
           #:load-customizations))

(in-package #:limn/custom)

(define-condition user-error (error)
  ((message :initarg :message :reader user-error-message))
  (:report (lambda (c s) (write-string (user-error-message c) s))))

;;; Registry: symbol → plist (:default :doc :type :group :set :get)
(defvar *registry* (make-hash-table))

;;; ─── type validation ──────────────────────────────────────────────

(defun %type= (type name)
  "Compare a type specifier against a canonical name string (case-insensitive, ignoring package)."
  (and (symbolp type)
       (string-equal (symbol-name type) name)))

(defun %valid-p (value type)
  (cond
    ((null type)                    t)
    ((%type= type "boolean")        (or (null value) (eq value t)))
    ((%type= type "integer")        (integerp value))
    ((%type= type "number")         (numberp value))
    ((%type= type "string")         (stringp value))
    ((%type= type "symbol")         (symbolp value))
    ((%type= type "function")       (or (symbolp value) (functionp value)))
    ((%type= type "hook")           (and (listp value)
                                         (every (lambda (f) (or (symbolp f) (functionp f)))
                                                value)))
    ((%type= type "color")          (stringp value))
    ((%type= type "face")           (symbolp value))
    ((and (listp type) (%type= (first type) "choice"))
     (some (lambda (sub) (%valid-p value sub)) (rest type)))
    ((and (listp type) (%type= (first type) "const"))
     (equal value (second type)))
    ((and (listp type) (%type= (first type) "repeat"))
     (and (listp value)
          (every (lambda (item) (%valid-p item (second type))) value)))
    (t t)))

(defun %check-type (sym value type)
  (unless (%valid-p value type)
    (error 'user-error
           :message (format nil "~a: invalid value ~s for type ~s" sym value type))))

;;; ─── defcustom macro ──────────────────────────────────────────────

(defmacro defcustom (sym default doc &key type group set get)
  ;; :type and :group are evaluated (user writes :type 'integer → stores symbol integer)
  `(progn
     (defvar ,sym ,default ,doc)
     (setf (gethash ',sym *registry*)
           (list :default ,default
                 :doc ,doc
                 :type ,type
                 :group ,group
                 :set ,set
                 :get ,get))
     ',sym))

;;; ─── customize-set-variable ───────────────────────────────────────

(defun customize-set-variable (sym value)
  (let ((entry (gethash sym *registry*)))
    (unless entry (error "~a is not a custom variable" sym))
    (let ((type (getf entry :type))
          (set-fn (getf entry :set))
          (get-fn (getf entry :get)))
      (%check-type sym value type)
      (if set-fn
          (setf (symbol-value sym) (funcall set-fn sym value))
          (setf (symbol-value sym) value))
      (if get-fn
          (funcall get-fn sym)
          (symbol-value sym)))))

;;; ─── customize-save-variable ──────────────────────────────────────

(defun customize-save-variable (sym value)
  (customize-set-variable sym value)
  (let* ((home (or (ignore-errors (sb-posix:getenv "HOME"))
                   (namestring (user-homedir-pathname))))
         (path (format nil "~a/.limn/custom.lisp" home)))
    (save-customizations path)))

;;; ─── save / load ──────────────────────────────────────────────────

(defun save-customizations (path)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (maphash (lambda (sym _entry)
               (let ((val (ignore-errors (symbol-value sym))))
                 ;; Skip values that can't be printed readably (e.g. lambdas)
                 (handler-case
                     (progn (write `(setf ,sym ',val) :stream out :readably t)
                            (terpri out))
                   (error ()
                     (format out "; skipped ~a (not readable)~%" sym)))))
             *registry*)))

(defun load-customizations (path)
  (when (probe-file path)
    (with-open-file (in path :direction :input)
      (loop for form = (read in nil :eof)
            until (eq form :eof)
            do (ignore-errors (eval form))))))

;;; ─── introspection ────────────────────────────────────────────────

(defun custom-variable-p (sym)
  (and (gethash sym *registry*) t))

(defun custom-variable-type (sym)
  (let ((entry (gethash sym *registry*)))
    (when entry (getf entry :type))))
