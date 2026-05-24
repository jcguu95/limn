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

(defun %text   (bid)         (funcall *buffer-text-fn*       bid))
(defun %cursor (bid)         (funcall *buffer-cursor-fn*     bid))
(defun %scur   (bid off)     (funcall *buffer-set-cursor-fn* bid off))
(defun %ins    (bid off str) (funcall *buffer-insert-fn*     bid off str))
(defun %del    (bid from to) (funcall *buffer-delete-fn*     bid from to))
(defun %kill   (str)         (funcall *kill-new-fn*          str))

;;; ── helpers ───────────────────────────────────────────────────────────────

(defun %word-char-p (c)
  "Word char: alphanumeric, underscore, or non-ASCII (CJK etc. count as word)."
  (or (alphanumericp c)
      (char= c #\_)
      (> (char-code c) 127)))

(defun %line-start (text pos)
  "Offset of the first char on the line containing POS."
  (let ((p (1- pos)))
    (loop while (>= p 0) do
      (when (char= (char text p) #\Newline)
        (return-from %line-start (1+ p)))
      (decf p))
    0))

(defun %line-end (text pos)
  "Offset of the \\n that terminates the current line, or (length text)
   if the line runs to end-of-buffer."
  (let ((p pos) (len (length text)))
    (loop while (< p len) do
      (when (char= (char text p) #\Newline)
        (return-from %line-end p))
      (incf p))
    len))

;;; ── M-< / M-> ────────────────────────────────────────────────────────────

(defun beginning-of-buffer (bid)
  (setf *goal-column* nil)
  (%scur bid 0))

(defun end-of-buffer (bid)
  (setf *goal-column* nil)
  (%scur bid (length (%text bid))))

;;; ── C-a / C-e ────────────────────────────────────────────────────────────

(defun move-beginning-of-line (bid)
  (setf *goal-column* nil)
  (%scur bid (%line-start (%text bid) (%cursor bid))))

(defun move-end-of-line (bid)
  (setf *goal-column* nil)
  (%scur bid (%line-end (%text bid) (%cursor bid))))

;;; ── C-n / C-p ────────────────────────────────────────────────────────────

(defun next-line (bid)
  "Move down one line, preserving the goal column."
  (let* ((text (%text bid))
         (cur  (%cursor bid))
         (len  (length text))
         (bol  (%line-start text cur))
         (eol  (%line-end   text cur))
         (col  (or *goal-column* (- cur bol))))
    (setf *goal-column* col)
    (when (< eol len)
      (let* ((nbol (1+ eol))
             (neol (%line-end text nbol))
             (target (min (+ nbol col) neol)))
        (%scur bid target)))))

(defun previous-line (bid)
  "Move up one line, preserving the goal column."
  (let* ((text (%text bid))
         (cur  (%cursor bid))
         (bol  (%line-start text cur))
         (col  (or *goal-column* (- cur bol))))
    (setf *goal-column* col)
    (when (> bol 0)
      (let* ((peol (1- bol))
             (pbol (%line-start text peol))
             (target (min (+ pbol col) peol)))
        (%scur bid target)))))

;;; ── M-f / M-b ────────────────────────────────────────────────────────────

(defun forward-word (bid)
  (setf *goal-column* nil)
  (let* ((text (%text bid))
         (len  (length text))
         (p    (%cursor bid)))
    ;; Skip leading non-word, then word chars.
    (loop while (and (< p len) (not (%word-char-p (char text p)))) do (incf p))
    (loop while (and (< p len)      (%word-char-p (char text p)))  do (incf p))
    (%scur bid p)))

(defun backward-word (bid)
  (setf *goal-column* nil)
  (let* ((text (%text bid))
         (p    (%cursor bid)))
    (loop while (and (> p 0) (not (%word-char-p (char text (1- p))))) do (decf p))
    (loop while (and (> p 0)      (%word-char-p (char text (1- p))))  do (decf p))
    (%scur bid p)))

;;; ── RET / DEL / C-d ─────────────────────────────────────────────────────

(defun newline (bid)
  (setf *goal-column* nil)
  (%ins bid (%cursor bid) (string #\Newline)))

(defun delete-forward-char (bid)
  (setf *goal-column* nil)
  (let* ((text (%text bid))
         (cur  (%cursor bid))
         (len  (length text)))
    (when (< cur len)
      (%del bid cur (1+ cur)))))

;;; ── C-k / M-d ───────────────────────────────────────────────────────────

(defun kill-line (bid)
  "Kill from cursor to end of line.  If cursor is exactly at the line's
   \\n, kill the \\n (merging with next line).  No-op at end-of-buffer."
  (setf *goal-column* nil)
  (let* ((text (%text bid))
         (cur  (%cursor bid))
         (len  (length text)))
    (when (< cur len)
      (let* ((eol (%line-end text cur))
             (to  (if (= cur eol) (1+ cur) eol))
             (killed (subseq text cur to)))
        (%kill killed)
        (%del bid cur to)))))

(defun kill-word (bid)
  "Kill from cursor to end of next word (including any preceding non-word
   chars).  No-op at end-of-buffer."
  (setf *goal-column* nil)
  (let* ((text (%text bid))
         (cur  (%cursor bid))
         (len  (length text)))
    (when (< cur len)
      (let ((p cur))
        (loop while (and (< p len) (not (%word-char-p (char text p)))) do (incf p))
        (loop while (and (< p len)      (%word-char-p (char text p)))  do (incf p))
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
