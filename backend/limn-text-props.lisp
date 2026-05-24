;;;; limn-text-props — text-properties with interval tree.
;;;;
;;;; Pure Lisp. v0.25 §B.
;;;;
;;;; Architecture: a prop-buffer wraps a string and an interval list.
;;;; Intervals are sorted by start position and never overlap (put-text-property
;;;; splits/merges as needed). Adjacent intervals with identical plists are merged.
;;;;
;;;; Invariant: ALL text mutations go through insert / delete-region here,
;;;; not directly to the bridge. This keeps the interval tree consistent.
;;;;
;;;; Stickiness (Emacs default):
;;;;   - front-nonsticky: insert at left boundary does NOT inherit
;;;;   - rear-sticky:     insert at right boundary DOES inherit
;;;; Override via :front-sticky / :rear-nonsticky properties on an interval.

(defpackage #:limn/text-props
  (:use #:cl)
  (:export #:make-prop-buffer
           #:insert #:delete-region
           #:put-text-property
           #:get-text-property
           #:add-text-properties
           #:remove-text-properties
           #:next-property-change
           #:previous-property-change
           #:text-property-any
           #:propertize
           #:buffer-text #:buffer-length))

(in-package #:limn/text-props)

;;; ─── data structures ──────────────────────────────────────────────

(defstruct (prop-buffer (:constructor %make-prop-buffer))
  (text "" :type string)
  ;; Sorted list of (start end . plist) — non-overlapping, sorted by start.
  (intervals '()))

(defun make-prop-buffer (initial-text)
  "Create a fresh prop-buffer pre-loaded with INITIAL-TEXT."
  (%make-prop-buffer :text initial-text :intervals '()))

;;; Alias: a prop-buffer can also be a string (for propertize).
;;; We attach a property list to strings via a parallel hash table.
(defvar *string-props* (make-hash-table :test 'eq))

(defun buffer-text (buf)
  (etypecase buf
    (prop-buffer (prop-buffer-text buf))
    (string buf)))

(defun buffer-length (buf)
  (length (buffer-text buf)))

;;; ─── interval helpers ─────────────────────────────────────────────

(defun %istart (iv) (first iv))
(defun %iend   (iv) (second iv))
(defun %iplist (iv) (cddr iv))
(defun %make-iv (s e plist) (list* s e plist))

(defun %plist-get (plist key)
  (getf plist key))

(defun %plist-put (plist key value)
  (let ((copy (copy-list plist)))
    (setf (getf copy key) value)
    copy))

(defun %plist-remove (plist key)
  (loop for (k v) on plist by #'cddr
        unless (eq k key)
        nconc (list k v)))

(defun %plist-equal (a b)
  ;; Both must have the same keys with equal values
  (and (= (length a) (length b))
       (loop for (k v) on a by #'cddr
             always (equal v (%plist-get b k)))))

(defun %merge-plists (base override)
  "Return BASE with OVERRIDE keys applied (OVERRIDE wins)."
  (let ((result (copy-list base)))
    (loop for (k v) on override by #'cddr
          do (setf (getf result k) v))
    result))

;;; ─── interval list operations ─────────────────────────────────────

(defun %put-prop-on-intervals (intervals start end prop value)
  "Set PROP=VALUE on [START,END), merging with existing interval plists.
   Emacs semantics: put-text-property updates ONE prop, preserving others."
  (let ((result '())
        (new-plist (list prop value))
        ;; Track which sub-ranges of [start,end) already had an interval
        (covered-start nil) (covered-end nil))
    (dolist (iv intervals)
      (let ((s (%istart iv)) (e (%iend iv)) (p (%iplist iv)))
        (cond
          ;; No overlap: keep as-is
          ((or (<= e start) (>= s end))
           (push iv result))
          ;; Overlap: split into at most 3 sub-intervals
          (t
           (let ((ov-s (max s start)) (ov-e (min e end)))
             ;; Track covered range (union, simplified — monotone scan)
             (setf covered-start (if covered-start (min covered-start ov-s) ov-s)
                   covered-end   (if covered-end   (max covered-end   ov-e) ov-e))
             ;; Left tail
             (when (< s start)
               (push (%make-iv s start p) result))
             ;; Overlapping part: merge new prop into existing plist
             (push (%make-iv ov-s ov-e (%plist-put p prop value)) result)
             ;; Right tail
             (when (> e end)
               (push (%make-iv end e p) result)))))))
    ;; Add bare interval for any uncovered portion of [start, end)
    ;; (simplified: only handles the case where NO existing interval touched [start,end))
    (unless covered-start
      (push (%make-iv start end new-plist) result))
    ;; Partial coverage: add gap intervals
    (when covered-start
      (when (< start covered-start)
        (push (%make-iv start covered-start new-plist) result))
      (when (> end covered-end)
        (push (%make-iv covered-end end new-plist) result)))
    (%normalise (sort result #'< :key #'%istart))))

(defun %normalise (sorted)
  "Merge adjacent intervals with identical plists."
  (when (null sorted) (return-from %normalise nil))
  (let ((result (list (first sorted))))
    (dolist (iv (rest sorted))
      (let ((prev (first result)))
        (if (and (= (%iend prev) (%istart iv))
                 (%plist-equal (%iplist prev) (%iplist iv)))
            ;; Merge: extend prev
            (setf (second (first result)) (%iend iv))
            (push iv result))))
    (nreverse result)))

(defun %shift-intervals (intervals pos delta)
  "Shift all interval boundaries >= POS by DELTA (positive = insert, negative = delete)."
  (mapcar (lambda (iv)
            (let ((s (%istart iv)) (e (%iend iv)) (p (%iplist iv)))
              (%make-iv (if (>= s pos) (max pos (+ s delta)) s)
                        (if (>= e pos) (max pos (+ e delta)) e)
                        p)))
          intervals))

(defun %clip-intervals (intervals del-start del-end)
  "Remove or trim intervals overlapping [del-start, del-end)."
  (let ((result '()))
    (dolist (iv intervals)
      (let ((s (%istart iv)) (e (%iend iv)) (p (%iplist iv)))
        (cond
          ((<= e del-start) (push iv result))   ; entirely before
          ((>= s del-end)   (push iv result))   ; entirely after
          ;; Left tail
          ((< s del-start)
           (push (%make-iv s del-start p) result)
           (when (> e del-end)
             (push (%make-iv del-start (- e (- del-end del-start)) p) result)))
          ;; Right tail only
          ((> e del-end)
           (push (%make-iv del-start (- e (- del-end del-start)) p) result))
          ;; Fully contained: drop
          (t nil))))
    (sort result #'< :key #'%istart)))

;;; ─── string-as-buffer helpers ─────────────────────────────────────

(defun %string-intervals (s)
  (gethash s *string-props* '()))

(defun (setf %string-intervals) (ivs s)
  (setf (gethash s *string-props*) ivs))

(defun %buf-intervals (buf)
  (etypecase buf
    (prop-buffer (prop-buffer-intervals buf))
    (string      (%string-intervals buf))
    (null        '())))

(defun %set-buf-intervals (buf ivs)
  (etypecase buf
    (prop-buffer (setf (prop-buffer-intervals buf) ivs))
    (string      (setf (%string-intervals buf) ivs))))

;;; ─── insert / delete (the wrappers that update intervals) ─────────

(defun insert (buf pos str)
  "Insert STR at POS in BUF, adjusting all text-property intervals."
  (let* ((len (length str))
         (text (buffer-text buf))
         (old-intervals (%buf-intervals buf))
         ;; Determine stickiness at pos
         ;; rear-sticky (default): interval ending AT pos extends → shift >=pos
         ;; front-nonsticky (default): interval starting AT pos does not extend
         ;; We shift end >= pos but start > pos (not >=)
         (new-intervals
           (mapcar (lambda (iv)
                     (let ((s (%istart iv)) (e (%iend iv)) (p (%iplist iv)))
                       (let* (;; front-sticky: the :front-sticky property lists which
                              ;; props are sticky at the left boundary. Default: none.
                              (front-sticky-props (%plist-get p :front-sticky))
                              ;; rear-nonsticky: props that do NOT extend at right.
                              (rear-nonsticky-props (%plist-get p :rear-nonsticky))
                              ;; Emacs default: front-nonsticky (insert at S does NOT extend)
                              ;; → new-s shifts right when s = pos, unless front-sticky.
                              (new-s (cond ((< s pos) s)
                                           ((= s pos)
                                            ;; front-sticky for :face? keep s; else shift
                                            (if (and front-sticky-props
                                                     (member :face front-sticky-props))
                                                s
                                                (+ s len)))
                                           (t (+ s len))))
                              ;; Emacs default: rear-sticky (insert at E extends)
                              ;; → new-e extends when e = pos, unless rear-nonsticky.
                              (new-e (cond ((< e pos) e)
                                           ((= e pos)
                                            (if (and rear-nonsticky-props
                                                     (member :face rear-nonsticky-props))
                                                e
                                                (+ e len)))
                                           (t (+ e len)))))
                         (%make-iv new-s new-e p))))
                   old-intervals)))
    ;; Mutate text
    (etypecase buf
      (prop-buffer
       (setf (prop-buffer-text buf)
             (concatenate 'string (subseq text 0 pos) str (subseq text pos))))
      (string nil))                     ; strings are immutable at this tier
    (%set-buf-intervals buf (%normalise new-intervals)))
  buf)

(defun delete-region (buf pos len)
  "Delete LEN chars at POS in BUF, adjusting intervals."
  (let* ((text (buffer-text buf))
         (del-end (+ pos len))
         (clipped (%clip-intervals (%buf-intervals buf) pos del-end))
         (shifted (%shift-intervals clipped del-end (- len))))
    (etypecase buf
      (prop-buffer
       (setf (prop-buffer-text buf)
             (concatenate 'string (subseq text 0 pos) (subseq text del-end))))
      (string nil))
    (%set-buf-intervals buf (%normalise shifted)))
  buf)

;;; ─── put-text-property / get-text-property ────────────────────────

(defun put-text-property (start end prop value &optional buf)
  (%set-buf-intervals
   buf
   (%put-prop-on-intervals (%buf-intervals buf) start end prop value))
  value)

(defun get-text-property (pos prop &optional buf)
  (let ((ivs (%buf-intervals buf)))
    (dolist (iv ivs)
      (when (and (>= pos (%istart iv)) (< pos (%iend iv)))
        (let ((v (%plist-get (%iplist iv) prop)))
          (when v (return-from get-text-property v)))))
    nil))

;;; ─── add / remove ─────────────────────────────────────────────────

(defun add-text-properties (start end plist &optional buf)
  (loop for (k v) on plist by #'cddr
        do (put-text-property start end k v buf))
  t)

(defun remove-text-properties (start end plist &optional buf)
  ;; plist is like (:face nil :weight nil) — keys to remove
  (let* ((keys-to-remove (loop for (k _v) on plist by #'cddr collect k))
         (ivs (%buf-intervals buf))
         (new-ivs '()))
    (dolist (iv ivs)
      (let ((s (%istart iv)) (e (%iend iv)) (p (%iplist iv)))
        (cond
          ;; No overlap with [start, end)
          ((or (<= e start) (>= s end))
           (push iv new-ivs))
          ;; Overlap: rebuild plist minus removed keys
          (t
           (let ((new-p (loop for (k v) on p by #'cddr
                              unless (member k keys-to-remove)
                              nconc (list k v))))
             ;; Left tail (before start)
             (when (< s start)
               (push (%make-iv s start p) new-ivs))
             ;; Overlapping part with keys removed
             (when new-p
               (push (%make-iv (max s start) (min e end) new-p) new-ivs))
             ;; Right tail (after end)
             (when (> e end)
               (push (%make-iv end e p) new-ivs)))))))
    (%set-buf-intervals buf (%normalise (sort new-ivs #'< :key #'%istart))))
  t)

;;; ─── boundary traversal ───────────────────────────────────────────

(defun next-property-change (pos &optional buf limit)
  (let ((ivs (%buf-intervals buf)))
    (let ((candidates '()))
      (dolist (iv ivs)
        (when (> (%istart iv) pos)
          (push (%istart iv) candidates))
        (when (> (%iend iv) pos)
          (push (%iend iv) candidates)))
      (let ((next (when candidates (reduce #'min candidates))))
        (when (and next (or (null limit) (< next limit)))
          next)))))

(defun previous-property-change (pos &optional buf limit)
  (let ((ivs (%buf-intervals buf)))
    (let ((candidates '()))
      (dolist (iv ivs)
        (when (< (%istart iv) pos)
          (push (%istart iv) candidates))
        (when (< (%iend iv) pos)
          (push (%iend iv) candidates)))
      (let ((prev (when candidates (reduce #'max candidates))))
        (when (and prev (or (null limit) (> prev limit)))
          prev)))))

(defun text-property-any (start end prop value &optional buf)
  (let ((ivs (%buf-intervals buf)))
    (dolist (iv ivs)
      (let ((s (max (%istart iv) start))
            (e (min (%iend iv) end)))
        (when (and (< s e)
                   (equal (%plist-get (%iplist iv) prop) value))
          (return-from text-property-any s))))
    nil))

;;; ─── propertize ───────────────────────────────────────────────────

(defun propertize (str &rest props)
  "Return a copy of STR with PROPS applied as text properties."
  (let ((copy (copy-seq str)))
    (loop for (k v) on props by #'cddr
          do (put-text-property 0 (length copy) k v copy))
    copy))
