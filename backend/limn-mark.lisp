;;;; limn-mark — mark / push-mark / pop-mark / exchange-point-and-mark
;;;; / global-mark-ring (v0.24 §B).
;;;;
;;;; A "mark" is a per-buffer position. Internally, marks are stored as
;;;; limn/marker objects (v0.30 upgrade) so that edits in the buffer
;;;; auto-fixup mark positions — set-mark 5 in a buffer where you
;;;; insert "XY" at pos 0 leaves the mark pointing at the same character
;;;; (now at pos 7).
;;;;
;;;; API compatibility: set-mark accepts an integer, (mark buf-id)
;;;; returns an integer, mark-ring-for returns a list of integers.
;;;; Wrapping/unwrapping happens internally.
;;;;
;;;; Late binding: limn/marker is looked up at call time via
;;;; find-package so this module loads regardless of load order, and
;;;; gracefully degrades to integer storage if limn/marker is absent.
;;;;
;;;; The cursor I/O vtable (*buffer-cursor-fn* / *buffer-set-cursor-fn*)
;;;; lets unit tests swap a mock buffer in without a running bridge.

(defpackage #:limn/mark
  (:use #:cl)
  (:export #:*mark-ring-max*
           #:*global-mark-ring* #:*global-mark-ring-max*
           #:set-mark #:mark
           #:push-mark #:pop-mark
           #:exchange-point-and-mark
           #:pop-global-mark
           #:*buffer-cursor-fn* #:*buffer-set-cursor-fn*
           #:reset-marks #:mark-ring-for
           ;; v0.33 §C — transient-mark-mode + region command classification
           #:*transient-mark-mode*
           #:*mark-active*
           #:mark-active-p
           #:activate-mark
           #:deactivate-mark
           #:use-region-p
           #:*motion-commands*
           #:*edit-commands*
           #:note-command))

(in-package #:limn/mark)

(defvar *mark-ring-max* 16)
(defvar *global-mark-ring* '())
(defvar *global-mark-ring-max* 16)

(defvar *buffer-cursor-fn*     (lambda (bid) (declare (ignore bid)) 0))
(defvar *buffer-set-cursor-fn* (lambda (bid off) (declare (ignore bid off))))

(defstruct bm
  (mark nil)     ; marker (or nil) — the current mark
  (ring '()))    ; list of markers, newest first

(defvar *bufs* (make-hash-table :test 'equal))

(defun %bm (buf-id)
  (or (gethash buf-id *bufs*)
      (setf (gethash buf-id *bufs*) (make-bm))))

;;; ── limn/marker late-binding ─────────────────────────────────────────────
;;;
;;; We don't depend on limn/marker at load time. At call time, if the
;;; package is present we wrap mark values in markers (so edits in the
;;; buffer auto-fixup mark positions). Otherwise we pass integers through.

(defun %marker-pkg () (find-package '#:limn/marker))

(defun %marker-class-p (x)
  (let ((p (%marker-pkg)))
    (and p (typep x (find-symbol "MARKER" p)))))

(defun %marker-position (m)
  (funcall (find-symbol "MARKER-POSITION" (%marker-pkg)) m))

(defun %unwrap (v)
  "If V is a marker, return its position; else return V (int or nil)."
  (cond ((null v) nil)
        ((%marker-class-p v) (%marker-position v))
        (t v)))

(defun %wrap-fresh (pos buf-id)
  "Make a new marker bound to BUF-ID at POS, using the no-clamp
   bind-marker so we don't depend on the consumer wiring text-len-fn."
  (let ((p (%marker-pkg)))
    (if p
        (let ((m (funcall (find-symbol "MAKE-MARKER" p))))
          (funcall (find-symbol "BIND-MARKER" p) m pos buf-id)
          m)
        pos)))

(defun %unlink (v)
  "If V is a marker, unlink it (remove from limn/marker registry)."
  (when (%marker-class-p v)
    (funcall (find-symbol "BIND-MARKER" (%marker-pkg)) v nil nil)))

;;; ── public API ──────────────────────────────────────────────────────────

(defun reset-marks (buf-id)
  "Reset all per-buffer mark state for BUF-ID (test isolation). Also
   unlinks the markers from limn/marker's registry. v0.33: also clears
   the transient-mark active flag."
  (let ((st (gethash buf-id *bufs*)))
    (when st
      (%unlink (bm-mark st))
      (dolist (m (bm-ring st)) (%unlink m))))
  (remhash buf-id *bufs*)
  (when (boundp '*mark-active*)
    (remhash buf-id *mark-active*))
  nil)

(defun mark-ring-for (buf-id)
  "Return the mark ring (list of integer offsets, newest first) for BUF-ID."
  (mapcar #'%unwrap (bm-ring (%bm buf-id))))

(defun set-mark (pos buf-id)
  "Set the mark in BUF-ID to POS (integer), overwriting any previous
   mark. Internally stores a marker so edits fix up the position.
   v0.33: when *transient-mark-mode* is on, also activates the region."
  (let* ((st  (%bm buf-id))
         (old (bm-mark st)))
    (%unlink old)
    (setf (bm-mark st) (%wrap-fresh pos buf-id)))
  ;; v0.33: forward-reference to activate-mark is safe — defined later
  ;; in the same file. *transient-mark-mode* is also defined later but
  ;; the check is at call time, not load time, so this is fine.
  (when (and (boundp '*transient-mark-mode*) *transient-mark-mode*)
    (setf (gethash buf-id *mark-active*) t))
  pos)

(defun mark (buf-id &key error-on-nil)
  "Return the current mark of BUF-ID as an integer, or nil if none.
   With :error-on-nil t, signal an error when no mark is set."
  (let* ((st (%bm buf-id))
         (m  (bm-mark st)))
    (cond ((and (null m) error-on-nil)
           (error "limn/mark: no mark set in ~s" buf-id))
          (t (%unwrap m)))))

(defun %push-global (buf-id marker-or-pos)
  (push (cons buf-id marker-or-pos) *global-mark-ring*)
  (when (and *global-mark-ring-max*
             (> (length *global-mark-ring*) *global-mark-ring-max*))
    (setf *global-mark-ring*
          (subseq *global-mark-ring* 0 *global-mark-ring-max*))))

(defun push-mark (buf-id &key pos)
  "Push a mark to the mark-ring of BUF-ID. With :pos, push that
   position; otherwise push the current cursor. Also pushes a
   (buf-id . marker) entry on *global-mark-ring*."
  (let* ((cur (funcall *buffer-cursor-fn* buf-id))
         (p   (or pos cur))
         (st  (%bm buf-id))
         (old (bm-mark st)))
    (when old
      (push old (bm-ring st))
      (when (and *mark-ring-max* (> (length (bm-ring st)) *mark-ring-max*))
        ;; trim excess; unlink the dropped markers
        (let ((dropped (subseq (bm-ring st) *mark-ring-max*)))
          (dolist (d dropped) (%unlink d)))
        (setf (bm-ring st) (subseq (bm-ring st) 0 *mark-ring-max*))))
    (let ((new-marker (%wrap-fresh p buf-id)))
      (setf (bm-mark st) new-marker))
    ;; *global-mark-ring* keeps the v0.24 (buf-id . integer) shape; it
    ;; is "where I was N navigation jumps ago" and does not auto-track
    ;; edits. v0.30 upgrade is scoped to per-buffer mark / mark-ring.
    (%push-global buf-id p)
    p))

(defun pop-mark (buf-id)
  "Pop the most recent entry off BUF-ID's mark-ring into the current
   mark. The old current mark is dropped (and unlinked). No-op when
   the ring is empty."
  (let ((st (%bm buf-id)))
    (when (bm-ring st)
      (%unlink (bm-mark st))
      (setf (bm-mark st) (pop (bm-ring st)))))
  nil)

(defun exchange-point-and-mark (buf-id)
  "Swap BUF-ID's cursor with its mark. Signals an error when no mark
   has been set."
  (let* ((st (%bm buf-id))
         (m  (bm-mark st)))
    (unless m
      (error "limn/mark: no mark set in ~s" buf-id))
    (let ((cur  (funcall *buffer-cursor-fn* buf-id))
          (mpos (%unwrap m)))
      (funcall *buffer-set-cursor-fn* buf-id mpos)
      (%unlink m)
      (setf (bm-mark st) (%wrap-fresh cur buf-id)))))

(defun pop-global-mark ()
  "Pop the most recent entry off *global-mark-ring* and move that
   buffer's cursor to the saved offset."
  (when *global-mark-ring*
    (let* ((entry (pop *global-mark-ring*))
           (bid   (car entry))
           (off   (%unwrap (cdr entry))))   ; cdr is int in v0.24+, robust to either
      (funcall *buffer-set-cursor-fn* bid off)
      entry)))

;;; ════════════════════════════════════════════════════════════════════════
;;; v0.33 §C — transient-mark-mode + region command classification
;;;
;;; *mark-active* is per-buffer (hash buf-id → t/nil). set-mark with
;;; transient-mark on activates; deactivate-mark clears. After every
;;; command, the dispatch layer calls (note-command CMD-NAME BUF) which:
;;;   - keeps active if CMD-NAME is in *motion-commands*
;;;   - deactivates if CMD-NAME is in *edit-commands*
;;;   - keeps active otherwise (conservative; same as Emacs default).
;;;
;;; The *region-overlay* face highlight rendering lives in limn/region —
;;; this module only owns the data state.
;;; ════════════════════════════════════════════════════════════════════════

(defvar *transient-mark-mode* t
  "When true (Emacs 25+ default), set-mark activates the region and
   subsequent edit commands deactivate it.")

(defvar *mark-active* (make-hash-table :test 'equal)
  "Per-buffer flag: buf-id → t/nil. t = region is currently active and
   should be visually highlighted.")

(defvar *region-deactivate-hook* nil
  "Funcall'd with (buf-id) immediately after a mark is deactivated, so
   the region-overlay layer can clear its overlay. limn/region installs
   itself here at load time.")

(defun mark-active-p (buf-id)
  "Return t when the region in BUF-ID is currently active."
  (gethash buf-id *mark-active*))

(defun activate-mark (buf-id)
  "Mark the region in BUF-ID as active. No-op when transient-mark-mode
   is off."
  (when *transient-mark-mode*
    (setf (gethash buf-id *mark-active*) t)
    t))

(defun deactivate-mark (buf-id)
  "Clear the active flag for BUF-ID's region. Fires
   *region-deactivate-hook* so the overlay layer can drop its display."
  (remhash buf-id *mark-active*)
  (when *region-deactivate-hook*
    (funcall *region-deactivate-hook* buf-id))
  nil)

(defun use-region-p (buf-id)
  "Emacs-style: t when the region in BUF-ID is non-empty and active.
   Many commands (upcase-region, etc.) only operate on the region when
   this returns t."
  (and *transient-mark-mode*
       (mark-active-p buf-id)
       (let ((m (mark buf-id))
             (c (funcall *buffer-cursor-fn* buf-id)))
         (and m (not (eql m c))))))

;;; ── command classification ────────────────────────────────────────────

(defvar *motion-commands*
  '(forward-char backward-char next-line previous-line
    beginning-of-line end-of-line
    forward-word backward-word
    beginning-of-buffer end-of-buffer
    move-beginning-of-line move-end-of-line
    isearch-forward isearch-backward
    isearch-repeat-forward isearch-repeat-backward
    scroll-up scroll-down
    forward-paragraph backward-paragraph
    forward-sexp backward-sexp
    forward-sentence backward-sentence)
  "Commands that should keep the region active when invoked.
   User-land can push more onto this list.")

(defvar *edit-commands*
  '(self-insert-command
    delete-char delete-backward-char backward-delete-char
    kill-region kill-line kill-word backward-kill-word
    yank yank-pop
    newline open-line
    transpose-chars transpose-words
    capitalize-word upcase-word downcase-word
    indent-for-tab-command
    overwrite-mode)
  "Commands that should deactivate the region (after they run).
   User-land can push more onto this list.")

(defun %cmd-sym= (a b)
  "Name-based symbol equality so cmd lookups work across packages
   (Emacs has one obarray; CL has packages — this bridges the gap)."
  (or (eq a b)
      (and (symbolp a) (symbolp b)
           (string= (symbol-name a) (symbol-name b)))))

(defun note-command (cmd-name buf-id)
  "Called by the dispatch layer after every command, with the command's
   symbol name. Classifies cmd against *motion-commands* / *edit-commands*
   and updates region active state. Unknown commands keep active state
   (conservative)."
  (when *transient-mark-mode*
    (cond
      ((find cmd-name *motion-commands* :test #'%cmd-sym=)
       t)
      ((find cmd-name *edit-commands* :test #'%cmd-sym=)
       (deactivate-mark buf-id))
      (t t))))
