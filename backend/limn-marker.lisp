;;;; limn-marker — v0.30 §A markers.
;;;;
;;;; Markers are buffer positions that auto-fixup on edits. Each marker
;;;; holds a position (codepoint offset), a buffer-id, and an
;;;; insertion-type (:before keeps marker put when text is inserted *at*
;;;; the marker; :after pushes it forward). The per-buffer registry is
;;;; updated by process-insert / process-delete, which the
;;;; event/buffer-modified handler calls on every edit.
;;;;
;;;; Cross-buffer correctness: each marker is registered under exactly
;;;; one buffer-id. set-marker M pos new-buf migrates it (un-registers
;;;; from old, registers under new). Edits in the old buffer no longer
;;;; affect it.
;;;;
;;;; Position clamping: set-marker clamps the position to
;;;; [0, *buffer-text-len-fn*(buffer)] to match Emacs semantics — if a
;;;; user pastes-replace-all leaving stored positions stale, we never
;;;; carry out-of-range positions.

(defpackage #:limn/marker
  (:use #:cl)
  (:export #:make-marker
           #:point-marker
           #:point-min-marker
           #:point-max-marker
           #:copy-marker
           #:marker-position
           #:marker-buffer
           #:set-marker
           #:marker-insertion-type
           #:set-marker-insertion-type
           ;; trusted-caller bind (skips clamping — used by limn-mark
           ;; whose positions come from cursor-fn / push-mark and are
           ;; known to be in range; avoids needing every caller of mark
           ;; to wire *buffer-text-len-fn*)
           #:bind-marker
           ;; fixup entry points (called by event handler; direct in tests)
           #:process-insert
           #:process-delete
           ;; event-stream subscription (call once at bootstrap to wire
           ;; fixup to buffer-modified events from both the wire channel
           ;; and the in-process keyword channel)
           #:install-buffer-modified-handler
           ;; test introspection
           #:reset-markers
           #:marker-count-for
           ;; I/O vtable
           #:*current-buffer-id*
           #:*buffer-cursor-fn*
           #:*buffer-text-len-fn*))

(in-package #:limn/marker)

;;; ── I/O vtable ──────────────────────────────────────────────────────────

(defvar *current-buffer-id* nil
  "Current buffer-id. Bound by the buffer-switching layer.")

(defvar *buffer-cursor-fn*
  (lambda (bid) (declare (ignore bid)) 0)
  "(buf-id) → cursor offset (codepoints). Default returns 0.")

(defvar *buffer-text-len-fn*
  (lambda (bid) (declare (ignore bid)) 0)
  "(buf-id) → text length (codepoints). Used to clamp set-marker positions.")

;;; ── marker struct ───────────────────────────────────────────────────────

(defstruct (marker (:constructor %make-marker)
                   (:copier nil)
                   (:predicate markerp))
  (position       nil)
  (buffer         nil)
  (insertion-type :before))

;;; ── per-buffer registry ─────────────────────────────────────────────────
;;;
;;; Hash: buf-id (string) → list of markers. We use eq-membership when
;;; adding/removing so duplicate registration is impossible.

(defvar *markers-by-buffer* (make-hash-table :test 'equal))

(defun %register (m buf-id)
  (when buf-id
    (let ((cur (gethash buf-id *markers-by-buffer* '())))
      (unless (member m cur :test #'eq)
        (setf (gethash buf-id *markers-by-buffer*) (cons m cur))))))

(defun %unregister (m buf-id)
  (when buf-id
    (let ((cur (gethash buf-id *markers-by-buffer* '())))
      (setf (gethash buf-id *markers-by-buffer*)
            (remove m cur :test #'eq)))))

(defun reset-markers (buf-id)
  "Remove all markers tracked for BUF-ID. For test isolation and for
   buffer-close cleanup."
  (remhash buf-id *markers-by-buffer*)
  nil)

(defun marker-count-for (buf-id)
  "Number of markers currently registered for BUF-ID."
  (length (gethash buf-id *markers-by-buffer* '())))

;;; ── creation ───────────────────────────────────────────────────────────

(defun make-marker ()
  "Return a fresh unlinked marker (no buffer, no position)."
  (%make-marker))

(defun %require-current-buffer (who)
  (or *current-buffer-id*
      (error "~a: no current buffer (*current-buffer-id* is nil)" who)))

(defun point-marker ()
  "Marker at current buffer's cursor."
  (let* ((bid (%require-current-buffer 'point-marker))
         (pos (funcall *buffer-cursor-fn* bid))
         (m   (%make-marker :position pos :buffer bid)))
    (%register m bid)
    m))

(defun point-min-marker ()
  "Marker at position 0 of the current buffer."
  (let* ((bid (%require-current-buffer 'point-min-marker))
         (m   (%make-marker :position 0 :buffer bid)))
    (%register m bid)
    m))

(defun point-max-marker ()
  "Marker at the current buffer's text length."
  (let* ((bid (%require-current-buffer 'point-max-marker))
         (len (funcall *buffer-text-len-fn* bid))
         (m   (%make-marker :position len :buffer bid)))
    (%register m bid)
    m))

(defun copy-marker (src &optional (insertion-type nil it-supplied-p)
                                  (buffer-arg nil ba-supplied-p))
  "Two shapes:
     (copy-marker MARKER)              — inherits position/buffer/insertion-type
     (copy-marker INTEGER &optional INSERT-TYPE BUF) — pure integer upgrade"
  (cond
    ((markerp src)
     (let ((m (%make-marker
               :position       (marker-position src)
               :buffer         (marker-buffer src)
               :insertion-type (marker-insertion-type src))))
       (when (marker-buffer m) (%register m (marker-buffer m)))
       m))
    ((integerp src)
     (let* ((it  (if it-supplied-p insertion-type :before))
            (buf (if ba-supplied-p buffer-arg *current-buffer-id*))
            (pos (%clamp src buf))
            (m   (%make-marker :position pos :buffer buf :insertion-type it)))
       (when buf (%register m buf))
       m))
    (t (error "copy-marker: expected marker or integer, got ~s" src))))

;;; ── clamping ───────────────────────────────────────────────────────────

(defun %clamp (position buf)
  "Clamp POSITION to [0, text-len(BUF)] if BUF is non-nil; else identity."
  (if buf
      (let ((maxp (funcall *buffer-text-len-fn* buf)))
        (max 0 (min position maxp)))
      position))

;;; ── set-marker ─────────────────────────────────────────────────────────

(defun set-marker (m position &optional (buffer nil buffer-supplied-p))
  "Move M to POSITION, optionally migrating to BUFFER.

   Semantics:
     position = nil                → unlink (clear buffer too)
     buffer supplied and is nil    → unlink
     buffer supplied (non-nil)     → migrate to that buffer
     buffer omitted                → keep marker-buffer

   Position is clamped to the destination buffer's text length."
  (let ((old-buf (marker-buffer m)))
    (cond
      ;; explicit unlink: nil position, or nil buffer arg.
      ((or (null position)
           (and buffer-supplied-p (null buffer)))
       (when old-buf (%unregister m old-buf))
       (setf (marker-position m) nil
             (marker-buffer   m) nil))
      (t
       (let* ((new-buf (if buffer-supplied-p buffer old-buf))
              (clamped (%clamp position new-buf)))
         (when (and old-buf (not (equal old-buf new-buf)))
           (%unregister m old-buf))
         (setf (marker-position m) clamped
               (marker-buffer   m) new-buf)
         (when new-buf (%register m new-buf))))))
  m)

(defun bind-marker (m position buf-id &key (insertion-type :before))
  "Like set-marker but skips position clamping. For trusted callers
   (e.g. limn-mark, where positions come from cursor-fn). Migrates M to
   BUF-ID. POSITION must be nil or a non-negative integer."
  (let ((old-buf (marker-buffer m)))
    (cond
      ((null position)
       (when old-buf (%unregister m old-buf))
       (setf (marker-position m) nil
             (marker-buffer m)   nil))
      (t
       (when (and old-buf (not (equal old-buf buf-id)))
         (%unregister m old-buf))
       (setf (marker-position m)       position
             (marker-buffer m)         buf-id
             (marker-insertion-type m) insertion-type)
       (when buf-id (%register m buf-id)))))
  m)

;;; ── insertion-type ─────────────────────────────────────────────────────

(defun set-marker-insertion-type (m type)
  "TYPE must be :before or :after."
  (unless (member type '(:before :after))
    (error "set-marker-insertion-type: TYPE must be :before or :after, got ~s"
           type))
  (setf (marker-insertion-type m) type)
  type)

;;; ── fixup engines ──────────────────────────────────────────────────────
;;;
;;; Called by the event/buffer-modified handler. Unknown buf-id is a
;;; silent no-op (gethash default '() → empty list → dolist no-op).

(defun process-insert (buf-id pos len)
  "Apply insert-at-POS, length-LEN fixup to all markers in BUF-ID."
  (when (and len (plusp len))
    (dolist (m (gethash buf-id *markers-by-buffer* '()))
      (let ((mp (marker-position m)))
        (when mp
          (cond
            ((< mp pos))                       ; before insert: unchanged
            ((= mp pos)
             (when (eq (marker-insertion-type m) :after)
               (setf (marker-position m) (+ mp len))))
            (t                                  ; mp > pos
             (setf (marker-position m) (+ mp len)))))))))

(defun process-delete (buf-id from to)
  "Apply delete-[FROM,TO) fixup to all markers in BUF-ID."
  (when (and from to (> to from))
    (let ((len (- to from)))
      (dolist (m (gethash buf-id *markers-by-buffer* '()))
        (let ((mp (marker-position m)))
          (when mp
            (cond
              ((<= mp from))                    ; before delete: unchanged
              ((< mp to)                        ; inside [FROM,TO): clamp
               (setf (marker-position m) from))
              (t                                ; at or after TO: shift left
               (setf (marker-position m) (- mp len))))))))))

;;; ── event-stream subscription ──────────────────────────────────────────
;;;
;;; Bridge the buffer-modified event stream to process-insert / process-delete.
;;; Two channels:
;;;   - wire dispatch: string-keyed "event/buffer-modified" (fired by
;;;     limn-dispatch when C++ pushes the event)
;;;   - in-process keyword: :event/buffer-modified (fired by mock-buffer
;;;     in tests and by Lisp code that mutates via the gap buffer)
;;;
;;; Wire payload shape (from limn-buffer-undo's normalization reference):
;;;   :|buffer-id| / :buf-id   string
;;;   :|op| / :op              "insert" | "delete" | :insert | :delete
;;;   :|pos| / :pos            integer
;;;   :|len| / :len            integer (length affected: inserted text /
;;;                            (to - from) for delete)
;;;
;;; Insert event → process-insert buf-id pos len
;;; Delete event → process-delete buf-id pos (pos + len)

(defvar *handler-installed* nil)

(defun %ev-getf (ev key1 key2)
  (or (getf ev key1) (getf ev key2)))

(defun %dispatch-event (ev)
  (let* ((buf-id (or (%ev-getf ev :|buffer-id| :buf-id)
                     (%ev-getf ev :|buf-id|    :buffer-id)))
         (op-raw (%ev-getf ev :|op| :op))
         (op     (cond ((null op-raw) nil)
                       ((symbolp op-raw)
                        (intern (string-upcase (symbol-name op-raw))
                                :keyword))
                       ((stringp op-raw)
                        (intern (string-upcase op-raw) :keyword))
                       (t nil)))
         (pos    (%ev-getf ev :|pos| :pos))
         (len    (%ev-getf ev :|len| :len)))
    (when (and buf-id op pos len)
      (case op
        (:insert (process-insert buf-id pos len))
        (:delete (process-delete buf-id pos (+ pos len)))))))

(defun install-buffer-modified-handler ()
  "Subscribe to buffer-modified events on both channels. Idempotent —
   later calls are no-ops. Returns t."
  (unless *handler-installed*
    (let ((hooks (find-package '#:limn/hooks)))
      (when hooks
        (let ((add (find-symbol "ADD-HOOK" hooks)))
          (when add
            (funcall add "event/buffer-modified"  #'%dispatch-event)
            (funcall add :event/buffer-modified   #'%dispatch-event)
            (setf *handler-installed* t))))))
  t)
