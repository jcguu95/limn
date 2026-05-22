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
           #:mode-keymap #:mode-name #:mode-type #:mode-modeline-name))

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

   :parent is reserved for keymap-parent linkage and currently not
   wired here — callers can directly (setf (mode-keymap m) ...) with
   a keymap whose parent is some other mode's keymap."
  (declare (ignore parent))
  (let ((existing (gethash name *modes*)))
    (cond
      (existing
       (setf (mode-type existing)          type
             (mode-modeline-name existing) modeline
             (mode-on-enter existing)      on-enter
             (mode-on-exit existing)       on-exit)
       existing)
      (t
       (let ((m (make-mode :name name :type type
                           :modeline-name modeline
                           :on-enter on-enter
                           :on-exit on-exit)))
         (setf (gethash name *modes*) m)
         m)))))

(defun find-mode (name) (gethash name *modes*))

(defun list-modes ()
  (loop for m being the hash-values of *modes* collect m))

(defun clear-modes ()
  "Test helper: wipe the registry."
  (clrhash *modes*))

;;; ── mode-buffer ────────────────────────────────────────────────────────

(defstruct (mode-buffer (:conc-name mode-buffer-) (:predicate mode-buffer-p))
  (major  nil)    ; symbol naming the active major mode, or nil
  (minors '()))   ; list of mode-name symbols, newest first

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

(defun lookup-key (buf spec)
  "Walk minors (newest first) → major. Returns the bound action, or
   NIL if no mode handles SPEC. (Global fallback is the caller's job
   for now — when a global keymap concept lands, layer it here.)"
  (or
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
     (and km (limn/keys:lookup km spec)))))
