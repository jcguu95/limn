;;;; limn-isearch — incremental search (v0.26 §A)
;;;;
;;;; Pure-Lisp stateless functional API.  All buffer I/O goes through
;;;; dynamic vtable vars so the module is testable without a running Qt.
;;;;
;;;; State machine:
;;;;   isearch-start → isearch-update ↔ isearch-next/isearch-prev
;;;;                                   → isearch-exit / isearch-abort

(defpackage #:limn/isearch
  (:use #:cl)
  (:export
   ;; entry points
   #:isearch-start
   #:isearch-update
   #:isearch-next
   #:isearch-prev
   #:isearch-exit
   #:isearch-abort
   ;; state accessors
   #:isearch-matches
   #:isearch-current-match
   #:isearch-current-index
   #:isearch-query
   #:isearch-active-p
   #:isearch-saved-cursor
   #:isearch-forward-p
   #:isearch-buf-id
   ;; I/O vtable
   #:*buffer-text-fn*
   #:*buffer-cursor-fn*
   #:*buffer-set-cursor-fn*
   #:*highlight-fn*
   #:*clear-highlights-fn*
   #:*history-push-fn*
   #:*isearch-case-fold*
   ;; v0.40 narrow — accessible-region bounds (NIL = no narrowing)
   #:*point-min-fn*
   #:*point-max-fn*))

(in-package #:limn/isearch)

;;; ── vtable ──────────────────────────────────────────────────────────────────

(defvar *buffer-text-fn*
  (lambda (bid) (declare (ignore bid)) "")
  "fn (buf-id) → string — read full buffer text")

(defvar *buffer-cursor-fn*
  (lambda (bid) (declare (ignore bid)) 0)
  "fn (buf-id) → integer — current cursor codepoint offset")

(defvar *buffer-set-cursor-fn*
  (lambda (bid off) (declare (ignore bid off)))
  "fn (buf-id offset) → void — move cursor")

(defvar *highlight-fn*
  (lambda (bid spans face) (declare (ignore bid spans face)))
  "fn (buf-id spans face) → void — paint highlight spans")

(defvar *clear-highlights-fn*
  (lambda (bid) (declare (ignore bid)))
  "fn (buf-id) → void — remove all isearch highlights")

(defvar *history-push-fn*
  (lambda (q) (declare (ignore q)))
  "fn (query) → void — add query to search history")

(defvar *isearch-case-fold* t
  "When true, search is case-insensitive.")

;; v0.40 narrow — accessible-region bounds.  Same nil-means-no-narrow
;; contract as limn/text-nav; rewired at limn/excursion load time.
(defvar *point-min-fn*
  (lambda (bid) (declare (ignore bid)) nil)
  "fn (buf-id) → integer | nil — start of accessible region, NIL = 0")

(defvar *point-max-fn*
  (lambda (bid) (declare (ignore bid)) nil)
  "fn (buf-id) → integer | nil — end of accessible region, NIL = (length text)")

;;; ── state struct ────────────────────────────────────────────────────────────

(defstruct (isearch-state
            (:constructor %make-isearch-state
                (&key buf-id saved-cursor query matches
                      current-index forward-p active-p)))
  buf-id
  saved-cursor
  (query        ""   :type string)
  (matches      '())          ; list of (start . end) codepoint conses
  (current-index 0   :type integer)
  (forward-p    t)
  (active-p     t))

;;; ── internal helpers ────────────────────────────────────────────────────────

(defun %find-matches (text query case-fold &optional (lo 0) (hi nil))
  "Return all (start . end) matches of QUERY in TEXT, allowing overlaps.
   When LO / HI are given, only matches fully contained in [LO, HI) are
   returned — this is how narrow-to-region restricts isearch to the
   accessible region.  HI defaults to (length text)."
  (when (or (string= query "") (string= text ""))
    (return-from %find-matches '()))
  (let* ((q     (if case-fold (string-downcase query) query))
         (tx    (if case-fold (string-downcase text)  text))
         (qlen  (length q))
         (tlen  (length tx))
         (hi    (or hi tlen))
         (limit (min (- tlen qlen) (- hi qlen)))
         (res   '()))
    (loop for i from lo to limit
          when (string= tx q :start1 i :end1 (+ i qlen))
            do (push (cons i (+ i qlen)) res))
    (nreverse res)))

(defun %nearest-match-forward (matches cursor)
  "Index of first match at or after CURSOR; 0 if none found (wrap)."
  (or (position-if (lambda (m) (>= (car m) cursor)) matches)
      0))

(defun %nearest-match-backward (matches cursor)
  "Index of last match at or before CURSOR; last index if none (wrap)."
  (let ((last-before
          (loop for i from (1- (length matches)) downto 0
                when (<= (car (nth i matches)) cursor)
                  return i)))
    (or last-before (1- (length matches)))))

(defun %set-cursor (buf-id offset)
  (funcall *buffer-set-cursor-fn* buf-id offset))

(defun %clear-highlights (buf-id)
  (funcall *clear-highlights-fn* buf-id))

(defun %paint-highlights (buf-id matches current-idx)
  "Call *highlight-fn* using keyword face symbols for portability."
  (when (null matches) (return-from %paint-highlights))
  (let ((all-spans (mapcar (lambda (m) (list (car m) (cdr m))) matches)))
    (funcall *highlight-fn* buf-id all-spans :isearch))
  (when (and current-idx (< current-idx (length matches)))
    (let* ((cm    (nth current-idx matches))
           (cspan (list (list (car cm) (cdr cm)))))
      (funcall *highlight-fn* buf-id cspan :isearch-current))))

;;; ── public API ──────────────────────────────────────────────────────────────

(defun isearch-start (buf-id &key (forward t))
  "Begin an incremental search session on BUF-ID.
   Records the current cursor position as saved-cursor."
  (let ((cursor (funcall *buffer-cursor-fn* buf-id)))
    (%make-isearch-state
     :buf-id       buf-id
     :saved-cursor cursor
     :query        ""
     :matches      '()
     :current-index 0
     :forward-p    forward
     :active-p     t)))

(defun isearch-update (state query)
  "Recompute matches for QUERY, move cursor to best match, repaint.
   Returns a fresh state (original STATE is not mutated).
   v0.40: when the buffer is narrowed, matches are restricted to
   [point-min, point-max)."
  (let* ((buf-id   (isearch-state-buf-id state))
         (forward  (isearch-state-forward-p state))
         (saved    (isearch-state-saved-cursor state))
         (text     (funcall *buffer-text-fn* buf-id))
         (lo       (or (funcall *point-min-fn* buf-id) 0))
         (hi       (or (funcall *point-max-fn* buf-id) (length text)))
         (matches  (if (string= query "")
                       '()
                       (%find-matches text query *isearch-case-fold*
                                      lo hi)))
         (idx      (cond
                     ((null matches) 0)
                     (forward        (%nearest-match-forward  matches saved))
                     (t              (%nearest-match-backward matches saved))))
         (new-st   (%make-isearch-state
                    :buf-id        buf-id
                    :saved-cursor  saved
                    :query         query
                    :matches       matches
                    :current-index idx
                    :forward-p     forward
                    :active-p      t)))
    ;; move cursor
    (when matches
      (%set-cursor buf-id (car (nth idx matches))))
    ;; repaint (clear only happens on exit/abort; here we just repaint)
    (when matches
      (%paint-highlights buf-id matches idx))
    new-st))

(defun isearch-next (state)
  "Advance to the next match (wraps).  Returns updated state."
  (let* ((matches (isearch-state-matches state))
         (n       (length matches)))
    (when (zerop n) (return-from isearch-next state))
    (let* ((idx     (mod (1+ (isearch-state-current-index state)) n))
           (new-st  (%make-isearch-state
                     :buf-id        (isearch-state-buf-id state)
                     :saved-cursor  (isearch-state-saved-cursor state)
                     :query         (isearch-state-query state)
                     :matches       matches
                     :current-index idx
                     :forward-p     (isearch-state-forward-p state)
                     :active-p      t)))
      (%set-cursor (isearch-state-buf-id state) (car (nth idx matches)))
      (%paint-highlights (isearch-state-buf-id state) matches idx)
      new-st)))

(defun isearch-prev (state)
  "Move to the previous match (wraps).  Returns updated state."
  (let* ((matches (isearch-state-matches state))
         (n       (length matches)))
    (when (zerop n) (return-from isearch-prev state))
    (let* ((idx    (mod (1- (isearch-state-current-index state)) n))
           (new-st (%make-isearch-state
                    :buf-id        (isearch-state-buf-id state)
                    :saved-cursor  (isearch-state-saved-cursor state)
                    :query         (isearch-state-query state)
                    :matches       matches
                    :current-index idx
                    :forward-p     (isearch-state-forward-p state)
                    :active-p      t)))
      (%set-cursor (isearch-state-buf-id state) (car (nth idx matches)))
      (%paint-highlights (isearch-state-buf-id state) matches idx)
      new-st)))

(defun isearch-exit (state)
  "Confirm search: leave cursor where it is, push to history, clear highlights.
   Mutates STATE's active-p to nil."
  (%clear-highlights (isearch-state-buf-id state))
  (let ((q       (isearch-state-query state))
        (matches (isearch-state-matches state)))
    (when (and (not (string= q "")) matches)
      (funcall *history-push-fn* q)))
  (setf (isearch-state-active-p state) nil))

(defun isearch-abort (state)
  "Cancel search: restore cursor to saved position, clear highlights.
   Mutates STATE's active-p to nil."
  (%clear-highlights (isearch-state-buf-id state))
  (%set-cursor (isearch-state-buf-id state)
               (isearch-state-saved-cursor state))
  (setf (isearch-state-active-p state) nil))

;;; ── accessors (all read-only views of state) ────────────────────────────────

(defun isearch-matches (state)
  (isearch-state-matches state))

(defun isearch-current-match (state)
  "Return the current (start . end) cons, or NIL."
  (let ((matches (isearch-state-matches state))
        (idx     (isearch-state-current-index state)))
    (when matches (nth idx matches))))

(defun isearch-current-index (state)
  (isearch-state-current-index state))

(defun isearch-query (state)
  (isearch-state-query state))

(defun isearch-active-p (state)
  (isearch-state-active-p state))

(defun isearch-saved-cursor (state)
  (isearch-state-saved-cursor state))

(defun isearch-forward-p (state)
  (isearch-state-forward-p state))

(defun isearch-buf-id (state)
  (isearch-state-buf-id state))
