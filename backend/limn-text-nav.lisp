;;;; limn-text-nav — Emacs-style navigation + line editing (v0.28 §A).
;;;;
;;;; Pure-Lisp module providing the cursor-movement and basic line-editing
;;;; commands that text-mode's keymap binds to (C-n / C-p / C-a / C-e /
;;;; M-f / M-b / M-< / M-> / RET / DEL / C-k / M-d / etc.).
;;;;
;;;; I/O is via a vtable of dynvars so unit tests can swap in a mock
;;;; buffer without a running bridge.  At runtime, install wires them
;;;; to the real buffer/* wire calls.

(defpackage #:limn/text-nav
  (:use #:cl)
  (:export #:*goal-column*
           #:*buffer-text-fn*
           #:*buffer-cursor-fn*
           #:*buffer-set-cursor-fn*
           #:*buffer-insert-fn*
           #:*buffer-delete-fn*
           #:*kill-new-fn*
           ;; v0.31 §A — syntax-table vtable + helpers
           #:*syntax-table-fn*
           ;; v0.40 narrow — bounds vtable; defaults 0 / text-length.
           ;; Wired by limn/excursion at its load time to point-min-of /
           ;; point-max-of so all text-nav commands respect narrowing.
           #:*point-min-fn*
           #:*point-max-fn*
           #:skip-syntax-forward
           #:skip-syntax-backward
           #:next-line #:previous-line
           #:move-beginning-of-line #:move-end-of-line
           #:forward-word #:backward-word
           #:beginning-of-buffer #:end-of-buffer
           #:newline #:delete-forward-char
           #:kill-line #:kill-word
           #:install))

(in-package #:limn/text-nav)

;;; ── state ─────────────────────────────────────────────────────────────────

(defvar *goal-column* nil
  "Sticky target column for consecutive C-n / C-p.  Set on first vertical
   move; preserved across more verticals; reset to nil by any non-vertical
   command (C-a, C-e, M-f, M-b, M-<, M->, RET, DEL, C-k, M-d, …).")

;;; ── I/O vtable ────────────────────────────────────────────────────────────

(defvar *buffer-text-fn*       (lambda (bid) (declare (ignore bid)) ""))
(defvar *buffer-cursor-fn*     (lambda (bid) (declare (ignore bid)) 0))
(defvar *buffer-set-cursor-fn* (lambda (bid off) (declare (ignore bid off))))
(defvar *buffer-insert-fn*     (lambda (bid off str) (declare (ignore bid off str))))
(defvar *buffer-delete-fn*     (lambda (bid from to) (declare (ignore bid from to))))
(defvar *kill-new-fn*          (lambda (str) (declare (ignore str))))

;; v0.31 §A — syntax table vtable
(defvar *syntax-table-fn* nil
  "When non-nil, (syntax-table-fn BUF-ID) → syntax-table object for that buffer.
   nil = no syntax table, fall back to %word-char-p defaults.")

;; v0.40 narrow — accessible-region bounds.
;;
;; Contract: each fn returns the narrow boundary, or NIL to mean "no
;; narrowing active — fall back to 0 / (length text)".  Defaults
;; return NIL (full buffer accessible).  limn/excursion's load-time
;; block rewires these to query buffer-local narrow markers, so when a
;; buffer is narrowed every text-nav command (M-< / M-> / C-a / C-e /
;; C-n / C-p / M-f / M-b / DEL / C-k / M-d) stays inside the
;; accessible region.
;;
;; The nil-means-default contract lets text-nav-only tests (which
;; don't wire limn/excursion at all) keep working — the defaults give
;; whole-buffer access without ever consulting excursion's text-len-fn.
(defvar *point-min-fn*
  (lambda (bid) (declare (ignore bid)) nil))

(defvar *point-max-fn*
  (lambda (bid) (declare (ignore bid)) nil))

(defun %text   (bid)         (funcall *buffer-text-fn*       bid))
(defun %cursor (bid)         (funcall *buffer-cursor-fn*     bid))
(defun %scur   (bid off)     (funcall *buffer-set-cursor-fn* bid off))
(defun %ins    (bid off str) (funcall *buffer-insert-fn*     bid off str))
(defun %del    (bid from to) (funcall *buffer-delete-fn*     bid from to))
(defun %kill   (str)         (funcall *kill-new-fn*          str))
(defun %pmin   (bid)         (or (funcall *point-min-fn* bid) 0))
(defun %pmax   (bid)         (or (funcall *point-max-fn* bid)
                                 (length (%text bid))))

;;; ── helpers ───────────────────────────────────────────────────────────────

(defun %word-char-p (c)
  "Legacy word char predicate (used when no syntax table is wired):
   alphanumeric, underscore, or non-ASCII."
  (or (alphanumericp c)
      (char= c #\_)
      (> (char-code c) 127)))

(defun %get-syntax-table (bid)
  "Return syntax table for BID by calling *syntax-table-fn*, or nil."
  (when *syntax-table-fn*
    (funcall *syntax-table-fn* bid)))

(defun %char-syntax-class (c table)
  "Return syntax class for C.  When TABLE is non-nil and limn/syntax is
   loaded, delegates to limn/syntax:char-syntax.  Otherwise uses legacy rules."
  (if (and table (find-package '#:limn/syntax))
      (funcall (symbol-function (find-symbol "CHAR-SYNTAX" '#:limn/syntax))
               c table)
      ;; legacy fallback — matches old %word-char-p :word/:other convention
      (if (%word-char-p c) :word :punct)))

(defun %word-or-symbol-p (c table)
  "True if C's syntax class in TABLE is :word or :symbol."
  (let ((cls (%char-syntax-class c table)))
    (or (eq cls :word) (eq cls :symbol))))

(defun %line-start (text pos &optional (lo 0))
  "Offset of the first char on the line containing POS.  Scans
   backwards until a #\\Newline or LO (whichever comes first).  LO is
   the lower bound of the accessible region (point-min when narrowed)."
  (let ((p (1- pos)))
    (loop while (>= p lo) do
      (when (char= (char text p) #\Newline)
        (return-from %line-start (1+ p)))
      (decf p))
    lo))

(defun %line-end (text pos &optional (hi (length text)))
  "Offset of the \\n that terminates the current line, or HI if the
   line runs to the upper bound of the accessible region (point-max
   when narrowed)."
  (let ((p pos))
    (loop while (< p hi) do
      (when (char= (char text p) #\Newline)
        (return-from %line-end p))
      (incf p))
    hi))

;;; ── M-< / M-> ────────────────────────────────────────────────────────────

(defun beginning-of-buffer (bid)
  (setf *goal-column* nil)
  (%scur bid (%pmin bid)))

(defun end-of-buffer (bid)
  (setf *goal-column* nil)
  (%scur bid (%pmax bid)))

;;; ── C-a / C-e ────────────────────────────────────────────────────────────

(defun move-beginning-of-line (bid)
  (setf *goal-column* nil)
  (%scur bid (%line-start (%text bid) (%cursor bid) (%pmin bid))))

(defun move-end-of-line (bid)
  (setf *goal-column* nil)
  (%scur bid (%line-end (%text bid) (%cursor bid) (%pmax bid))))

;;; ── C-n / C-p ────────────────────────────────────────────────────────────

(defun next-line (bid)
  "Move down one line, preserving the goal column."
  (let* ((text (%text bid))
         (cur  (%cursor bid))
         (lo   (%pmin bid))
         (hi   (%pmax bid))
         (bol  (%line-start text cur lo))
         (eol  (%line-end   text cur hi))
         (col  (or *goal-column* (- cur bol))))
    (setf *goal-column* col)
    (when (< eol hi)
      (let* ((nbol (1+ eol))
             (neol (%line-end text nbol hi))
             (target (min (+ nbol col) neol)))
        (%scur bid target)))))

(defun previous-line (bid)
  "Move up one line, preserving the goal column."
  (let* ((text (%text bid))
         (cur  (%cursor bid))
         (lo   (%pmin bid))
         (bol  (%line-start text cur lo))
         (col  (or *goal-column* (- cur bol))))
    (setf *goal-column* col)
    (when (> bol lo)
      (let* ((peol (1- bol))
             (pbol (%line-start text peol lo))
             (target (min (+ pbol col) peol)))
        (%scur bid target)))))

;;; ── M-f / M-b ────────────────────────────────────────────────────────────

(defun forward-word (bid)
  (setf *goal-column* nil)
  (let* ((text  (%text bid))
         (hi    (%pmax bid))
         (table (%get-syntax-table bid))
         (p     (%cursor bid)))
    (loop while (and (< p hi)
                     (not (%word-or-symbol-p (char text p) table)))
          do (incf p))
    (loop while (and (< p hi)
                     (%word-or-symbol-p (char text p) table))
          do (incf p))
    (%scur bid p)))

(defun backward-word (bid)
  (setf *goal-column* nil)
  (let* ((text  (%text bid))
         (lo    (%pmin bid))
         (table (%get-syntax-table bid))
         (p     (%cursor bid)))
    (loop while (and (> p lo)
                     (not (%word-or-symbol-p (char text (1- p)) table)))
          do (decf p))
    (loop while (and (> p lo)
                     (%word-or-symbol-p (char text (1- p)) table))
          do (decf p))
    (%scur bid p)))

;;; ── skip-syntax-forward / backward (v0.31 §A) ───────────────────────────

(defun %class-str-to-keywords (class-str)
  "Parse a syntax class string into a list of keyword symbols.
   \"w\" → :word  \"_\" → :symbol  \"-\" → :whitespace
   \"(\" → :open  \")\" → :close   \"\\\"\" → :string
   \"\\\\ \" → :escape  \".\" → :punct  \"<\" → :comment-start
   \">\" → :comment-end"
  (loop for c across class-str
        for kw = (case c
                   (#\w :word)
                   (#\_ :symbol)
                   (#\- :whitespace)
                   (#\( :open)
                   (#\) :close)
                   (#\" :string)
                   (#\\ :escape)
                   (#\. :punct)
                   (#\< :comment-start)
                   (#\> :comment-end))
        when kw collect kw))

(defun skip-syntax-forward (class-str bid)
  "Move cursor forward past consecutive chars whose syntax is in CLASS-STR."
  (setf *goal-column* nil)
  (let* ((text    (%text bid))
         (hi      (%pmax bid))
         (table   (%get-syntax-table bid))
         (classes (%class-str-to-keywords class-str))
         (p       (%cursor bid)))
    (loop while (and (< p hi)
                     (member (%char-syntax-class (char text p) table) classes))
          do (incf p))
    (%scur bid p)))

(defun skip-syntax-backward (class-str bid)
  "Move cursor backward past consecutive chars whose syntax is in CLASS-STR."
  (setf *goal-column* nil)
  (let* ((text    (%text bid))
         (lo      (%pmin bid))
         (table   (%get-syntax-table bid))
         (classes (%class-str-to-keywords class-str))
         (p       (%cursor bid)))
    (loop while (and (> p lo)
                     (member (%char-syntax-class (char text (1- p)) table) classes))
          do (decf p))
    (%scur bid p)))

;;; ── RET / DEL / C-d ─────────────────────────────────────────────────────

(defun newline (bid)
  (setf *goal-column* nil)
  (%ins bid (%cursor bid) (string #\Newline)))

(defun delete-forward-char (bid)
  (setf *goal-column* nil)
  (let* ((cur (%cursor bid))
         (hi  (%pmax bid)))
    (when (< cur hi)
      (%del bid cur (1+ cur)))))

;;; ── C-k / M-d ───────────────────────────────────────────────────────────

(defun kill-line (bid)
  "Kill from cursor to end of line.  If cursor is exactly at the line's
   \\n, kill the \\n (merging with next line).  No-op at end-of-buffer
   or at the upper narrow bound."
  (setf *goal-column* nil)
  (let* ((text (%text bid))
         (cur  (%cursor bid))
         (hi   (%pmax bid)))
    (when (< cur hi)
      (let* ((eol (%line-end text cur hi))
             (to  (if (= cur eol) (min (1+ cur) hi) eol))
             (killed (subseq text cur to)))
        (%kill killed)
        (%del bid cur to)))))

(defun kill-word (bid)
  "Kill from cursor to end of next word (including any preceding non-word
   chars).  No-op at end-of-buffer or upper narrow bound."
  (setf *goal-column* nil)
  (let* ((text  (%text bid))
         (cur   (%cursor bid))
         (hi    (%pmax bid))
         (table (%get-syntax-table bid)))
    (when (< cur hi)
      (let ((p cur))
        (loop while (and (< p hi)
                         (not (%word-or-symbol-p (char text p) table)))
              do (incf p))
        (loop while (and (< p hi)
                         (%word-or-symbol-p (char text p) table))
              do (incf p))
        (when (> p cur)
          (let ((killed (subseq text cur p)))
            (%kill killed)
            (%del bid cur p)))))))

;;; ── install ─────────────────────────────────────────────────────────────

(defun install ()
  "Wire vtable callbacks to real subsystems when present.  Safe to call
   multiple times (idempotent)."
  ;; *kill-new-fn* → limn/kill:kill-new
  (let* ((kp (find-package '#:limn/kill))
         (kn (and kp (find-symbol "KILL-NEW" kp))))
    (when (and kn (fboundp kn))
      (setf *kill-new-fn* (symbol-function kn))))
  t)

(install)
