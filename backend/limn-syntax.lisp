;;;; limn-syntax — v0.31 §A syntax tables.
;;;;
;;;; Syntax tables classify each character into a "role" that drives
;;;; word-movement, sexp-navigation, and string/comment parsing.
;;;; Pure-Lisp, zero C++ changes.
;;;;
;;;; Internal representation:
;;;;   0-127 (ASCII) : simple-vector of length 128, each slot a keyword or nil
;;;;   128+          : hash table char-code → keyword
;;;;   nil slot / miss → fall through to parent, then %default-class
;;;;
;;;; The standard table itself has empty slots; %default-class encodes
;;;; the Emacs-compatible defaults so we never need to pre-fill it.
;;;;
;;;; with-syntax-table is a plain function (table thunk) — no macro tricks.

(defpackage #:limn/syntax
  (:use #:cl)
  (:export #:make-syntax-table
           #:copy-syntax-table
           #:modify-syntax-entry
           #:char-syntax
           #:with-syntax-table
           #:*standard-syntax-table*
           #:*current-syntax-table*))

(in-package #:limn/syntax)

;;; ── internal structure ────────────────────────────────────────────────────

(defstruct (%st (:constructor %alloc-st (&optional parent))
                (:conc-name %st-)
                (:predicate %st-p))
  (parent    nil)
  (ascii     (make-array 128 :initial-element nil) :type simple-vector)
  (non-ascii (make-hash-table :test 'eql)))

;;; ── default class (Emacs-compatible) ─────────────────────────────────────

(defun %default-class (code)
  "Default syntax class for a char whose code isn't set in any table.
   Matches Emacs standard-syntax-table semantics for ASCII, and
   defaults non-ASCII to :word (CJK, emoji, accented letters)."
  (declare (type fixnum code))
  (cond
    ;; Non-ASCII: all default to :word
    ((> code 127) :word)
    ;; Whitespace: SPC TAB LF CR FF
    ((or (= code 32) (= code 9) (= code 10) (= code 13) (= code 12))
     :whitespace)
    ;; Word: digits, uppercase, lowercase
    ((or (and (>= code 48) (<= code 57))
         (and (>= code 65) (<= code 90))
         (and (>= code 97) (<= code 122)))
     :word)
    ;; Symbol: _ (Emacs class "_")
    ((= code 95) :symbol)
    ;; Open parens: ( [ {
    ((or (= code 40) (= code 91) (= code 123)) :open)
    ;; Close parens: ) ] }
    ((or (= code 41) (= code 93) (= code 125)) :close)
    ;; String quotes: " '
    ((or (= code 34) (= code 39)) :string)
    ;; Escape: \
    ((= code 92) :escape)
    ;; Everything else: punct
    (t :punct)))

;;; ── lookup ────────────────────────────────────────────────────────────────

(defun %lookup (st code)
  "Look up CODE in ST, walking the parent chain, falling back to %default-class."
  (declare (type fixnum code))
  (if (null st)
      (%default-class code)
      (let ((entry (if (< code 128)
                       (svref (%st-ascii st) code)
                       (gethash code (%st-non-ascii st)))))
        (if entry
            entry
            (%lookup (%st-parent st) code)))))

;;; ── global vars ───────────────────────────────────────────────────────────

(defvar *standard-syntax-table* nil
  "The root syntax table.  All new tables inherit from this by default.")

(defvar *current-syntax-table* nil
  "The syntax table currently in effect.
   Bound by with-syntax-table or buffer-local *syntax-table*.")

;;; ── public API ────────────────────────────────────────────────────────────

(defun make-syntax-table (&optional parent)
  "Return a new empty syntax table inheriting from PARENT.
   PARENT defaults to *standard-syntax-table*.  nil parent makes the
   table a root (entries not found fall through to %default-class)."
  (%alloc-st (if (eq parent 'no-parent)
                 nil
                 (or parent *standard-syntax-table*))))

(defun copy-syntax-table (table)
  "Return an independent copy of TABLE; mutations of the copy don't
   affect the original."
  (let ((new (%alloc-st (%st-parent table))))
    (dotimes (i 128)
      (setf (svref (%st-ascii new) i) (svref (%st-ascii table) i)))
    (maphash (lambda (k v) (setf (gethash k (%st-non-ascii new)) v))
             (%st-non-ascii table))
    new))

(defun modify-syntax-entry (char class &optional table)
  "Set the syntax class for CHAR to CLASS in TABLE.
   TABLE defaults to *current-syntax-table* (which is initialized to
   *standard-syntax-table* at load time)."
  (let* ((st (or table *current-syntax-table* *standard-syntax-table*))
         (code (char-code char)))
    (if (< code 128)
        (setf (svref (%st-ascii st) code) class)
        (setf (gethash code (%st-non-ascii st)) class)))
  nil)

(defun char-syntax (char &optional table)
  "Return the syntax class keyword for CHAR.
   TABLE defaults to *current-syntax-table*.  Falls back to
   *standard-syntax-table*, then to %default-class."
  (let ((st (or table *current-syntax-table* *standard-syntax-table*)))
    (%lookup st (char-code char))))

(defun with-syntax-table (table thunk)
  "Call THUNK with *current-syntax-table* dynamically bound to TABLE.
   Returns whatever THUNK returns."
  (let ((*current-syntax-table* table))
    (funcall thunk)))

;;; ── initialize globals ────────────────────────────────────────────────────

;;; *standard-syntax-table* is the root: no parent (nil), empty slots —
;;; all lookups fall through to %default-class.
(unless *standard-syntax-table*
  (setf *standard-syntax-table* (%alloc-st nil)))

(setf *current-syntax-table* *standard-syntax-table*)
