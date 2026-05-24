;;;; limn-local — v0.30 §B buffer-local variables.
;;;;
;;;; Buffer-local variables: a global default value (held in the symbol)
;;;; plus per-buffer overrides (held in *buffer-locals*, a hash buf-id →
;;;; (hash sym → value)). Lookup falls through buffer→default.
;;;;
;;;; Auto-mark: setq-local on an undeclared symbol marks it buffer-local
;;;; (Emacs convention — friendlier for ad-hoc use).
;;;;
;;;; Event firing: changes go through %notify-change, which compares
;;;; old/new with EQUAL and only fires when they differ. The handler is
;;;; stored in *buffer-local-changed-fn* (vtable, default nil). The
;;;; integration with limn/hooks happens at a higher layer.
;;;;
;;;; Persistence on re-load: defvar-local expands to plain defvar (which
;;;; does NOT re-init an already-bound symbol) plus make-variable-buffer-local
;;;; (idempotent). So re-loading init.el preserves both the global value
;;;; and the per-buffer values.

(defpackage #:limn/local
  (:use #:cl)
  (:shadow #:get #:set)
  (:export #:get
           #:set
           #:bound-p
           #:default-value
           #:buffer-local-value
           #:set-buffer-local-value
           #:kill-local-variable
           #:local-variable-p
           #:make-variable-buffer-local
           #:defvar-local
           #:setq-local
           ;; vtable / dyn vars
           #:*current-buffer-id*
           #:*buffer-local-changed-fn*
           ;; test helper
           #:reset-buffer-locals))

(in-package #:limn/local)

;;; ── dyn vars / vtable ───────────────────────────────────────────────────

(defvar *current-buffer-id* nil
  "Current buffer-id. setq-local and the no-arg variants of
   kill-local-variable / local-variable-p read this.")

(defvar *buffer-local-changed-fn* nil
  "If non-nil, called as (fn PLIST) when a buffer-local value changes.
   PLIST has keys :buffer-id :symbol :old :new. EQUAL-equal old/new
   does not fire.")

;;; ── registry ────────────────────────────────────────────────────────────

(defvar *buffer-local-symbols* (make-hash-table :test 'eq)
  "Set of symbols (value t) registered as buffer-local-capable.")

(defvar *buffer-locals* (make-hash-table :test 'equal)
  "buf-id → (hash symbol → value).")

(defun %locals-table-or-nil (buf-id)
  (gethash buf-id *buffer-locals*))

(defun %locals-table-ensure (buf-id)
  (or (gethash buf-id *buffer-locals*)
      (setf (gethash buf-id *buffer-locals*)
            (make-hash-table :test 'eq))))

(defun reset-buffer-locals (buf-id)
  "Remove all locals for BUF-ID. For test isolation / buffer-close."
  (remhash buf-id *buffer-locals*)
  nil)

;;; ── declaration ────────────────────────────────────────────────────────

(defun make-variable-buffer-local (sym)
  "Mark SYM as buffer-local-capable. Idempotent."
  (setf (gethash sym *buffer-local-symbols*) t)
  sym)

(defmacro defvar-local (sym value &optional docstring)
  "Like (defvar SYM VALUE [DOCSTRING]) + make-variable-buffer-local.
   defvar does not re-init an already-bound SYM, so reloading init.el
   does not clobber user customizations."
  `(progn
     ,(if docstring
          `(defvar ,sym ,value ,docstring)
          `(defvar ,sym ,value))
     (make-variable-buffer-local ',sym)
     ',sym))

;;; ── event firing ───────────────────────────────────────────────────────

(defun %notify-change (buf-id sym old new)
  (when (and *buffer-local-changed-fn*
             (not (equal old new)))
    (funcall *buffer-local-changed-fn*
             (list :buffer-id buf-id :symbol sym :old old :new new))))

(defun %effective-default (sym)
  "Symbol's global default, or nil if unbound (for event payload purposes
   we don't want to error on transitional states)."
  (if (boundp sym) (symbol-value sym) nil))

;;; ── core lookup / mutation ─────────────────────────────────────────────

(defun get (sym &optional (buf-id *current-buffer-id*))
  "Buffer-aware lookup. Falls back to symbol-value if no local in BUF-ID."
  (let ((tbl (and buf-id (%locals-table-or-nil buf-id))))
    (if tbl
        (multiple-value-bind (v found) (gethash sym tbl)
          (if found v (symbol-value sym)))
        (symbol-value sym))))

(defun set (sym value)
  "Set SYM as buffer-local in the current buffer."
  (set-buffer-local-value sym value
                          (or *current-buffer-id*
                              (error "limn/local:set: no current buffer"))))

(defun bound-p (sym)
  "T if SYM has a local value in the current buffer, or a global value."
  (let ((bid *current-buffer-id*))
    (or (and bid
             (let ((tbl (%locals-table-or-nil bid)))
               (and tbl (nth-value 1 (gethash sym tbl)))))
        (boundp sym))))

(defun default-value (sym)
  "Global default. Signals unbound-variable if SYM was never defvar'd."
  (symbol-value sym))

(defun buffer-local-value (sym buf-id)
  "Read SYM in BUF-ID. Falls through to global default if no local."
  (let ((tbl (%locals-table-or-nil buf-id)))
    (if tbl
        (multiple-value-bind (v found) (gethash sym tbl)
          (if found v (symbol-value sym)))
        (symbol-value sym))))

(defun set-buffer-local-value (sym value buf-id)
  "Set SYM = VALUE in BUF-ID. Auto-marks SYM as buffer-local."
  (unless (gethash sym *buffer-local-symbols*)
    (make-variable-buffer-local sym))
  (let* ((tbl (%locals-table-ensure buf-id))
         (old (multiple-value-bind (v found) (gethash sym tbl)
                (if found v (%effective-default sym)))))
    (setf (gethash sym tbl) value)
    (%notify-change buf-id sym old value))
  value)

(defun kill-local-variable (sym &optional (buf-id *current-buffer-id*))
  "Remove SYM's local value in BUF-ID. No-op if no local set.
   Returns SYM (Emacs convention)."
  (when buf-id
    (let ((tbl (%locals-table-or-nil buf-id)))
      (when tbl
        (multiple-value-bind (old found) (gethash sym tbl)
          (when found
            (remhash sym tbl)
            (%notify-change buf-id sym old (%effective-default sym)))))))
  sym)

(defun local-variable-p (sym &optional (buf-id *current-buffer-id*))
  "T if SYM has a local value in BUF-ID (or current buffer)."
  (when buf-id
    (let ((tbl (%locals-table-or-nil buf-id)))
      (when tbl
        (nth-value 1 (gethash sym tbl))))))

;;; ── setq-local ─────────────────────────────────────────────────────────

(defmacro setq-local (sym value)
  "Set SYM's buffer-local value in the current buffer."
  `(set-buffer-local-value ',sym ,value
                           (or *current-buffer-id*
                               (error "setq-local: no current buffer"))))
