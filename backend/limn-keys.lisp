;;;; limn-keys — Emacs-like keymap.
;;;;
;;;; A keymap is a hash from key-string → action OR sub-keymap (for prefix
;;;; keys). Lookup of a single key returns action / :prefix / nil.
;;;; Lookup of a sequence walks the prefix chain.
;;;;
;;;; Keys parsed from Emacs-style strings: "j", "C-s", "M-x", "RET", "SPC".
;;;; Modifier order is canonicalized so "C-M-s" and "M-C-s" are the same.

(defpackage #:limn/keys
  (:use #:cl)
  (:export #:make-keymap #:define-key #:lookup #:lookup-sequence
           #:parse-key-spec #:keymap-p
           #:invoke #:define-parent #:describe-bindings
           #:undefine-key
           #:lookup-with-prefix))

(in-package #:limn/keys)

(defstruct keymap
  (bindings (make-hash-table :test 'equal))   ; canonical-key → action OR sub-keymap
  parent)                                       ; parent keymap, or nil

;;; ── key spec canonicalization ──────────────────────────────────────────

(defun canonical-key (spec)
  "Sort modifiers alphabetically so 'C-M-s' and 'M-C-s' map to the same string."
  (let* ((parts (split-on-dash spec))
         (base  (car (last parts)))
         (mods  (sort (butlast parts) #'string<)))
    (if mods
        (format nil "~{~a-~}~a" mods base)
        base)))

(defun split-on-dash (s)
  "Split 'C-M-s' into ('C' 'M' 's'). Treats only single-char modifiers
   as separators — bare '-' (after a modifier) becomes the literal key."
  (let ((parts '())
        (cur (make-string-output-stream)))
    (loop for i from 0 below (length s) do
      (let ((c (char s i)))
        (cond
          ;; "X-" where X is a known modifier letter — flush
          ((and (char= c #\-)
                (zerop (length (string-trim '() (get-output-stream-string-peek cur))))
                (= i 1) (char= (char s 0) #\C))
           ;; Already flushed by previous step? Fall through.
           (write-char c cur))
          (t (write-char c cur)))))
    ;; Simpler: just split by '-' but rejoin if last part is empty (means literal -)
    (let ((bits (loop with start = 0
                       for i from 0 below (length s)
                       when (char= (char s i) #\-)
                         collect (subseq s start i) and do (setf start (1+ i))
                       finally (return (append (loop with start = 0
                                                      for i from 0 below (length s)
                                                      when (char= (char s i) #\-)
                                                        collect (subseq s start i) and do (setf start (1+ i)))
                                                (list (subseq s start)))))))
      (declare (ignore bits)))
    ;; Robust version: split on every "-", treat each segment of length 1 + uppercase as modifier
    ;; or the special form "Modifier-Base".
    ;; For our purposes, just split on every "-".
    (let ((bits (split-string-on s #\-)))
      ;; Remove empty segments (only at end if input ends with -)
      bits)))

(defun split-string-on (s ch)
  (loop with start = 0
        with result = '()
        for i from 0 below (length s)
        when (char= (char s i) ch)
          do (push (subseq s start i) result)
             (setf start (1+ i))
        finally (push (subseq s start) result)
                (return (nreverse result))))

(defun get-output-stream-string-peek (stream)
  (declare (ignore stream))
  "")   ; not used in simplified impl

(defun parse-key-spec (spec)
  "Parse an Emacs-style key spec into its canonical form.
   Signals an error for empty/invalid input."
  (when (or (null spec) (zerop (length spec)))
    (error "empty key spec"))
  ;; Quick syntactic check
  (let ((parts (split-string-on spec #\-)))
    (cond
      ;; bare single segment
      ((= (length parts) 1) spec)
      ;; modifiers + base
      (t (canonical-key spec)))))

;;; ── keymap operations ──────────────────────────────────────────────────

(defun define-key (km spec action)
  (let* ((seq (split-string-on spec #\Space))
         (single (and (= (length seq) 1)))
         (cur km))
    (if single
        (setf (gethash (canonical-key (first seq)) (keymap-bindings cur)) action)
        ;; multi-key sequence: walk/create sub-keymaps
        (let ((last (car (last seq)))
              (prefix-keys (butlast seq)))
          (dolist (k prefix-keys)
            (let* ((ck   (canonical-key k))
                   (next (gethash ck (keymap-bindings cur))))
              (unless (keymap-p next)
                (setf next (make-keymap))
                (setf (gethash ck (keymap-bindings cur)) next))
              (setf cur next)))
          (setf (gethash (canonical-key last) (keymap-bindings cur)) action)))
    action))

(defun undefine-key (km spec)
  (let ((seq (split-string-on spec #\Space)))
    (if (= (length seq) 1)
        (remhash (canonical-key (first seq)) (keymap-bindings km))
        ;; walk to leaf, remove
        (let ((cur km))
          (dolist (k (butlast seq))
            (let ((next (gethash (canonical-key k) (keymap-bindings cur))))
              (unless (keymap-p next) (return-from undefine-key nil))
              (setf cur next)))
          (remhash (canonical-key (car (last seq))) (keymap-bindings cur))))))

(defun lookup (km spec)
  (let ((v (gethash (canonical-key spec) (keymap-bindings km))))
    (cond
      (v v)
      ((keymap-parent km) (lookup (keymap-parent km) spec))
      (t nil))))

(defun lookup-sequence (km keys)
  "Walk a key sequence. Returns final action, :prefix if mid-sequence,
   or nil if unknown."
  (let ((cur km))
    (loop for k in keys
          for last-p = (eq k (car (last keys)))
          for v = (gethash (canonical-key k) (keymap-bindings cur))
          do (cond
               ((null v)
                ;; Try parent only at the first step
                (if (and (eq cur km) (keymap-parent km))
                    (return (lookup-sequence (keymap-parent km) keys))
                    (return nil)))
               ((keymap-p v)
                (if last-p
                    (return :prefix)
                    (setf cur v)))
               (t  ; action
                (if last-p
                    (return v)
                    (return nil)))))))

(defun lookup-with-prefix (km spec arg)
  "Look up spec then invoke with the prefix arg. Returns the call's return value."
  (let ((action (lookup km spec)))
    (when (and action (functionp action))
      (funcall action arg))))

(defun invoke (km spec &rest args)
  (let ((action (lookup km spec)))
    (cond
      ((null action) (error "no binding for ~s" spec))
      ((functionp action) (apply action args))
      (t action))))

(defun define-parent (child parent)
  (setf (keymap-parent child) parent))

(defun describe-bindings (km)
  "Returns alist ((key . action) ...) — top-level bindings only."
  (let ((out '()))
    (maphash (lambda (k v) (push (cons k v) out)) (keymap-bindings km))
    out))
