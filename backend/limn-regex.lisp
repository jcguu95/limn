;;;; limn-regex — v0.34 regex engine wrapping cl-ppcre with Emacs-style API.
;;;;
;;;; Provides:
;;;;   §B Emacs-style API: string-match / re-search-forward(/backward) /
;;;;      looking-at(/back) / re-search-in-buffer / match-string /
;;;;      match-beginning / match-end / match-data / set-match-data /
;;;;      replace-match / replace-regexp-in-string / split-string /
;;;;      search-failed condition.
;;;;   §C emacs-regex-to-pcre syntax shim — translates Emacs special
;;;;      syntax (\\(..\\) / \\| / \\b / \\< / \\> / \\sw / \\s- / \\` / \\')
;;;;      to PCRE before handing off to cl-ppcre.
;;;;
;;;; Buffer-aware operations resolve *current-buffer* via limn/excursion;
;;;; they read text + point through the vtable below so impl can be tested
;;;; against in-process mock buffers without a running Limn.
;;;;
;;;; Depends on:
;;;;   - cl-ppcre (loaded by run-unit.lisp / repl.lisp from vendor/)
;;;;   - limn/excursion (v0.32) for *current-buffer* tracking (soft-resolved
;;;;     via find-package so this module loads even if v0.32 isn't present)

(defpackage #:limn/regex
  (:use #:cl)
  (:export #:re-search-forward
           #:re-search-backward
           #:re-search-in-buffer
           #:looking-at
           #:looking-back
           #:replace-match
           #:string-match
           #:replace-regexp-in-string
           #:split-string
           #:match-string
           #:match-beginning
           #:match-end
           #:match-data
           #:set-match-data
           #:search-failed
           #:emacs-regex-to-pcre
           #:*buffer-text-fn*
           #:*buffer-set-text-fn*
           #:*point-fn*
           #:*set-point-fn*
           #:*buffer-text-len-fn*
           ;; v0.40 narrow — accessible-region bounds.  NIL means
           ;; "not narrowed" → re-search-* falls back to 0 / text-len.
           #:*point-min-fn*
           #:*point-max-fn*
           #:reset-match-data))

(in-package #:limn/regex)

;;; ── vtable hooks ──────────────────────────────────────────────────────────
;;;
;;; Buffer-aware functions go through these. Mock during tests; production
;;; wires to limn:call "buffer/text" / "buffer/cursor-get" / etc. The wire
;;; bootstrap (limn.lisp / repl.lisp) installs the real implementations.

(defvar *buffer-text-fn*
  (lambda (bid) (declare (ignore bid)) ""))

(defvar *buffer-set-text-fn*
  (lambda (bid text) (declare (ignore bid text)) nil))

(defvar *point-fn*
  (lambda (bid) (declare (ignore bid)) 0))

(defvar *set-point-fn*
  (lambda (bid off) (declare (ignore bid off)) nil))

(defvar *buffer-text-len-fn*
  (lambda (bid) (declare (ignore bid)) 0))

;; v0.40 narrow — same nil-means-no-narrow contract as limn/text-nav.
;; Rewired by limn/excursion at its load time to query buffer-local
;; narrow markers; when set, re-search-* and looking-{at,back} stay
;; inside [point-min, point-max).
(defvar *point-min-fn*
  (lambda (bid) (declare (ignore bid)) nil))

(defvar *point-max-fn*
  (lambda (bid) (declare (ignore bid)) nil))

(defun %pmin (bid) (or (funcall *point-min-fn* bid) 0))
(defun %pmax (bid text)
  "TEXT is passed in so the no-narrow fallback uses the same string the
   caller is searching over.  Avoids depending on *buffer-text-len-fn*
   being wired (existing regex tests only wire *buffer-text-fn*)."
  (or (funcall *point-max-fn* bid) (length text)))

;;; ── match-data state ──────────────────────────────────────────────────────
;;;
;;; A flat list (start0 end0 start1 end1 ... startN endN). Each pair is one
;;; group; group 0 is the whole match. Positions are integer offsets into
;;; the string the match was performed against; nil for a group that didn't
;;; participate. Empty / nil = no match yet.

(defvar *match-data* nil)

(defvar *match-string-source* nil
  "The string the last successful match was performed against — used by
   match-string when no STRING argument is supplied.")

(defun reset-match-data ()
  "Clear match state. Called between tests."
  (setf *match-data* nil)
  (setf *match-string-source* nil))

;;; ── conditions ───────────────────────────────────────────────────────────

(define-condition search-failed (error)
  ((regex :initarg :regex :reader search-failed-regex))
  (:report (lambda (c stream)
             (format stream "Search failed: ~s"
                     (search-failed-regex c)))))

;;; ── current-buffer lookup ────────────────────────────────────────────────

(defun %current-buffer-id ()
  "Resolve the wire-level buffer-id of *current-buffer* via limn/excursion.
   Returns nil if v0.32 isn't loaded or no buffer is current."
  (let* ((pkg (find-package '#:limn/excursion))
         (fn  (and pkg (find-symbol "CURRENT-BUFFER-ID" pkg))))
    (when (and fn (fboundp fn))
      (funcall fn))))

;;; ──────────────────────────────────────────────────────────────────────────
;;; §C. Emacs → PCRE syntax shim
;;; ──────────────────────────────────────────────────────────────────────────
;;;
;;; Translate Emacs regex syntax into PCRE before handing off to cl-ppcre.
;;; Stays single-pass / no regex-on-regex — pure char-by-char rewrite.
;;;
;;; Mapping summary:
;;;   \(  \)  \|       — group/alternation        →   (  )  |
;;;   ( ) |  (literal) — Emacs literal, PCRE meta →   \(  \)  \|
;;;   \b  \B  \w  \W  — boundary/class            →   passthrough
;;;   \<  \>           — word-start / word-end    →   \b (approximation)
;;;   \s-              — Emacs syntax-class WS    →   \s
;;;   \sw              — Emacs syntax-class word  →   \w
;;;   \s.              — Emacs syntax-class punct →   [[:punct:]]
;;;   \s<other>        — other syntax classes     →   \s (loose mapping)
;;;   \`               — buffer/string start      →   \A
;;;   \'               — buffer/string end        →   \z
;;;   \\               — literal backslash        →   \\
;;;   \<other>         — preserve escape          →   \<other>

(defun emacs-regex-to-pcre (pat)
  "Translate Emacs regex syntax in PAT to PCRE syntax. Pure string op."
  (with-output-to-string (out)
    (let ((i 0)
          (n (length pat)))
      (loop while (< i n) do
        (let ((c (char pat i)))
          (cond
            ;; ── backslash-prefixed sequences ─────────────────────────────
            ((char= c #\\)
             (if (>= (1+ i) n)
                 ;; trailing lone backslash — emit as-is
                 (progn (write-char #\\ out) (incf i))
                 (let ((next (char pat (1+ i))))
                   (case next
                     ((#\( #\))                       ; group delimiters
                      (write-char next out)
                      (incf i 2))
                     (#\|                             ; alternation
                      (write-char #\| out)
                      (incf i 2))
                     (#\<                             ; word start
                      (write-string "\\b" out)
                      (incf i 2))
                     (#\>                             ; word end
                      (write-string "\\b" out)
                      (incf i 2))
                     (#\`                             ; buffer start
                      (write-string "\\A" out)
                      (incf i 2))
                     (#\'                             ; buffer end
                      (write-string "\\z" out)
                      (incf i 2))
                     (#\\                             ; literal backslash
                      (write-string "\\\\" out)
                      (incf i 2))
                     (#\s                             ; Emacs syntax class
                      (cond
                        ((>= (+ i 2) n)
                         (write-string "\\s" out) (incf i 2))
                        (t
                         (let ((class (char pat (+ i 2))))
                           (cond
                             ((char= class #\-)
                              (write-string "\\s" out)
                              (incf i 3))
                             ((char= class #\w)
                              (write-string "\\w" out)
                              (incf i 3))
                             ((char= class #\.)
                              (write-string "[[:punct:]]" out)
                              (incf i 3))
                             (t
                              ;; Unknown Emacs syntax class — loose map
                              ;; to PCRE \s; we don't have a faithful
                              ;; equivalent for all of Emacs' classes.
                              (write-string "\\s" out)
                              (incf i 3)))))))
                     (otherwise
                      ;; Preserve the escape. Covers \b \B \w \W \. \? \*
                      ;; \+ \^ \$ \d \D and any other PCRE-compatible
                      ;; escape, plus literals like \. that Emacs uses for
                      ;; "literal dot".
                      (write-char #\\ out)
                      (write-char next out)
                      (incf i 2))))))
            ;; ── bare meta in PCRE that's literal in Emacs ────────────────
            ((or (char= c #\() (char= c #\)) (char= c #\|))
             (write-char #\\ out)
             (write-char c out)
             (incf i))
            ;; ── pass-through ─────────────────────────────────────────────
            (t
             (write-char c out)
             (incf i))))))))

;;; ──────────────────────────────────────────────────────────────────────────
;;; §B.1 string-match + match-data helpers
;;; ──────────────────────────────────────────────────────────────────────────

(defun %install-match-data (mstart mend reg-starts reg-ends source)
  "Capture cl-ppcre scan result into *match-data* + *match-string-source*."
  (setf *match-string-source* source)
  (setf *match-data*
        (cons mstart
              (cons mend
                    (loop for s across reg-starts
                          for e across reg-ends
                          collect s collect e)))))

(defun string-match (regex string &optional (start 0))
  "Find first match of REGEX in STRING starting at START. Sets match-data
   on success; returns the match start position (integer) or nil."
  (let ((pcre (emacs-regex-to-pcre regex)))
    (multiple-value-bind (mstart mend reg-starts reg-ends)
        (cl-ppcre:scan pcre string :start start)
      (cond
        ((null mstart)
         ;; leave match-data as-is per Emacs spec (some impls clear it; we
         ;; explicitly invalidate group 0 so subsequent match-beginning
         ;; returns nil-ish)
         (setf *match-data* nil)
         (setf *match-string-source* nil)
         nil)
        (t
         (%install-match-data mstart mend reg-starts reg-ends string)
         mstart)))))

(defun match-string (n &optional string)
  "Return the N'th group from the last match, or nil."
  (let ((src (or string *match-string-source*)))
    (when (and *match-data* src)
      (let ((idx (* n 2)))
        (when (< (1+ idx) (length *match-data*))
          (let ((s (nth idx *match-data*))
                (e (nth (1+ idx) *match-data*)))
            (when (and s e (<= s (length src)) (<= e (length src)))
              (subseq src s e))))))))

(defun match-beginning (n)
  "Return the start offset of the N'th group of the last match, or nil."
  (when *match-data*
    (let ((idx (* n 2)))
      (when (< idx (length *match-data*))
        (nth idx *match-data*)))))

(defun match-end (n)
  "Return the end offset of the N'th group of the last match, or nil."
  (when *match-data*
    (let ((idx (1+ (* n 2))))
      (when (< idx (length *match-data*))
        (nth idx *match-data*)))))

(defun match-data (&optional integers)
  "Snapshot the current match data as a fresh list."
  (declare (ignore integers))
  (copy-list *match-data*))

(defun set-match-data (data)
  "Restore match data from DATA (as returned by match-data)."
  (setf *match-data* (copy-list data))
  data)

;;; ──────────────────────────────────────────────────────────────────────────
;;; §B.2 re-search-forward / re-search-backward / re-search-in-buffer
;;; ──────────────────────────────────────────────────────────────────────────

(defun %scan-once (pcre text start end)
  "Wrap cl-ppcre:scan, returning (values mstart mend reg-starts reg-ends)
   or all nil if no match."
  (cl-ppcre:scan pcre text :start start :end end))

(defun re-search-forward (regex &optional bound noerror count)
  "Search forward for REGEX from *current-buffer*'s point. On success: set
   point to match end, install match-data, return new point. On failure:
   if NOERROR is nil, signal SEARCH-FAILED; if t, return nil; otherwise
   return nil. Point is unchanged on failure. BOUND, if given, is the
   upper search limit. COUNT (default 1) iterates the search.
   v0.40: when BOUND is omitted, defaults to (point-max) so the search
   stays inside the accessible region; an explicit BOUND is still
   honoured, but is clipped to point-max."
  (let* ((bid   (%current-buffer-id))
         (text  (funcall *buffer-text-fn* bid))
         (point (funcall *point-fn* bid))
         (pcre  (emacs-regex-to-pcre regex))
         (c     (or count 1))
         (pmax  (%pmax bid text))
         (upper (if bound (min bound pmax) pmax))
         (cursor point)
         (last-end nil))
    (when (> cursor upper)
      ;; Point sits outside the accessible region (e.g. a recent
      ;; narrow shrank past it).  No forward match possible.
      (cond
        ((null noerror) (error 'search-failed :regex regex))
        (t (return-from re-search-forward nil))))
    (dotimes (_ c)
      (multiple-value-bind (mstart mend reg-starts reg-ends)
          (%scan-once pcre text cursor upper)
        (cond
          ((null mstart)
           (cond
             ((null noerror) (error 'search-failed :regex regex))
             (t (return-from re-search-forward nil))))
          (t
           (%install-match-data mstart mend reg-starts reg-ends text)
           (setf last-end mend)
           (setf cursor   mend)))))
    (when last-end
      (funcall *set-point-fn* bid last-end)
      last-end)))

(defun re-search-backward (regex &optional bound noerror count)
  "Search backward for REGEX from *current-buffer*'s point. On success:
   set point to match start. BOUND, if given, is the lower search limit;
   matches whose start is < BOUND are rejected.
   v0.40: when BOUND is omitted, defaults to (point-min); an explicit
   BOUND is honoured but clamped to >= point-min."
  (let* ((bid   (%current-buffer-id))
         (text  (funcall *buffer-text-fn* bid))
         (point (funcall *point-fn* bid))
         (pcre  (emacs-regex-to-pcre regex))
         (c     (or count 1))
         (pmin  (%pmin bid))
         (lower (if bound (max bound pmin) pmin))
         (cursor point)
         (last-start nil))
    (when (< cursor lower)
      ;; Point sits before the accessible region.  No backward match
      ;; possible.
      (cond
        ((null noerror) (error 'search-failed :regex regex))
        (t (return-from re-search-backward nil))))
    (dotimes (_ c)
      (let ((all (cl-ppcre:all-matches pcre text
                                        :start lower
                                        :end cursor)))
        (cond
          ((null all)
           (cond
             ((null noerror) (error 'search-failed :regex regex))
             (t (return-from re-search-backward nil))))
          (t
           ;; all is flat (s0 e0 s1 e1 ... sN eN). Take last pair.
           (let* ((len (length all))
                  (s   (nth (- len 2) all))
                  (e   (nth (- len 1) all)))
             ;; Re-scan at that location to capture group data.
             (multiple-value-bind (mstart mend reg-starts reg-ends)
                 (%scan-once pcre text s (max e (1+ s)))
               (let ((true-end (or e mend)))
                 (%install-match-data (or mstart s) true-end
                                      reg-starts reg-ends text)))
             (setf last-start s)
             (setf cursor s))))))
    (when last-start
      (funcall *set-point-fn* bid last-start)
      last-start)))

(defun re-search-in-buffer (regex buf-id)
  "Find first match of REGEX in BUF-ID, without changing *current-buffer*.
   Sets match-data; returns match-end on success, nil otherwise.
   v0.40: respects BUF-ID's narrowing — only matches inside
   [point-min, point-max) qualify."
  (let* ((text (funcall *buffer-text-fn* buf-id))
         (pcre (emacs-regex-to-pcre regex))
         (lo   (%pmin buf-id))
         (hi   (%pmax buf-id text)))
    (multiple-value-bind (mstart mend reg-starts reg-ends)
        (%scan-once pcre text lo hi)
      (cond
        ((null mstart) nil)
        (t (%install-match-data mstart mend reg-starts reg-ends text)
           mend)))))

;;; ──────────────────────────────────────────────────────────────────────────
;;; §B.3 looking-at / looking-back
;;; ──────────────────────────────────────────────────────────────────────────

(defun looking-at (regex)
  "Return t iff REGEX matches text starting exactly at *current-buffer*'s
   point. Point is NOT moved. Installs match-data on success.
   v0.40: the implicit upper search bound is (point-max), so a match
   that would extend past the accessible region is rejected."
  (let* ((bid   (%current-buffer-id))
         (text  (funcall *buffer-text-fn* bid))
         (point (funcall *point-fn* bid))
         (pmax  (%pmax bid text))
         (pcre  (emacs-regex-to-pcre regex)))
    (multiple-value-bind (mstart mend reg-starts reg-ends)
        (%scan-once pcre text point pmax)
      (cond
        ((and mstart (= mstart point) (<= mend pmax))
         (%install-match-data mstart mend reg-starts reg-ends text)
         t)
        (t nil)))))

(defun looking-back (regex &optional limit)
  "Return t iff REGEX matches text ending exactly at *current-buffer*'s
   point. Scan starts from LIMIT (default (point-min)). Point is NOT
   moved.
   v0.40: when LIMIT is omitted, defaults to (point-min); an explicit
   LIMIT is clamped up to point-min."
  (let* ((bid   (%current-buffer-id))
         (text  (funcall *buffer-text-fn* bid))
         (point (funcall *point-fn* bid))
         (pmin  (%pmin bid))
         (lower (if limit (max limit pmin) pmin))
         (pcre  (emacs-regex-to-pcre regex)))
    (loop for start from lower upto point do
      (multiple-value-bind (mstart mend reg-starts reg-ends)
          (%scan-once pcre text start point)
        (when (and mstart (= mstart start) (= mend point))
          (%install-match-data mstart mend reg-starts reg-ends text)
          (return-from looking-back t))))
    nil))

;;; ──────────────────────────────────────────────────────────────────────────
;;; §B.4 replace-match / replace-regexp-in-string / split-string
;;; ──────────────────────────────────────────────────────────────────────────

(defun %expand-back-refs (replacement)
  "Walk REPLACEMENT; expand \\N to match-string N. Bare \\\\ → literal \\.
   Used by replace-match in non-LITERAL mode."
  (with-output-to-string (out)
    (let ((i 0)
          (n (length replacement)))
      (loop while (< i n) do
        (let ((c (char replacement i)))
          (cond
            ((and (char= c #\\) (< (1+ i) n))
             (let ((next (char replacement (1+ i))))
               (cond
                 ((digit-char-p next)
                  (let* ((group (digit-char-p next))
                         (val   (match-string group)))
                    (when val (write-string val out))
                    (incf i 2)))
                 ((char= next #\\)
                  (write-char #\\ out)
                  (incf i 2))
                 (t
                  (write-char next out)
                  (incf i 2)))))
            (t
             (write-char c out)
             (incf i))))))))

(defun replace-match (replacement &optional fixedcase literal)
  "Replace the most recent match in *current-buffer* with REPLACEMENT.
   In default mode (LITERAL nil), \\N in REPLACEMENT expands to capture
   group N. FIXEDCASE suppresses case-folding (we don't fold by default;
   flag accepted for API parity)."
  (declare (ignore fixedcase))
  (when *match-data*
    (let* ((bid    (%current-buffer-id))
           (text   (funcall *buffer-text-fn* bid))
           (mstart (first *match-data*))
           (mend   (second *match-data*))
           (effective (cond
                        (literal replacement)
                        (t (%expand-back-refs replacement))))
           (new-text (concatenate 'string
                                  (subseq text 0 mstart)
                                  effective
                                  (subseq text mend))))
      (funcall *buffer-set-text-fn* bid new-text)
      ;; Also keep match-data consistent for chained replacements: the
      ;; "match end" in the new buffer is mstart + length of replacement.
      (let ((new-end (+ mstart (length effective))))
        (setf *match-data*
              (cons mstart (cons new-end (cdddr *match-data*))))
        (funcall *set-point-fn* bid new-end))
      new-text)))

(defun replace-regexp-in-string (regex replacement string
                                 &key fixedcase literal)
  "Pure-string global replace. \\N in REPLACEMENT expands to capture group
   N (unless LITERAL). Returns a new string; STRING is untouched."
  (declare (ignore fixedcase))
  (let ((pcre (emacs-regex-to-pcre regex)))
    (cond
      (literal
       (cl-ppcre:regex-replace-all pcre string replacement
                                    :simple-calls t))
      (t
       ;; cl-ppcre's replacement strings interpret \1, \2 ... as
       ;; back-references natively — same as Emacs after Lisp reader has
       ;; collapsed \\1 to \1. Just pass through.
       (cl-ppcre:regex-replace-all pcre string replacement)))))

(defun split-string (string &optional (separator-regex "[ \\t\\n]+")
                              (omit-nulls nil))
  "Split STRING on SEPARATOR-REGEX. With OMIT-NULLS, drop empty pieces."
  (let* ((pcre  (emacs-regex-to-pcre separator-regex))
         (parts (cl-ppcre:split pcre string)))
    (cond
      (omit-nulls (remove-if (lambda (s) (string= s "")) parts))
      (t parts))))

;;; ── v0.40 narrow integration ─────────────────────────────────────────
;;;
;;; limn-regex loads AFTER limn-excursion (see limn.asd), so excursion's
;;; load-time patcher can't reach us.  Wire ourselves here, late-bound
;;; via find-symbol so this stays a soft dependency.

(eval-when (:load-toplevel :execute)
  (let ((ex (find-package '#:limn/excursion)))
    (when ex
      (let ((nstart (find-symbol "NARROW-START-OF" ex))
            (nend   (find-symbol "NARROW-END-OF"   ex)))
        (when (and nstart (fboundp nstart))
          (setf *point-min-fn*
                (lambda (bid) (and bid (funcall nstart bid)))))
        (when (and nend (fboundp nend))
          (setf *point-max-fn*
                (lambda (bid) (and bid (funcall nend bid)))))))))
