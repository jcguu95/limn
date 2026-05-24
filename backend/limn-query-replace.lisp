;;;; limn-query-replace — v0.36 §A query-replace + query-replace-regexp.
;;;;
;;;; Pure Lisp. Stitches v0.34 regex + v0.32 narrow/save-excursion to
;;;; deliver Emacs M-% style interactive search-and-replace.
;;;;
;;;; The prompt loop is driven by a response thunk (:response-fn) so the
;;;; module is testable without a real minibuffer. When called from the
;;;; user-facing M-% command we plug in a minibuffer-backed thunk; in
;;;; tests we plug in a list-popping thunk. Recognized responses:
;;;;
;;;;   "y" | "SPC"  → replace this, move to next
;;;;   "n" | "DEL"  → skip this, move to next
;;;;   "!"          → replace this and all remaining without further prompts
;;;;   "q" | "RET"  → quit (don't replace this)
;;;;   "."          → replace this, then quit
;;;;   ","          → replace this, then pause for re-confirmation (we
;;;;                  treat as "replace + next" — non-interactive context)
;;;;   "^"          → revert last replacement, re-prompt at that match
;;;;
;;;; Range can be limited with :START and :END (Emacs region arg). Range
;;;; end auto-adjusts as replacements grow/shrink the buffer.
;;;;
;;;; Case-folding via :CASE-FOLD t (default).  In regex mode the pattern
;;;; is passed through limn/regex:emacs-regex-to-pcre to translate Emacs
;;;; syntax (\\(...\\) / \\b / etc.) to PCRE.  In literal mode we escape
;;;; the pattern's regex metachars instead.

(defpackage #:limn/query-replace
  (:use #:cl)
  (:export #:query-replace
           #:query-replace-regexp
           ;; vtable hooks
           #:*buffer-text-fn*
           #:*buffer-insert-fn*
           #:*buffer-delete-fn*
           #:*point-fn*
           #:*set-point-fn*
           #:*buffer-text-len-fn*
           ;; introspection
           #:*last-replace-count*
           ;; runtime wireup
           #:install-wire-vtable))

(in-package #:limn/query-replace)

;;; ── vtable hooks ──────────────────────────────────────────────────────────

(defvar *buffer-text-fn*
  (lambda (bid) (declare (ignore bid)) ""))

(defvar *buffer-insert-fn*
  (lambda (bid off str) (declare (ignore bid off str)) nil))

(defvar *buffer-delete-fn*
  (lambda (bid from to) (declare (ignore bid from to)) nil))

(defvar *point-fn*
  (lambda (bid) (declare (ignore bid)) 0))

(defvar *set-point-fn*
  (lambda (bid off) (declare (ignore bid off)) nil))

(defvar *buffer-text-len-fn*
  (lambda (bid) (declare (ignore bid)) 0))

(defvar *last-replace-count* 0
  "Number of substitutions performed by the most recent query-replace call.")

;;; ── current-buffer + narrow integration ──────────────────────────────────

(defun %current-buffer-id ()
  (let* ((pkg (find-package '#:limn/excursion))
         (fn  (and pkg (find-symbol "CURRENT-BUFFER-ID" pkg))))
    (or (and fn (fboundp fn) (funcall fn))
        (let* ((lp (find-package '#:limn/local))
               (sym (and lp (find-symbol "*CURRENT-BUFFER-ID*" lp))))
          (and sym (boundp sym) (symbol-value sym))))))

(defun %narrow-bounds ()
  "Return (values lo hi) of the current narrowing, or (values nil nil)
   when widened."
  (let* ((pkg (find-package '#:limn/excursion))
         (pmin (and pkg (find-symbol "POINT-MIN" pkg)))
         (pmax (and pkg (find-symbol "POINT-MAX" pkg)))
         (narrowed (and pkg (find-symbol "NARROWED-P" pkg))))
    (when (and pkg pmin pmax narrowed
               (fboundp pmin) (fboundp pmax) (fboundp narrowed)
               (funcall narrowed))
      (values (funcall pmin) (funcall pmax)))))

;;; ── pattern compilation ──────────────────────────────────────────────────

(defun %escape-literal (s)
  "Escape PCRE metachars in S so it matches literally."
  (with-output-to-string (out)
    (loop for c across s do
      (when (find c ".\\+*?[^]$(){}=!<>|:" :test #'char=)
        (write-char #\\ out))
      (write-char c out))))

(defun %compile-pattern (pattern &key regexp case-fold)
  "Convert PATTERN to a PCRE string ready for cl-ppcre. Returns string.
   Always prepends (?m) so ^ and $ match per-line in Emacs fashion."
  (let* ((base (cond
                 (regexp
                  ;; Use Emacs→PCRE shim from limn/regex if available.
                  (let* ((pkg (find-package '#:limn/regex))
                         (fn (and pkg (find-symbol "EMACS-REGEX-TO-PCRE" pkg))))
                    (if (and fn (fboundp fn))
                        (funcall fn pattern)
                        pattern)))
                 (t (%escape-literal pattern))))
         (flags (with-output-to-string (s)
                  (write-char #\( s) (write-char #\? s)
                  (when case-fold (write-char #\i s))
                  (when regexp (write-char #\m s))
                  (write-char #\) s))))
    ;; If flags only contains (?) (no actual flags), skip.
    (if (= (length flags) 3)
        base
        (concatenate 'string flags base))))

(defun %expand-replacement (replacement match-string reg-starts reg-ends source)
  "Expand \\N back-references in REPLACEMENT using the most recent match."
  (with-output-to-string (out)
    (let ((i 0) (n (length replacement)))
      (loop while (< i n) do
        (let ((c (char replacement i)))
          (cond
            ((and (char= c #\\) (< (1+ i) n))
             (let ((nxt (char replacement (1+ i))))
               (cond
                 ((digit-char-p nxt)
                  (let ((g (digit-char-p nxt)))
                    (cond
                      ((zerop g)
                       (write-string match-string out))
                      ((and reg-starts
                            (< (1- g) (length reg-starts))
                            (aref reg-starts (1- g))
                            (aref reg-ends (1- g)))
                       (write-string
                        (subseq source
                                (aref reg-starts (1- g))
                                (aref reg-ends   (1- g)))
                        out)))
                    (incf i 2)))
                 ((char= nxt #\\)
                  (write-char #\\ out) (incf i 2))
                 (t (write-char nxt out) (incf i 2)))))
            (t (write-char c out) (incf i))))))))

;;; ── core engine ──────────────────────────────────────────────────────────

(defstruct (qr-history
             (:constructor make-qr-history (point match-start match-end
                                            original replacement)))
  point          ; point before this replacement
  match-start    ; match begin offset (before replace)
  match-end      ; match end offset (before replace)
  original       ; original matched text
  replacement)   ; what we replaced it with

(defun %do-query-replace (pattern replacement
                          &key regexp case-fold start end response-fn)
  (let* ((bid       (%current-buffer-id))
         (pcre      (%compile-pattern pattern :regexp regexp
                                              :case-fold case-fold))
         (scanner   (cl-ppcre:create-scanner pcre))
         (initial-len (length (funcall *buffer-text-fn* bid)))
         ;; Honour narrow if no explicit start/end supplied.
         (effective-start
           (or start
               (multiple-value-bind (lo hi) (%narrow-bounds)
                 (declare (ignore hi))
                 lo)
               (funcall *point-fn* bid)))
         (effective-end
           (or end
               (multiple-value-bind (lo hi) (%narrow-bounds)
                 (declare (ignore lo))
                 hi)
               initial-len))
         (history '())
         (count 0)
         (all-mode nil)
         (point effective-start)
         (range-end effective-end))
    (funcall *set-point-fn* bid point)
    (loop
      (let* ((text  (funcall *buffer-text-fn* bid))
             (upper (min range-end (length text))))
        (when (> point upper) (return))
        (multiple-value-bind (mstart mend reg-starts reg-ends)
            (cl-ppcre:scan scanner text :start point :end upper)
          (unless mstart (return))
          (let* ((matched (subseq text mstart mend))
                 (effective (if regexp
                                (%expand-replacement replacement matched
                                                     reg-starts reg-ends text)
                                replacement))
                 (do-replace
                   (lambda ()
                     (when (> mend mstart)
                       (funcall *buffer-delete-fn* bid mstart mend))
                     (when (> (length effective) 0)
                       (funcall *buffer-insert-fn* bid mstart effective))
                     (incf count)
                     (push (make-qr-history point mstart mend
                                            matched effective)
                           history)
                     (let ((delta (- (length effective) (- mend mstart))))
                       (incf range-end delta))
                     (setf point (+ mstart (length effective)))
                     ;; Zero-length match: bump past one more char so we
                     ;; don't keep replacing at the same logical position.
                     (when (= mstart mend)
                       (incf point))
                     (funcall *set-point-fn* bid point))))
            (cond
              (all-mode
               (funcall do-replace))
              (t
               (let ((resp (and response-fn (funcall response-fn))))
                 (cond
                   ((or (null resp) (equal resp "q") (equal resp "RET"))
                    (return))
                   ((or (equal resp "y") (equal resp "SPC"))
                    (funcall do-replace))
                   ((or (equal resp "n") (equal resp "DEL"))
                    ;; Skip — advance past match (avoid infinite loop on
                    ;; zero-length match).
                    (setf point (max mend (1+ point)))
                    (funcall *set-point-fn* bid point))
                   ((equal resp "!")
                    (setf all-mode t)
                    (funcall do-replace))
                   ((equal resp ".")
                    (funcall do-replace)
                    (return))
                   ((equal resp ",")
                    ;; Replace + advance (non-interactive flavour of ,).
                    (funcall do-replace))
                   ((equal resp "^")
                    (cond
                      (history
                       (let ((h (pop history)))
                         (incf range-end (- (length (qr-history-original h))
                                            (length (qr-history-replacement h))))
                         ;; Undo the replacement.
                         (let* ((ms (qr-history-match-start h))
                                (rlen (length (qr-history-replacement h))))
                           (when (plusp rlen)
                             (funcall *buffer-delete-fn* bid ms (+ ms rlen)))
                           (when (plusp (length (qr-history-original h)))
                             (funcall *buffer-insert-fn* bid ms
                                      (qr-history-original h))))
                         (decf count)
                         (setf point (qr-history-point h))
                         (funcall *set-point-fn* bid point)))
                      (t
                       ;; No previous match — skip.
                       (setf point (max mend (1+ point))))))
                   (t
                    ;; Unknown response — treat as skip.
                    (setf point (max mend (1+ point))))))))
            ;; Safety: ensure forward progress on zero-length matches.
            (when (and (= mstart mend) (= point mstart))
              (incf point)
              (funcall *set-point-fn* bid point))))))
    (setf *last-replace-count* count)
    count))

;;; ── public API ───────────────────────────────────────────────────────────

(defun query-replace (from-string to-string
                      &key (case-fold t) start end response-fn)
  "Interactively replace occurrences of FROM-STRING with TO-STRING.
   In tests, supply RESPONSE-FN — a thunk returning the next user response
   string. Returns the substitution count."
  (%do-query-replace from-string to-string
                     :regexp nil
                     :case-fold case-fold
                     :start start :end end
                     :response-fn response-fn))

(defun query-replace-regexp (regexp to-string
                             &key (case-fold t) start end response-fn)
  "Like QUERY-REPLACE but REGEXP is an Emacs-style regular expression and
   \\N in TO-STRING expands to capture group N."
  (%do-query-replace regexp to-string
                     :regexp t
                     :case-fold case-fold
                     :start start :end end
                     :response-fn response-fn))

;;; ── runtime wireup ───────────────────────────────────────────────────────

(defvar *wire-vtable-installed* nil)

(defun %wire-call (cmd &rest kw)
  (let ((sym (find-symbol "CALL" :limn)))
    (when (and sym (fboundp sym))
      (apply (symbol-function sym) cmd kw))))

(defun %wire-resp-data (r)
  (let ((rd (find-symbol "RESPONSE-DATA" :limn/bridge)))
    (when (and rd (fboundp rd) r)
      (funcall (symbol-function rd) r))))

(defun install-wire-vtable ()
  "Bind the vtable to live wire commands. Idempotent."
  (unless *wire-vtable-installed*
    (setf *buffer-text-fn*
          (lambda (bid)
            (let* ((r (%wire-call "buffer/text" :|buffer-id| bid))
                   (d (%wire-resp-data r)))
              (or (getf d :|text|) ""))))
    (setf *buffer-insert-fn*
          (lambda (bid off str)
            (%wire-call "buffer/cursor-set" :|buffer-id| bid :|offset| off)
            (%wire-call "buffer/insert"     :|buffer-id| bid :|text|   str)))
    (setf *buffer-delete-fn*
          (lambda (bid from to)
            (%wire-call "buffer/delete" :|buffer-id| bid
                        :|from| from :|to| to)))
    (setf *point-fn*
          (lambda (bid)
            (let* ((r (%wire-call "buffer/cursor-get" :|buffer-id| bid))
                   (d (%wire-resp-data r)))
              (or (getf d :|offset|) 0))))
    (setf *set-point-fn*
          (lambda (bid off)
            (%wire-call "buffer/cursor-set" :|buffer-id| bid :|offset| off)))
    (setf *buffer-text-len-fn*
          (lambda (bid)
            (let* ((r (%wire-call "buffer/text" :|buffer-id| bid))
                   (d (%wire-resp-data r))
                   (txt (and d (getf d :|text|))))
              (if (stringp txt) (length txt) 0))))
    ;; Also wire limn/regex's vtable so query-replace and friends have a
    ;; consistent backend (replace-match calls limn/regex too).
    (let ((rpkg (find-package '#:limn/regex)))
      (when rpkg
        (dolist (pair `((,(find-symbol "*BUFFER-TEXT-FN*" rpkg) .
                         ,(symbol-value '*buffer-text-fn*))
                        (,(find-symbol "*BUFFER-SET-TEXT-FN*" rpkg) .
                         ,(lambda (bid txt)
                            ;; Emulate set-text via delete-all + insert
                            (let* ((r (%wire-call "buffer/text" :|buffer-id| bid))
                                   (d (%wire-resp-data r))
                                   (old (and d (getf d :|text|)))
                                   (n (if (stringp old) (length old) 0)))
                              (when (> n 0)
                                (%wire-call "buffer/delete" :|buffer-id| bid
                                            :|from| 0 :|to| n))
                              (%wire-call "buffer/cursor-set"
                                          :|buffer-id| bid :|offset| 0)
                              (%wire-call "buffer/insert"
                                          :|buffer-id| bid :|text| txt))))
                        (,(find-symbol "*POINT-FN*" rpkg) .
                         ,(symbol-value '*point-fn*))
                        (,(find-symbol "*SET-POINT-FN*" rpkg) .
                         ,(symbol-value '*set-point-fn*))
                        (,(find-symbol "*BUFFER-TEXT-LEN-FN*" rpkg) .
                         ,(symbol-value '*buffer-text-len-fn*))))
          (when (and (car pair) (boundp (car pair)))
            (set (car pair) (cdr pair))))))
    (setf *wire-vtable-installed* t))
  t)
