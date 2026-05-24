;;;; limn-mode — Mode system (SPEC §1.1 + §9.1).
;;;;
;;;; A mode is a NAMED bundle of (keymap, optional :on-enter / :on-exit
;;;; hooks, modeline-name). Each Limn buffer carries exactly one major
;;;; mode and an ordered list of minor modes (newest first).
;;;;
;;;; Key-lookup order, given a buffer: minor modes (newest first) → major
;;;; → (global, future). limn/keys' keymap parent chains handle further
;;;; fallback if a mode's keymap has a parent.
;;;;
;;;; NOTE: the "mode-buffer" type here is the pure-Lisp abstraction the
;;;; mode system operates on. The wire-level Buffer (with buffer-id) will
;;;; adopt it later via composition — we want this module testable in
;;;; isolation, no bridge dependency.

(defpackage #:limn/mode
  (:use #:cl)
  (:export #:define-mode #:find-mode #:list-modes #:clear-modes
           #:make-mode-buffer #:mode-buffer-p
           #:major-mode #:minor-modes
           #:activate #:deactivate
           #:lookup-key
           #:mode-keymap #:mode-name #:mode-type #:mode-modeline-name
           ;; v0.19 α
           #:*global-keymap*
           ;; v0.19 β
           #:mode-buffer-local-keymap #:set-local-keymap))

(in-package #:limn/mode)

;;; ── mode object ────────────────────────────────────────────────────────

(defstruct (mode (:conc-name mode-))
  name
  type            ; :major or :minor
  keymap          ; limn/keys keymap; settable via (setf mode-keymap)
  modeline-name
  on-enter        ; thunk or nil
  on-exit)        ; thunk or nil

(defvar *modes* (make-hash-table :test 'eq)
  "Global registry: mode-name symbol → mode object.")

(defun define-mode (name &key type parent modeline on-enter on-exit)
  "Register or update a mode under NAME (a symbol).

   If a mode of this NAME already exists, update its fields IN PLACE
   so anyone holding a reference (e.g. buffers that have activated it)
   sees the new behaviour.

   v0.19 α: :parent is now actually wired:
     - validates PARENT names an existing mode (errors otherwise)
     - rejects cycles (errors if PARENT is the new mode's descendant)
     - lazily creates keymap on this mode and on parent if either's
       mode-keymap slot is nil
     - sets (keymap-parent self-km) ← parent-km

   :parent omitted leaves any existing parent link untouched (idempotent
   re-define-mode for everything BUT parent)."
  (let ((existing (gethash name *modes*)))
    (let ((m (cond
               (existing
                (setf (mode-type existing)          type
                      (mode-modeline-name existing) modeline
                      (mode-on-enter existing)      on-enter
                      (mode-on-exit existing)       on-exit)
                existing)
               (t
                (let ((new (make-mode :name name :type type
                                       :modeline-name modeline
                                       :on-enter on-enter
                                       :on-exit on-exit)))
                  (setf (gethash name *modes*) new)
                  new)))))
      ;; v0.19 α: parent linkage
      (when parent
        (%wire-parent m parent))
      m)))

(defun %wire-parent (child-mode parent-name)
  "Establish keymap-parent link CHILD → PARENT (both by mode-name).
   Validates parent exists and cycle would not be created."
  (let ((parent-mode (gethash parent-name *modes*)))
    (unless parent-mode
      (error "limn/mode:define-mode :parent — unknown mode ~s" parent-name))
    (when (eq parent-mode child-mode)
      (error "limn/mode:define-mode :parent — mode ~s cannot be its own parent"
             (mode-name child-mode)))
    ;; Cycle check: walk parent's keymap-parent chain; if we hit child's
    ;; keymap, the would-be link creates a loop.
    (let ((child-km (or (mode-keymap child-mode)
                        (setf (mode-keymap child-mode)
                              (limn/keys:make-keymap))))
          (parent-km (or (mode-keymap parent-mode)
                         (setf (mode-keymap parent-mode)
                               (limn/keys:make-keymap)))))
      (when (%creates-cycle-p child-km parent-km)
        (error "limn/mode:define-mode :parent — cycle: ~s already ancestor of ~s"
               (mode-name child-mode) parent-name))
      (setf (limn/keys:keymap-parent child-km) parent-km))))

(defun %creates-cycle-p (child-km candidate-parent-km)
  "True if setting child's parent to candidate would make a cycle —
   i.e., child-km already appears in candidate's parent chain."
  (loop for k = candidate-parent-km then (limn/keys:keymap-parent k)
        while k
        when (eq k child-km) return t
        finally (return nil)))

(defvar *global-keymap* nil
  "v0.19 α: fallback keymap consulted by lookup-key when neither
   minor nor major modes (nor local / transient) bind the spec.

   Application sets this once at startup, e.g.:
       (setf limn/mode:*global-keymap* (limn/keys:make-keymap))
   Or dynamic-let it from a test fixture.")

(defun find-mode (name) (gethash name *modes*))

(defun list-modes ()
  (loop for m being the hash-values of *modes* collect m))

(defun clear-modes ()
  "Test helper: wipe the registry."
  (clrhash *modes*))

;;; ── mode-buffer ────────────────────────────────────────────────────────

(defstruct (mode-buffer (:conc-name mode-buffer-) (:predicate mode-buffer-p))
  (major  nil)    ; symbol naming the active major mode, or nil
  (minors '())   ; list of mode-name symbols, newest first
  ;; v0.19 β: buffer-local override keymap (Emacs local-set-key).
  ;; Consulted by lookup-key BEFORE minors. Orthogonal to mode
  ;; activation — survives activate/deactivate. Set via set-local-keymap.
  (local-keymap nil))

;; defstruct gives us make-mode-buffer for free; we just re-export it.

(defun major-mode  (buf) (mode-buffer-major  buf))
(defun minor-modes (buf) (mode-buffer-minors buf))

;;; ── hooks ──────────────────────────────────────────────────────────────

(defun %fire-hook (mode which)
  (let ((fn (ecase which
              (:enter (mode-on-enter mode))
              (:exit  (mode-on-exit mode)))))
    (when (functionp fn) (funcall fn))))

;;; ── activation ─────────────────────────────────────────────────────────

(defun activate (buf name)
  "Activate the mode named NAME on BUF.

   :major → replaces the existing major mode (firing :on-exit on the
            outgoing mode, then :on-enter on the new one).
   :minor → pushed to the FRONT of minor-modes (newest first). No-op
            if already active. Fires :on-enter."
  (let ((m (find-mode name)))
    (unless m
      (error "limn/mode:activate: unknown mode ~s" name))
    (ecase (mode-type m)
      (:major
       (let ((old-name (mode-buffer-major buf)))
         (when old-name
           (let ((old-m (find-mode old-name)))
             (when old-m (%fire-hook old-m :exit))))
         (setf (mode-buffer-major buf) name)
         (%fire-hook m :enter)))
      (:minor
       (unless (member name (mode-buffer-minors buf))
         (push name (mode-buffer-minors buf))
         (%fire-hook m :enter))))
    name))

(defun deactivate (buf name)
  "Remove a mode from BUF. For :minor, drops from minor-modes (firing
   :on-exit). For :major, clears the major slot (rare; usually you'd
   activate a different major instead)."
  (let ((m (find-mode name)))
    (unless m
      (error "limn/mode:deactivate: unknown mode ~s" name))
    (ecase (mode-type m)
      (:minor
       (when (member name (mode-buffer-minors buf))
         (setf (mode-buffer-minors buf)
               (remove name (mode-buffer-minors buf)))
         (%fire-hook m :exit)))
      (:major
       (when (eq (mode-buffer-major buf) name)
         (%fire-hook m :exit)
         (setf (mode-buffer-major buf) nil))))
    name))

;;; ── key lookup ─────────────────────────────────────────────────────────

(defun set-local-keymap (buf km)
  "v0.19 β: set BUF's buffer-local override keymap. KM=nil clears.

   Buffer-local: persists across (de)activate of major/minor modes.
   Consulted by lookup-key with priority right after transient (i.e.,
   above minor and major). Mirrors Emacs's local-set-key semantics."
  (setf (mode-buffer-local-keymap buf) km))

(defun lookup-key (buf spec)
  "Walk the v0.19 precedence stack:

      transient → local → minors (newest first) → major → global

   Returns the bound action, or NIL if no layer handles SPEC.
   Within each layer, limn/keys:lookup walks that keymap's own
   parent chain (so e.g. mode → mode-keymap-parent → ... happens
   for free, including v0.19 α's auto-wired :parent links)."
  (or
    ;; Transient (v0.19 β) — highest priority when active
    (and limn/keys:*transient-keymap*
         (limn/keys:lookup limn/keys:*transient-keymap* spec))
    ;; Local (v0.19 β)
    (let ((lkm (mode-buffer-local-keymap buf)))
      (and lkm (limn/keys:lookup lkm spec)))
    ;; Minors, newest first
    (loop for minor-name in (mode-buffer-minors buf)
          for m  = (find-mode minor-name)
          for km = (and m (mode-keymap m))
          for v  = (and km (limn/keys:lookup km spec))
          when v return v)
    ;; Major
    (let* ((major-name (mode-buffer-major buf))
           (m          (and major-name (find-mode major-name)))
           (km         (and m (mode-keymap m))))
      (and km (limn/keys:lookup km spec)))
    ;; Global fallback (v0.19 α)
    (and *global-keymap* (limn/keys:lookup *global-keymap* spec))))
