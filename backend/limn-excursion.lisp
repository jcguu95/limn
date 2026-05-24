;;;; limn-excursion — v0.32 current-buffer / save-excursion / narrow.
;;;;
;;;; Pure Lisp. Builds on v0.30 markers (limn/marker) for point/mark
;;;; storage that auto-fixes-up on buffer edits, and on v0.30 buffer-local
;;;; variables (limn/local) for per-buffer narrow markers.
;;;;
;;;; SPEC v0.32 §A–E:
;;;;   §A  *current-buffer* dyn var + current-buffer / current-buffer-id /
;;;;       buffer-name / set-buffer / resolve-buffer
;;;;   §B  with-current-buffer macro
;;;;   §C  save-excursion macro (saves buffer + point + mark + mark-active;
;;;;       point/mark stored as markers, so body edits auto-fixup)
;;;;   §D  narrow-to-region / widen / save-restriction + point-min /
;;;;       point-max / narrowed-p (narrow markers are buffer-local)
;;;;   §E  buffer-list / get-buffer / get-buffer-create / kill-buffer /
;;;;       rename-buffer
;;;;
;;;; Vtable injection: the module is C++/wire-agnostic — point/mark/
;;;; text-len queries go through *POINT-FN* / *MARK-FN* / *BUFFER-TEXT-
;;;; LEN-FN* function pointers. The runtime wire-up sets them; unit tests
;;;; install mocks. With no hooks installed, all queries fall back to
;;;; safe nil/zero so the module never crashes from "no runtime yet".

