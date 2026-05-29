;;;; limn-occur — line-based search buffer (v0.26 §B)
;;;;
;;;; Pure-Lisp stateless functional API.  All buffer I/O goes through
;;;; dynamic vtable vars for test isolation.
;;;;
;;;; One occur-match per matching line; match-start/end are offsets
;;;; within the line; offset is the absolute codepoint position from
;;;; buffer start.  Calling OCCUR writes to *occur-write-fn* immediately.

(defpackage #:limn/occur
  (:use #:cl)
  (:export
   ;; main entry
   #:occur
   ;; state accessors
   #:occur-results
   #:occur-count
   #:occur-current
   #:occur-source-buf-id
   #:occur-occur-buf-id
   ;; navigation
   #:occur-next
   #:occur-prev
   #:occur-jump
   ;; match record
   #:occur-match-p
   #:occur-match-line-num
   #:occur-match-line-text
   #:occur-match-start
   #:occur-match-end
   #:occur-match-offset
   ;; formatting
   #:format-occur-results
   #:format-occur-line
   ;; I/O vtable
   #:*buffer-text-fn*
   #:*buffer-set-cursor-fn*
   #:*occur-write-fn*
   ;; v0.40 narrow — accessible-region bounds (NIL = no narrowing)
   #:*point-min-fn* #:*point-max-fn*))

(in-package #:limn/occur)

;;; ── vtable ──────────────────────────────────────────────────────────────────

(defvar *buffer-text-fn*
  (lambda (bid) (declare (ignore bid)) "")
  "fn (buf-id) → string — full buffer text")

(defvar *buffer-set-cursor-fn*
  (lambda (bid off) (declare (ignore bid off)))
  "fn (buf-id offset) → void — move cursor in source buffer")

(defvar *occur-write-fn*
  (lambda (obid content) (declare (ignore obid content)))
  "fn (occur-buf-id content) → void — write formatted results to *occur* buffer")

;; v0.40 narrow — same nil-means-no-narrow contract as limn/text-nav.
;; Rewired at limn/excursion load time.  When set, occur only reports
;; matches whose absolute [start, end) lies inside [point-min, point-max).
(defvar *point-min-fn*
  (lambda (bid) (declare (ignore bid)) nil))

(defvar *point-max-fn*
  (lambda (bid) (declare (ignore bid)) nil))

;;; ── match struct ────────────────────────────────────────────────────────────

(defstruct (occur-match
            (:constructor %make-occur-match
                (&key line-num line-text start end offset)))
  (line-num  0 :type integer)
  (line-text "" :type string)
  (start     0 :type integer)   ; within-line offset of first match
  (end       0 :type integer)   ; within-line exclusive end
  (offset    0 :type integer))  ; absolute codepoint offset from buf start

;;; ── state struct ────────────────────────────────────────────────────────────

(defstruct (occur-state
            (:constructor %make-occur-state
                (&key source-buf-id results current)))
  source-buf-id
  (occur-buf-id "*occur*" :type string)
  (results '())
  (current nil))     ; 0-based integer or nil when no results

;;; ── internal helpers ────────────────────────────────────────────────────────

;; ── minimal built-in regexp engine (used when cl-ppcre unavailable) ─────────
;;
;; Supports: plain chars, '.', '[...]' / '[^...]' character classes,
;;           '*' '+' '?' quantifiers, '^' start anchor.  No groups.
;; Invalid patterns return NIL without signalling.

(defun %rx-parse-class (pat i)
  "Parse [...] at position I (after '[').  Return (match-fn new-i)."
  (let ((negate nil) (chars '()) (ranges '()) (j i))
    (when (and (< j (length pat)) (char= (char pat j) #\^))
      (setf negate t) (incf j))
    (loop while (and (< j (length pat)) (not (char= (char pat j) #\])))
          do (let ((c (char pat j)))
               (if (and (< (+ j 2) (length pat))
                        (char= (char pat (1+ j)) #\-)
                        (not (char= (char pat (+ j 2)) #\])))
                   (progn (push (cons c (char pat (+ j 2))) ranges) (incf j 3))
                   (progn (push c chars) (incf j)))))
    (when (and (< j (length pat)) (char= (char pat j) #\])) (incf j))
    (let ((cs chars) (rs ranges) (ng negate))
      (values (lambda (c)
                (let ((hit (or (member c cs :test #'char=)
                               (some (lambda (r) (char<= (car r) c (cdr r))) rs))))
                  (if ng (not hit) hit)))
              j))))

(defun %rx-match (pat pp text tp)
  "Match PAT[pp..] against TEXT[tp..].  Return end pos or NIL."
  (when (= pp (length pat)) (return-from %rx-match tp))
  (let ((pc (char pat pp)))
    (cond
      ((char= pc #\$)
       (when (= tp (length text)) tp))
      (t
       (multiple-value-bind (mfn next-pp)
           (cond
             ((char= pc #\.)
              (values (lambda (c) (declare (ignore c)) t) (1+ pp)))
             ((char= pc #\[)
              (handler-case (%rx-parse-class pat (1+ pp))
                (error () (return-from %rx-match nil))))
             (t
              (let ((ch pc))
                (values (lambda (c) (char= c ch)) (1+ pp)))))
         (let ((q (and (< next-pp (length pat))
                       (member (char pat next-pp) '(#\* #\+ #\?) :test #'char=)
                       (char pat next-pp))))
           (if q
               (let ((qnext (1+ next-pp))
                     (min-c (if (char= q #\+) 1 0))
                     (max-c (if (char= q #\?) 1 most-positive-fixnum)))
                 (let ((end tp))
                   (loop while (and (< end (length text))
                                    (funcall mfn (char text end))
                                    (< (- end tp) max-c))
                         do (incf end))
                   (loop for e from end downto (+ tp min-c)
                         for r = (%rx-match pat qnext text e)
                         when r return r
                         finally (return nil))))
               (when (and (< tp (length text)) (funcall mfn (char text tp)))
                 (%rx-match pat next-pp text (1+ tp))))))))))

(defun %simple-regexp-search (pattern text)
  "Try to match PATTERN anywhere in TEXT.  Return (start end) or NIL."
  (let* ((anchored (and (> (length pattern) 0)
                        (char= (char pattern 0) #\^)))
         (pat      (if anchored (subseq pattern 1) pattern)))
    (handler-case
        (if anchored
            (let ((e (%rx-match pat 0 text 0)))
              (when e (list 0 e)))
            (loop for s from 0 to (length text)
                  for e = (%rx-match pat 0 text s)
                  when e return (list s e)))
      (error () nil))))

(defun %regexp-scan (pattern text)
  "Return (start end) via cl-ppcre:scan if available; else use built-in engine."
  (let ((scan-fn (and (find-package '#:cl-ppcre)
                      (find-symbol "SCAN" '#:cl-ppcre))))
    (if scan-fn
        (handler-case
            (multiple-value-bind (s e)
                (funcall scan-fn pattern text)
              (when s (list s e)))
          (error () nil))
        (%simple-regexp-search pattern text))))

(defun %search-in-line (pattern line &key regexp)
  "Return (start end) within LINE or NIL.  regexp uses cl-ppcre if available."
  (if regexp
      (%regexp-scan pattern line)
      ;; plain string search, case-insensitive
      (let* ((p   (string-downcase pattern))
             (l   (string-downcase line))
             (pos (search p l :test #'char=)))
        (when pos (list pos (+ pos (length pattern)))))))

(defun %scan-buffer (buf-id pattern &key regexp)
  "Return a list of OCCUR-MATCH for every line in the buffer text
   that contains PATTERN.
   v0.40: when BUF-ID is narrowed, only matches whose absolute
   [match-start, match-end) lies fully inside [point-min, point-max)
   are reported.  Line numbers stay absolute (relative to the whole
   buffer)."
  (let* ((text   (funcall *buffer-text-fn* buf-id))
         (lo     (or (funcall *point-min-fn* buf-id) 0))
         (hi     (or (funcall *point-max-fn* buf-id) (length text)))
         (lines  (if (string= text "")
                     '()
                     ;; split on newlines, keeping empty trailing line out
                     (let ((result '())
                           (start 0)
                           (tlen  (length text)))
                       (loop for i from 0 to (1- tlen) do
                         (when (char= (char text i) #\Newline)
                           (push (subseq text start i) result)
                           (setf start (1+ i))))
                       ;; last segment (may be empty)
                       (when (< start tlen)
                         (push (subseq text start) result))
                       (nreverse result))))
         (matches '())
         (abs-off 0))
    (loop for line in lines
          for line-num from 1
          do (let ((found (%search-in-line pattern line :regexp regexp)))
               (when found
                 (let* ((m-abs-s (+ abs-off (first found)))
                        (m-abs-e (+ abs-off (second found))))
                   ;; v0.40: filter out matches outside narrow.
                   (when (and (>= m-abs-s lo) (<= m-abs-e hi))
                     (push (%make-occur-match
                            :line-num  line-num
                            :line-text line
                            :start     (first found)
                            :end       (second found)
                            :offset    m-abs-s)
                           matches)))))
             ;; advance past this line + newline separator
             (incf abs-off (1+ (length line))))
    (nreverse matches)))

;;; ── formatting ──────────────────────────────────────────────────────────────

(defun format-occur-line (num text start end)
  "Format one occur result line for human display."
  (declare (ignore start end))
  (format nil "~4d: ~a" num text))

(defun format-occur-results (state)
  "Produce the full formatted string for all occur results."
  (let ((results (occur-state-results state)))
    (if (null results)
        (format nil "No matches.")
        (with-output-to-string (s)
          (dolist (m results)
            (format s "~a~%"
                    (format-occur-line
                     (occur-match-line-num m)
                     (occur-match-line-text m)
                     (occur-match-start m)
                     (occur-match-end m))))))))

;;; ── public API ──────────────────────────────────────────────────────────────

(defun occur (buf-id pattern &key regexp)
  "Search BUF-ID for PATTERN (line-based).  Returns an occur-state.
   Calls *occur-write-fn* with formatted content immediately."
  (let* ((results (handler-case (%scan-buffer buf-id pattern :regexp regexp)
                    (error () '())))
         (state   (%make-occur-state
                   :source-buf-id buf-id
                   :results       results
                   :current       (if results 0 nil)))
         (content (format-occur-results state)))
    (funcall *occur-write-fn* "*occur*" content)
    state))

(defun occur-results (state)
  (occur-state-results state))

(defun occur-count (state)
  (length (occur-state-results state)))

(defun occur-current (state)
  (occur-state-current state))

(defun occur-source-buf-id (state)
  (occur-state-source-buf-id state))

(defun occur-occur-buf-id (state)
  (occur-state-occur-buf-id state))

(defun occur-next (state)
  "Advance to next result (wraps).  Returns updated state."
  (let* ((n       (occur-count state))
         (current (occur-state-current state)))
    (when (zerop n) (return-from occur-next state))
    (%make-occur-state
     :source-buf-id (occur-state-source-buf-id state)
     :results       (occur-state-results state)
     :current       (mod (1+ current) n))))

(defun occur-prev (state)
  "Move to previous result (wraps).  Returns updated state."
  (let* ((n       (occur-count state))
         (current (occur-state-current state)))
    (when (zerop n) (return-from occur-prev state))
    (%make-occur-state
     :source-buf-id (occur-state-source-buf-id state)
     :results       (occur-state-results state)
     :current       (mod (1- current) n))))

(defun occur-jump (state)
  "Move source buffer cursor to current match's absolute offset.
   No-op when there are no results."
  (let* ((current (occur-state-current state))
         (results (occur-state-results state)))
    (when (and current results)
      (let ((match (nth current results)))
        (funcall *buffer-set-cursor-fn*
                 (occur-state-source-buf-id state)
                 (occur-match-offset match))))))
