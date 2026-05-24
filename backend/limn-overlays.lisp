;;;; limn-overlays — v0.33 §B overlay data layer + §A wire payload helpers.
;;;;
;;;; Overlays are independent range objects with a property plist. Unlike
;;;; text-properties (v0.25, sticky to text), overlays:
;;;;
;;;;   - don't get carried by copy/paste (they're not part of buffer text)
;;;;   - can be moved or deleted independently
;;;;   - auto-fix-up their start/end via v0.30 markers when text mutates
;;;;
;;;; Property semantics follow Emacs: `face`, `before-string`,
;;;; `after-string`, `display`, `keymap`, `mouse-face`, `priority`, `window`.
;;;; The render layer reads these when building wire payloads.
;;;;
;;;; Late binding to limn/marker: like limn-mark, we look up marker fns at
;;;; call time so this module can load before/after limn-marker without
;;;; ordering pain. When limn/marker is missing, overlays fall back to
;;;; integer start/end with no fixup.

(defpackage #:limn/overlays
  (:use #:cl)
  (:export
   ;; constructors / mutators
   #:make-overlay
   #:delete-overlay
   #:move-overlay
   ;; properties
   #:overlay-put
   #:overlay-get
   #:overlay-properties
   ;; accessors
   #:overlay-start
   #:overlay-end
   #:overlay-buffer
   ;; queries
   #:overlays-in
   #:overlays-at
   ;; predicate / test introspection
   #:overlay-p
   #:reset-overlays
   #:overlay-count-for
   ;; wire-payload helpers (§A)
   #:overlay-as-wire-layer
   #:overlays-to-wire-layers
   #:layer-with-face
   ;; vtable
   #:*current-buffer-id*
   #:*buffer-text-len-fn*))

(in-package #:limn/overlays)

;;; ── vtable ─────────────────────────────────────────────────────────────

(defvar *current-buffer-id* nil
  "Default buf-id used by make-overlay when caller omits it.")

(defvar *buffer-text-len-fn*
  (lambda (bid) (declare (ignore bid)) 0)
  "(buf-id) → text length. Forwarded to limn/marker via late binding.")

;;; ── late binding to limn/marker ────────────────────────────────────────

(defun %marker-pkg () (find-package '#:limn/marker))

(defun %make-marker (pos buf-id insertion-type)
  "Build a marker bound to BUF-ID at POS with the given INSERTION-TYPE.
   Returns the marker (or the raw integer POS if limn/marker is absent).
   Mirrors limn-mark's %wrap-fresh: uses BIND-MARKER (no clamp) so we
   don't depend on the caller wiring *buffer-text-len-fn*."
  (let ((p (%marker-pkg)))
    (if p
        (let* ((mk-make    (find-symbol "MAKE-MARKER" p))
               (mk-bind    (find-symbol "BIND-MARKER" p))
               (m          (funcall mk-make)))
          (funcall mk-bind m pos buf-id :insertion-type insertion-type)
          m)
        pos)))

(defun %marker-position (m)
  "Resolve a marker (or integer) to its current position."
  (cond ((null m) nil)
        ((integerp m) m)
        (t (let ((p (%marker-pkg)))
             (when p
               (funcall (find-symbol "MARKER-POSITION" p) m))))))

(defun %marker-unlink (m)
  "Remove M from the limn/marker registry (no-op for raw integers)."
  (let ((p (%marker-pkg)))
    (when (and p (not (integerp m)))
      (let ((markerp (find-symbol "MARKERP" p))
            (bind    (find-symbol "BIND-MARKER" p)))
        (when (and markerp bind (funcall markerp m))
          (funcall bind m nil nil))))))

(defun %marker-rebind (m pos buf-id insertion-type)
  "Move marker M to (POS, BUF-ID). For integers (no marker pkg) caller
   must rebuild the marker since integers are immutable. Returns the
   (possibly new) marker."
  (let ((p (%marker-pkg)))
    (cond
      ((and p (not (integerp m)))
       (let ((bind (find-symbol "BIND-MARKER" p)))
         (funcall bind m pos buf-id :insertion-type insertion-type)
         m))
      (t (%make-marker pos buf-id insertion-type)))))

;;; ── overlay struct ─────────────────────────────────────────────────────
;;;
;;; We name the buffer slot %BUF so defstruct's auto-generated accessor
;;; OVERLAY-%BUF doesn't collide with our public API OVERLAY-BUFFER.

(defstruct (overlay (:constructor %make-ov)
                    (:copier nil)
                    (:predicate overlay-p)
                    (:conc-name %ov-))
  start-marker
  end-marker
  (buf   nil)
  (plist '()))

(defun overlay-start (ov)
  (%marker-position (%ov-start-marker ov)))

(defun overlay-end (ov)
  (%marker-position (%ov-end-marker ov)))

(defun overlay-buffer (ov)
  (%ov-buf ov))

;;; ── per-buffer registry ────────────────────────────────────────────────
;;;
;;; buf-id → list of overlays. Linear scan for overlays-in / overlays-at;
;;; sufficient at v0.33's expected overlay counts (~hundreds). If profiling
;;; shows hot-spot we can add an interval tree later. Order in the list is
;;; insertion order — overlays-* functions re-sort on output.

(defvar *overlays-by-buffer* (make-hash-table :test 'equal))

(defun reset-overlays (buf-id)
  "Drop all overlays tracked for BUF-ID, unlinking their markers."
  (dolist (ov (gethash buf-id *overlays-by-buffer* '()))
    (%marker-unlink (%ov-start-marker ov))
    (%marker-unlink (%ov-end-marker   ov)))
  (remhash buf-id *overlays-by-buffer*)
  nil)

(defun overlay-count-for (buf-id)
  (length (gethash buf-id *overlays-by-buffer* '())))

(defun %register (ov buf-id)
  (when buf-id
    (let ((cur (gethash buf-id *overlays-by-buffer* '())))
      (unless (member ov cur :test #'eq)
        (setf (gethash buf-id *overlays-by-buffer*) (cons ov cur))))))

(defun %unregister (ov buf-id)
  (when buf-id
    (let ((cur (gethash buf-id *overlays-by-buffer* '())))
      (setf (gethash buf-id *overlays-by-buffer*)
            (remove ov cur :test #'eq)))))

;;; ── make-overlay ───────────────────────────────────────────────────────

(defun make-overlay (start end &optional buf front-advance rear-advance)
  "Create an overlay covering [START, END) in BUF (default *current-buffer-id*).
   FRONT-ADVANCE / REAR-ADVANCE map to marker insertion-types:
     front-advance nil → start sticky right (:before)  ← default
     front-advance t   → start sticky left  (:after)
     rear-advance nil  → end   sticky left  (:before)  ← default
     rear-advance t    → end   sticky right (:after)"
  (when (and (integerp start) (minusp start))
    (error "make-overlay: start must be non-negative, got ~s" start))
  (when (and (integerp start) (integerp end) (> start end))
    (error "make-overlay: start (~s) must be <= end (~s)" start end))
  (let* ((bid    (or buf *current-buffer-id*))
         (sm     (%make-marker start bid (if front-advance :after :before)))
         (em     (%make-marker end   bid (if rear-advance  :after :before)))
         (ov     (%make-ov :start-marker sm
                           :end-marker   em
                           :buf          bid
                           :plist        '())))
    (%register ov bid)
    ov))

(defun delete-overlay (ov)
  "Remove OV from its buffer's registry and unlink its markers.
   Idempotent — repeated calls are no-ops."
  (when (overlay-p ov)
    (let ((bid (%ov-buf ov)))
      (when bid
        (%unregister ov bid)
        (setf (%ov-buf ov) nil))
      (%marker-unlink (%ov-start-marker ov))
      (%marker-unlink (%ov-end-marker   ov))
      (setf (%ov-start-marker ov) nil
            (%ov-end-marker   ov) nil)))
  nil)

(defun move-overlay (ov new-start new-end &optional new-buf)
  "Move OV to [NEW-START, NEW-END), optionally migrating to NEW-BUF."
  (let* ((old-buf (%ov-buf ov))
         (dest    (or new-buf old-buf)))
    (when (and old-buf (not (equal old-buf dest)))
      (%unregister ov old-buf)
      (%register ov dest)
      (setf (%ov-buf ov) dest))
    (setf (%ov-start-marker ov)
          (%marker-rebind (%ov-start-marker ov) new-start dest :before))
    (setf (%ov-end-marker ov)
          (%marker-rebind (%ov-end-marker   ov) new-end   dest :before))
    ov))

;;; ── properties ────────────────────────────────────────────────────────

;;; Property keys are compared by symbol-name (not eq), so callers in
;;; different packages can put and get the same logical property
;;; without having to share a common interned symbol. Mirrors Emacs's
;;; single-namespace semantics.

(defun %prop-key= (a b)
  (or (eq a b)
      (and (symbolp a) (symbolp b)
           (string= (symbol-name a) (symbol-name b)))))

(defun %plist-find-cell (plist key)
  "Walk PLIST in (k v k v ...) form; return the cons whose CAR is the
   key's value cell (i.e. the cdr of the key cell). Result: the cdr is
   the value, (setf (car ...) ...) updates it. NIL if not found."
  (loop for (k . rest) on plist by #'cddr
        when (%prop-key= k key) return rest))

(defun %plist-get-by-name (plist key)
  (let ((cell (%plist-find-cell plist key)))
    (when cell (car cell))))

(defun overlay-put (ov key value)
  "Set OV's property KEY to VALUE. Returns VALUE. Keys are compared by
   symbol-name so cross-package callers see the same logical property."
  (let* ((plist (%ov-plist ov))
         (cell  (%plist-find-cell plist key)))
    (cond
      (cell (setf (car cell) value))
      (t (setf (%ov-plist ov) (list* key value plist)))))
  value)

(defun overlay-get (ov key)
  "Return OV's value for KEY, or nil if unset. Name-based comparison."
  (%plist-get-by-name (%ov-plist ov) key))

(defun overlay-properties (ov)
  "Return a copy of OV's full property plist."
  (copy-list (%ov-plist ov)))

;;; ── overlays-in / overlays-at ─────────────────────────────────────────
;;;
;;; Semantics:
;;;   overlays-in (a, b)  — any overlay that overlaps [a, b)
;;;     overlap = (ov-start < b) AND (ov-end > a)
;;;     EXCEPTION: when a == b (empty range), return empty list
;;;   overlays-at (pos)   — overlays whose [ov-start, ov-end) contains pos
;;;     i.e. ov-start <= pos < ov-end
;;;   Both sort high-priority first; priority defaults to 0.

(defun %priority (ov)
  (or (overlay-get ov 'priority) 0))

(defun %sort-by-priority-desc (overlays)
  (stable-sort (copy-list overlays) #'>
               :key #'%priority))

(defun overlays-in (start end &optional buf)
  "Return overlays in BUF (default *current-buffer-id*) that overlap
   [START, END). Sorted high-priority first."
  (cond
    ((eql start end) '())
    (t
     (let* ((bid     (or buf *current-buffer-id*))
            (all     (gethash bid *overlays-by-buffer* '()))
            (matches (remove-if-not
                      (lambda (ov)
                        (let ((s (overlay-start ov))
                              (e (overlay-end   ov)))
                          (and s e (< s end) (> e start))))
                      all)))
       (%sort-by-priority-desc matches)))))

(defun overlays-at (pos &optional buf)
  "Return overlays in BUF (default *current-buffer-id*) covering POS.
   High-priority first."
  (let* ((bid     (or buf *current-buffer-id*))
         (all     (gethash bid *overlays-by-buffer* '()))
         (matches (remove-if-not
                   (lambda (ov)
                     (let ((s (overlay-start ov))
                           (e (overlay-end   ov)))
                       (and s e (<= s pos) (< pos e))))
                   all)))
    (%sort-by-priority-desc matches)))

;;; ════════════════════════════════════════════════════════════════════════
;;; §A. wire payload helpers
;;;
;;; The C++ cmd_view_overlays accepts these fields on each layer:
;;;   :type :page :rect :color :opacity ...  (existing)
;;;   :face FACE-NAME                        (new in v0.33)
;;;   :win-id                                (per-layer window targeting)
;;;   :priority                              (draw order tie-break)
;;; ════════════════════════════════════════════════════════════════════════

(defun %face-name-string (face)
  "Coerce a face name (symbol or string) to the lowercase string form
   used in wire payloads."
  (cond
    ((null face)    nil)
    ((stringp face) face)
    ((symbolp face) (string-downcase (symbol-name face)))
    (t (princ-to-string face))))

(defun layer-with-face (layer-plist face-name)
  "Return a new layer plist that copies LAYER-PLIST and adds :face.
   :color (if present) is preserved as fallback."
  (let* ((face-str (%face-name-string face-name))
         (copy     (copy-list layer-plist)))
    (setf (getf copy :|face|) face-str)
    copy))

(defun overlay-as-wire-layer (ov)
  "Convert overlay OV into a wire layer plist.

   Properties consulted:
     face           → :face FACE-NAME
     window         → :win-id WIN-ID
     priority       → :priority N
     before-string  → :before-string TEXT
     after-string   → :after-string TEXT

   The geometry (:type :page :rect/:pos) is intentionally left to the
   render-layer dispatcher — overlays without a 'type' property default
   to a generic 'overlay' record carrying :start :end so the C++ side
   can render them as a text-range highlight."
  (let* ((start (overlay-start ov))
         (end   (overlay-end   ov))
         (face  (overlay-get ov 'face))
         (win   (overlay-get ov 'window))
         (prio  (overlay-get ov 'priority))
         (bef   (overlay-get ov 'before-string))
         (aft   (overlay-get ov 'after-string))
         (type  (overlay-get ov 'type))
         (page  (overlay-get ov 'page))
         (rect  (overlay-get ov 'rect))
         (color (overlay-get ov 'color))
         (op    (overlay-get ov 'opacity))
         (layer (list :|type| (or type "overlay")
                      :|start| start
                      :|end|   end)))
    (when page  (setf (getf layer :|page|)    page))
    (when rect  (setf (getf layer :|rect|)    rect))
    (when color (setf (getf layer :|color|)   color))
    (when op    (setf (getf layer :|opacity|) op))
    (let ((face-str (%face-name-string face)))
      (when face-str (setf (getf layer :|face|) face-str)))
    (when win  (setf (getf layer :|win-id|)   win))
    (when prio (setf (getf layer :|priority|) prio))
    (when bef  (setf (getf layer :|before-string|) bef))
    (when aft  (setf (getf layer :|after-string|)  aft))
    layer))

(defun overlays-to-wire-layers (start end buf &key window)
  "Build a list of wire layer plists for all overlays in BUF that
   overlap [START, END).

   Window filtering:
     - Overlay without 'window' property = global, included in every query
     - Overlay with 'window' set = only included when :WINDOW matches
     - When :WINDOW is NIL, only global overlays are included (so callers
       can paint to a default window without leaking window-bound layers)

   Layers are sorted low-priority first (so they paint as 'bottom'
   first, high-priority overlays paint on top)."
  (let* ((in       (overlays-in start end buf))
         (filtered (remove-if-not
                    (lambda (ov)
                      (let ((w (overlay-get ov 'window)))
                        (cond
                          ((null w)        t)                    ; global overlay
                          ((null window)   nil)                   ; window-bound but no filter
                          (t (equal w window)))))
                    in))
         ;; reverse-sort for paint order: low priority first
         (asc      (stable-sort (copy-list filtered) #'< :key #'%priority)))
    (mapcar #'overlay-as-wire-layer asc)))