(defpackage #:limn/excursion
  (:use #:cl)
  (:shadow #:point #:point-min #:point-max)
  (:export ;; §A current-buffer
           #:*current-buffer*
           #:current-buffer
           #:current-buffer-id
           #:buffer-name
           #:set-buffer
           #:resolve-buffer
           ;; §B
           #:with-current-buffer
           ;; §C
           #:save-excursion
           ;; §D narrow
           #:narrow-to-region
           #:widen
           #:save-restriction
           #:point-min
           #:point-max
           #:narrowed-p
           ;; point helpers
           #:point
           #:goto-char
           ;; §E lifecycle
           #:buffer-list
           #:get-buffer
           #:get-buffer-create
           #:kill-buffer
           #:rename-buffer
           ;; vtable hooks
           #:*buffer-id-of-fn*
           #:*point-fn*
           #:*set-point-fn*
           #:*mark-fn*
           #:*set-mark-fn*
           #:*mark-active-fn*
           #:*set-mark-active-fn*
           #:*buffer-text-len-fn*
           #:*buffer-name-fn*
           #:*buffer-insert-fn*
           #:*buffer-delete-fn*
           #:*buffer-list-fn*
           #:*get-buffer-fn*
           #:*get-buffer-create-fn*
           #:*kill-buffer-fn*
           #:*rename-buffer-fn*
           ;; registry + test helpers
           #:register-buffer
           #:unregister-buffer
           #:reset-excursion-state))

(in-package #:limn/excursion)

;;; ── vtable hooks ───────────────────────────────────────────────────────

(defvar *current-buffer* nil
  "Current buffer (a buffer object — typically a mode-buffer; can also be
   a string buffer-id when no rich object exists). Dynamic var; rebind
   with with-current-buffer or mutate via set-buffer.")

(defvar *buffer-id-of-fn* nil
  "If non-nil, (fn BUF) → buffer-id string. Used to extract the wire-level
   id from a buffer object when the internal reverse registry doesn't
   know it. Default fallback: look up in *buf->id*, or treat strings as
   self-id.")

(defvar *point-fn*             nil)
(defvar *set-point-fn*         nil)
(defvar *mark-fn*              nil)
(defvar *set-mark-fn*          nil)
(defvar *mark-active-fn*       nil)
(defvar *set-mark-active-fn*   nil)
(defvar *buffer-text-len-fn*   nil)
(defvar *buffer-name-fn*       nil)
(defvar *buffer-insert-fn*     nil)
(defvar *buffer-delete-fn*     nil)
(defvar *buffer-list-fn*       nil
  "If non-nil, () → list of buffer objects (override of internal registry).")
(defvar *get-buffer-fn*        nil)
(defvar *get-buffer-create-fn* nil)
(defvar *kill-buffer-fn*       nil)
(defvar *rename-buffer-fn*     nil)

;;; ── internal registry ──────────────────────────────────────────────────
;;;
;;; Buffers are registered by (object, id [, name]). The forward map
;;; *buffers* keys by id; reverse map *buf->id* keys by object identity.
;;; This lets buffer-list / get-buffer / current-buffer-id all work
;;; without requiring a vtable hook for every operation.

(defvar *buffers*  (make-hash-table :test 'equal))   ; id → object
(defvar *buf->id*  (make-hash-table :test 'eq))      ; object → id
(defvar *id->name* (make-hash-table :test 'equal))   ; id → name (override)

(defun register-buffer (obj id &key name)
  "Register OBJ under ID (string). Optionally with display NAME.
   Idempotent."
  (setf (gethash id *buffers*) obj
        (gethash obj *buf->id*) id)
  (when name (setf (gethash id *id->name*) name))
  obj)

(defun unregister-buffer (id-or-obj)
  "Remove from the registry."
  (let* ((id (if (stringp id-or-obj)
                 id-or-obj
                 (gethash id-or-obj *buf->id*)))
         (obj (and id (gethash id *buffers*))))
    (when id
      (remhash id *buffers*)
      (remhash id *id->name*))
    (when obj
      (remhash obj *buf->id*))))

(defun reset-excursion-state ()
  "Clear all registry state. For test isolation."
  (clrhash *buffers*)
  (clrhash *buf->id*)
  (clrhash *id->name*)
  (setf *current-buffer* nil)
  nil)

;;; ── id / name extraction ───────────────────────────────────────────────

(defun %id-of (buf)
  "Best-effort: extract buffer-id from BUF. Returns nil if unresolvable."
  (cond
    ((null buf) nil)
    ((stringp buf) buf)
    (*buffer-id-of-fn* (funcall *buffer-id-of-fn* buf))
    (t (gethash buf *buf->id*))))

(defun %name-of (id)
  "Look up display name for ID. Priority: explicit override → vtable
   *buffer-name-fn* → id itself."
  (or (gethash id *id->name*)
      (and *buffer-name-fn* (funcall *buffer-name-fn* id))
      id))

;;; ── downstream-package sync ───────────────────────────────────────────
;;;
;;; limn/marker and limn/local each track *current-buffer-id*. v0.32
;;; promotes our richer *current-buffer* as the source of truth; this
;;; helper pushes the new id into both downstream packages so any
;;; subsequent marker / buffer-local op uses the right buf-id.

(defun %sync-current-buffer-id (bid)
  (dolist (pkg-name '(#:limn/marker #:limn/local))
    (let ((pkg (find-package pkg-name)))
      (when pkg
        (let ((sym (find-symbol "*CURRENT-BUFFER-ID*" pkg)))
          (when (and sym (boundp sym))
            (set sym bid)))))))

;;; ── §A. current-buffer / current-buffer-id / buffer-name / set-buffer ──

(defun current-buffer () *current-buffer*)

(defun current-buffer-id ()
  (and *current-buffer* (%id-of *current-buffer*)))

(defun buffer-name (&optional buf)
  (let* ((b (or buf *current-buffer*))
         (id (%id-of b)))
    (when id (%name-of id))))

(defun resolve-buffer (buf-or-spec)
  "Resolve BUF-OR-SPEC (object / buffer-id string / display name) to a
   buffer object. Returns nil if not found."
  (cond
    ((null buf-or-spec) nil)
    ((stringp buf-or-spec)
     (or
      ;; vtable override first (for prod runtime)
      (and *get-buffer-fn* (funcall *get-buffer-fn* buf-or-spec))
      ;; by id
      (gethash buf-or-spec *buffers*)
      ;; by name (via %name-of so rename overrides win over vtable)
      (let ((found nil))
        (maphash (lambda (id obj)
                   (when (and (null found)
                              (equal (%name-of id) buf-or-spec))
                     (setf found obj)))
                 *buffers*)
        found)))
    ;; Already a buffer object — return as-is (regardless of registration,
    ;; since callers may have a live reference).
    (t buf-or-spec)))

(defun set-buffer (buf-or-spec)
  "Set *current-buffer* to BUF-OR-SPEC (resolved). Errors if unknown."
  (let ((resolved (resolve-buffer buf-or-spec)))
    (unless resolved
      (error "set-buffer: unknown buffer ~s" buf-or-spec))
    (setf *current-buffer* resolved)
    (%sync-current-buffer-id (%id-of resolved))
    resolved))

;;; ── §B. with-current-buffer ───────────────────────────────────────────

(defmacro with-current-buffer (buf &body body)
  "Dynamically bind *current-buffer* (and downstream *current-buffer-id*
   in limn/marker / limn/local) to BUF for the duration of BODY.
   BUF may be a buffer object, buffer-id string, or display name."
  (let ((spec (gensym "SPEC"))
        (resolved (gensym "RES"))
        (new-id (gensym "NID"))
        (old-mid (gensym "OMID"))
        (old-lid (gensym "OLID"))
        (mpkg-sym (gensym "MPSYM"))
        (lpkg-sym (gensym "LPSYM")))
    `(let* ((,spec ,buf)
            (,resolved (resolve-buffer ,spec)))
       (unless ,resolved
         (error "with-current-buffer: unknown buffer ~s" ,spec))
       (let* ((,new-id  (%id-of ,resolved))
              (,mpkg-sym (let ((p (find-package '#:limn/marker)))
                           (and p (find-symbol "*CURRENT-BUFFER-ID*" p))))
              (,lpkg-sym (let ((p (find-package '#:limn/local)))
                           (and p (find-symbol "*CURRENT-BUFFER-ID*" p))))
              (,old-mid (and ,mpkg-sym (boundp ,mpkg-sym)
                             (symbol-value ,mpkg-sym)))
              (,old-lid (and ,lpkg-sym (boundp ,lpkg-sym)
                             (symbol-value ,lpkg-sym))))
         (declare (ignorable ,old-mid ,old-lid))
         (let ((*current-buffer* ,resolved))
           (unwind-protect
                (progn
                  (when ,mpkg-sym (set ,mpkg-sym ,new-id))
                  (when ,lpkg-sym (set ,lpkg-sym ,new-id))
                  ,@body)
             (when ,mpkg-sym (set ,mpkg-sym ,old-mid))
             (when ,lpkg-sym (set ,lpkg-sym ,old-lid))))))))

;;; ── point / goto-char (vtable-backed) ─────────────────────────────────

(defun point ()
  "Current point in the current buffer (codepoint offset)."
  (let ((bid (current-buffer-id)))
    (when (and *point-fn* bid)
      (funcall *point-fn* bid))))

(defun goto-char (n)
  "Set point in the current buffer to N (clamped to [point-min,point-max])."
  (let ((bid (current-buffer-id)))
    (when (and *set-point-fn* bid)
      (let* ((lo (point-min))
             (hi (point-max))
             (clamped (max lo (min hi n))))
        (funcall *set-point-fn* bid clamped)))))

(defun %get-mark (bid)
  (and *mark-fn* bid (funcall *mark-fn* bid)))

(defun %set-mark (bid pos)
  (and *set-mark-fn* bid (funcall *set-mark-fn* bid pos)))

(defun %get-mark-active (bid)
  (and *mark-active-fn* bid (funcall *mark-active-fn* bid)))

(defun %set-mark-active (bid val)
  (and *set-mark-active-fn* bid (funcall *set-mark-active-fn* bid val)))

(defun %text-len (bid)
  (if (and *buffer-text-len-fn* bid)
      (funcall *buffer-text-len-fn* bid)
      0))

;;; ── §D. narrow / widen / save-restriction / point-min / point-max ─────

;;; Narrow markers live as buffer-locals in limn/local. They're real
;;; limn/marker markers so they auto-fixup on buffer edits.

(eval-when (:load-toplevel :execute)
  (let ((lpkg (find-package '#:limn/local)))
    (when lpkg
      (let ((make-bl (find-symbol "MAKE-VARIABLE-BUFFER-LOCAL" lpkg)))
        (when make-bl
          (funcall make-bl '*narrow-start-marker*)
          (funcall make-bl '*narrow-end-marker*))))))

(defvar *narrow-start-marker* nil
  "Buffer-local. nil = no left narrow boundary.")
(defvar *narrow-end-marker*   nil
  "Buffer-local. nil = no right narrow boundary.")

(defun %narrow-start (bid)
  (let ((lpkg (find-package '#:limn/local)))
    (and lpkg bid
         (funcall (find-symbol "BUFFER-LOCAL-VALUE" lpkg)
                  '*narrow-start-marker* bid))))

(defun %narrow-end (bid)
  (let ((lpkg (find-package '#:limn/local)))
    (and lpkg bid
         (funcall (find-symbol "BUFFER-LOCAL-VALUE" lpkg)
                  '*narrow-end-marker* bid))))

(defun %set-narrow-start (bid m)
  (let ((lpkg (find-package '#:limn/local)))
    (when (and lpkg bid)
      (funcall (find-symbol "SET-BUFFER-LOCAL-VALUE" lpkg)
               '*narrow-start-marker* m bid))))

(defun %set-narrow-end (bid m)
  (let ((lpkg (find-package '#:limn/local)))
    (when (and lpkg bid)
      (funcall (find-symbol "SET-BUFFER-LOCAL-VALUE" lpkg)
               '*narrow-end-marker* m bid))))

(defun %make-narrow-marker (bid pos)
  "Create a marker at POS in BID. Returns the marker."
  (let ((mpkg (find-package '#:limn/marker)))
    (when mpkg
      (let* ((make (find-symbol "MAKE-MARKER" mpkg))
             (setm (find-symbol "SET-MARKER" mpkg))
             (m    (and make (funcall make))))
        (when (and m setm) (funcall setm m pos bid))
        m))))

(defun %marker-pos (m)
  (let ((mpkg (find-package '#:limn/marker)))
    (when (and mpkg m)
      (funcall (find-symbol "MARKER-POSITION" mpkg) m))))

(defun %release-marker (m)
  (let ((mpkg (find-package '#:limn/marker)))
    (when (and mpkg m)
      (funcall (find-symbol "SET-MARKER" mpkg) m nil))))

(defun narrowed-p ()
  "True iff the current buffer has narrowing active."
  (let ((bid (current-buffer-id)))
    (and bid
         (or (%narrow-start bid)
             (%narrow-end bid))
         t)))

(defun point-min ()
  "Lowest accessible point in current buffer (respects narrowing)."
  (let* ((bid (current-buffer-id))
         (m   (%narrow-start bid))
         (mp  (%marker-pos m)))
    (or mp 0)))

(defun point-max ()
  "Highest accessible point in current buffer (respects narrowing)."
  (let* ((bid (current-buffer-id))
         (m   (%narrow-end bid))
         (mp  (%marker-pos m)))
    (or mp (%text-len bid))))

(defun narrow-to-region (start end)
  "Limit point-min/point-max to [START, END)."
  (when (> start end)
    (error "narrow-to-region: start (~a) > end (~a)" start end))
  (let* ((bid (current-buffer-id))
         (len (%text-len bid))
         (s (max 0 (min start len)))
         (e (max s (min end len))))
    (unless bid
      (error "narrow-to-region: no current buffer"))
    ;; release any pre-existing markers to keep marker-count tidy
    (%release-marker (%narrow-start bid))
    (%release-marker (%narrow-end   bid))
    (%set-narrow-start bid (%make-narrow-marker bid s))
    (%set-narrow-end   bid (%make-narrow-marker bid e))
    nil))

(defun widen ()
  "Remove narrowing in current buffer."
  (let ((bid (current-buffer-id)))
    (when bid
      (%release-marker (%narrow-start bid))
      (%release-marker (%narrow-end   bid))
      (%set-narrow-start bid nil)
      (%set-narrow-end   bid nil)))
  nil)

(defmacro save-restriction (&body body)
  "Save current buffer's narrowing state; restore on body exit (normal
   or error)."
  (let ((bid (gensym "BID"))
        (saved-s (gensym "SS"))
        (saved-e (gensym "SE"))
        (saved-s-pos (gensym "SSP"))
        (saved-e-pos (gensym "SEP")))
    `(let* ((,bid (current-buffer-id))
            (,saved-s (and ,bid (%narrow-start ,bid)))
            (,saved-e (and ,bid (%narrow-end   ,bid)))
            (,saved-s-pos (%marker-pos ,saved-s))
            (,saved-e-pos (%marker-pos ,saved-e)))
       (unwind-protect
            (progn ,@body)
         (when ,bid
           (%release-marker (%narrow-start ,bid))
           (%release-marker (%narrow-end   ,bid))
           (cond
             ((and ,saved-s-pos ,saved-e-pos)
              (%set-narrow-start
               ,bid (%make-narrow-marker ,bid ,saved-s-pos))
              (%set-narrow-end
               ,bid (%make-narrow-marker ,bid ,saved-e-pos)))
             (t
              (%set-narrow-start ,bid nil)
              (%set-narrow-end   ,bid nil))))))))

;;; ── §C. save-excursion ───────────────────────────────────────────────

(defmacro save-excursion (&body body)
  "Save current buffer + point + mark + mark-active; restore on body exit.
   Point and mark are stored as markers so body-side edits auto-fixup."
  (let ((saved-buf (gensym "SBUF"))
        (saved-bid (gensym "SBID"))
        (pm (gensym "PM"))
        (mm (gensym "MM"))
        (ma (gensym "MA")))
    `(let* ((,saved-buf *current-buffer*)
            (,saved-bid (%id-of ,saved-buf))
            (,pm (when ,saved-bid
                   (%make-narrow-marker ,saved-bid
                                        (or (and *point-fn*
                                                 (funcall *point-fn*
                                                          ,saved-bid))
                                            0))))
            (,mm (let ((mv (%get-mark ,saved-bid)))
                   (when (and ,saved-bid mv)
                     (%make-narrow-marker ,saved-bid mv))))
            (,ma (%get-mark-active ,saved-bid)))
       (unwind-protect
            (progn ,@body)
         ;; restore current buffer (and downstream ids)
         (setf *current-buffer* ,saved-buf)
         (%sync-current-buffer-id ,saved-bid)
         ;; restore point
         (when (and ,pm *set-point-fn* ,saved-bid)
           (let ((p (%marker-pos ,pm)))
             (when p (funcall *set-point-fn* ,saved-bid p))))
         (%release-marker ,pm)
         ;; restore mark
         (when ,mm
           (let ((p (%marker-pos ,mm)))
             (when p (%set-mark ,saved-bid p))))
         (%release-marker ,mm)
         ;; restore mark-active
         (when ,saved-bid
           (%set-mark-active ,saved-bid ,ma))))))

;;; ── §E. buffer lifecycle ─────────────────────────────────────────────

(defun buffer-list ()
  "List all registered buffer objects."
  (cond
    (*buffer-list-fn* (funcall *buffer-list-fn*))
    (t (let ((bs '()))
         (maphash (lambda (id obj)
                    (declare (ignore id))
                    (push obj bs))
                  *buffers*)
         (nreverse bs)))))

(defun get-buffer (name-or-id)
  "Find a buffer by NAME-OR-ID. Returns nil if not found.
   resolve-buffer signals on object inputs; get-buffer is strictly
   string-keyed, so we filter."
  (cond
    ((null name-or-id) nil)
    ((stringp name-or-id) (resolve-buffer name-or-id))
    (t nil)))

(defun get-buffer-create (name &key engine)
  "Return existing buffer named NAME, or create a fresh one if absent."
  (declare (ignore engine))
  (cond
    (*get-buffer-create-fn* (funcall *get-buffer-create-fn* name))
    (t
     (or (get-buffer name)
         ;; create a minimal object — a plist that carries the id/name.
         ;; Callers needing a richer buffer object should install
         ;; *get-buffer-create-fn*.
         (let ((obj (list :|buffer-id| name :|name| name)))
           (register-buffer obj name :name name)
           obj)))))

(defun kill-buffer (&optional buf)
  "Remove BUF (default = current) from the registry."
  (cond
    (*kill-buffer-fn* (funcall *kill-buffer-fn* (or buf *current-buffer*)))
    (t (let ((target (or buf *current-buffer*)))
         (when target
           (let ((id (%id-of target)))
             (unregister-buffer id))))))
  nil)

(defun rename-buffer (new-name)
  "Rename the current buffer's display name to NEW-NAME."
  (cond
    (*rename-buffer-fn* (funcall *rename-buffer-fn*
                                 *current-buffer* new-name))
    (t (let ((bid (current-buffer-id)))
         (when bid (setf (gethash bid *id->name*) new-name)))))
  new-name)
