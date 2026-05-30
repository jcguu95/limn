;;;; limn-bookmark — cross-buffer, persistent, name-based bookmarks
;;;; (v0.37 — "bookmark everywhere").
;;;;
;;;; The Emacs bookmark.el analog.  Pure Lisp; no C++ wire changes.
;;;;
;;;; Coexists with — but is independent of — the PDF-only bookmark
;;;; system in limn-pdf-mode §E (single-char key, per-doc sidecar,
;;;; C++ wire bookmark/*).  That one stays for `m a` / `' a` Emacs-
;;;; register-style jumps inside one PDF.  This module is the
;;;; cross-document, named, persistent-across-sessions layer that
;;;; works in text-mode / org-mode / pdf-mode buffers alike.
;;;;
;;;; ── Data model ─────────────────────────────────────────────────
;;;;   bookmark = (:name STRING :handler SYMBOL :record PLIST)
;;;;
;;;;   :handler dispatches the jump.  Built-in handlers (registered
;;;;   from per-mode modules):
;;;;     'text-mode  record = (:file PATH :position N [:line L])
;;;;     'pdf-mode   record = (:path PATH :doc-hash STR
;;;;                           :page P :y-offset Y :x-offset X)
;;;;
;;;;   :record is mode-defined.  bookmark-jump only dispatches; it
;;;;   doesn't inspect the record's shape.
;;;;
;;;; ── Storage ───────────────────────────────────────────────────
;;;;   In-memory: *bookmarks* (hash, name → bookmark struct).
;;;;   Persistence: single sidecar at ~/.limn/bookmarks.lisp,
;;;;   serialized as a top-level plist (:version 1 :bookmarks ...).
;;;;
;;;;   Per-PDF persistence still lives in limn-pdf-mode §E
;;;;   (~/.limn/bookmarks/{hash}.lisp) — that's the single-char layer.

(defpackage #:limn/bookmark
  (:use #:cl)
  (:export
   ;; struct + accessors
   #:make-bookmark
   #:bookmark-p
   #:bookmark-name
   #:bookmark-handler
   #:bookmark-record
   ;; store ops
   #:bookmark-add
   #:bookmark-remove
   #:bookmark-rename
   #:bookmark-find
   #:bookmark-list
   #:bookmark-clear
   #:bookmark-count
   ;; handler registry + dispatch
   #:register-handler
   #:unregister-handler
   #:handler-registered-p
   #:bookmark-jump
   ;; record-fn registry (per-mode "make record at current location")
   #:register-record-fn
   #:unregister-record-fn
   #:make-current-record
   ;; persistence
   #:bookmarks-sidecar-path
   #:bookmarks-save
   #:bookmarks-load
   ;; introspection (mostly for tests / debugging)
   #:*bookmarks*
   #:*handler-registry*
   #:*record-fn-registry*))

(in-package #:limn/bookmark)

;;; ── struct ─────────────────────────────────────────────────────────

(defstruct (bookmark (:conc-name bookmark-) (:predicate bookmark-p))
  (name    "" :type string)
  (handler nil)            ; symbol naming a registered handler
  (record  '() :type list))   ; plist; handler-defined shape

;;; ── store ──────────────────────────────────────────────────────────
;;;
;;; Hash for O(1) name lookup.  bookmark-list converts to a name-sorted
;;; list for deterministic UI rendering.

(defvar *bookmarks* (make-hash-table :test 'equal)
  "Global registry: name (string) → bookmark struct.")

(defun bookmark-add (b)
  "Insert or replace B (a bookmark struct) keyed by its name.  Returns B."
  (unless (bookmark-p b)
    (error "limn/bookmark:bookmark-add: not a bookmark struct: ~s" b))
  (setf (gethash (bookmark-name b) *bookmarks*) b)
  b)

(defun bookmark-find (name)
  "Return the bookmark named NAME, or NIL."
  (gethash name *bookmarks*))

(defun bookmark-remove (name)
  "Delete the bookmark named NAME.  Returns T if removed, NIL if absent."
  (when (gethash name *bookmarks*)
    (remhash name *bookmarks*)
    t))

(defun bookmark-rename (old-name new-name)
  "Rename OLD-NAME → NEW-NAME.  Refuses (returns NIL) when:
     - OLD-NAME does not exist, or
     - NEW-NAME is already taken (we don't silently overwrite).
   Returns T on success."
  (let ((b (gethash old-name *bookmarks*)))
    (cond
      ((null b) nil)
      ((gethash new-name *bookmarks*) nil)        ; collision
      (t
       (setf (bookmark-name b) new-name)
       (remhash old-name *bookmarks*)
       (setf (gethash new-name *bookmarks*) b)
       t))))

(defun bookmark-count ()
  (hash-table-count *bookmarks*))

(defun bookmark-clear ()
  "Wipe the in-memory store.  Does NOT touch the sidecar — caller
   should bookmarks-save if they want the wipe to persist."
  (clrhash *bookmarks*))

(defun bookmark-list ()
  "Return all bookmarks as a list, sorted by name (deterministic for
   UI / completion ordering)."
  (let ((out '()))
    (maphash (lambda (k v) (declare (ignore k)) (push v out))
             *bookmarks*)
    (sort out #'string< :key #'bookmark-name)))

;;; ── handler registry ───────────────────────────────────────────────

(defvar *handler-registry* (make-hash-table :test 'eq)
  "handler-symbol → (lambda (record) ...) thunk.  Per-mode modules
   register themselves at module-load time.")

(defun register-handler (handler-symbol jump-fn)
  "Install JUMP-FN as the dispatcher for HANDLER-SYMBOL.  Idempotent —
   re-registration replaces.  JUMP-FN takes one arg, the bookmark
   record plist, and returns whatever (caller doesn't read it)."
  (unless (symbolp handler-symbol)
    (error "limn/bookmark:register-handler: handler must be a symbol, got ~s"
           handler-symbol))
  (unless (functionp jump-fn)
    (error "limn/bookmark:register-handler: jump-fn must be a function"))
  (setf (gethash handler-symbol *handler-registry*) jump-fn)
  handler-symbol)

(defun unregister-handler (handler-symbol)
  "Remove HANDLER-SYMBOL's jump fn.  Future jumps with that handler
   raise.  Returns T if removed."
  (when (gethash handler-symbol *handler-registry*)
    (remhash handler-symbol *handler-registry*)
    t))

(defun handler-registered-p (handler-symbol)
  (and (gethash handler-symbol *handler-registry*) t))

(defun bookmark-jump (name)
  "Look up the bookmark named NAME, find its handler's jump-fn, and
   call it on the bookmark's record.

   Errors clearly when:
     - no bookmark with NAME exists
     - the bookmark's handler has no registered jump-fn (stale data)

   Returns whatever the handler returns."
  (let ((b (gethash name *bookmarks*)))
    (unless b
      (error "limn/bookmark:bookmark-jump: no bookmark named ~s" name))
    (let* ((h  (bookmark-handler b))
           (fn (gethash h *handler-registry*)))
      (unless fn
        (error "limn/bookmark:bookmark-jump: no handler registered for ~s ~
                (bookmark ~s — likely stale persisted data)"
               h name))
      (funcall fn (bookmark-record b)))))

;;; ── record-fn registry ─────────────────────────────────────────────
;;;
;;; A *record-fn* is a thunk (no args) that captures the current
;;; user location for a given mode and returns the record plist.
;;;
;;; bookmark-set: dispatches on the focused buffer's major mode.

(defvar *record-fn-registry* (make-hash-table :test 'eq)
  "mode-symbol → (lambda () => record-plist).")

(defun register-record-fn (mode-symbol record-fn)
  "Install RECORD-FN as the 'capture current location' thunk for
   MODE-SYMBOL.  Idempotent — re-registration replaces."
  (unless (symbolp mode-symbol)
    (error "limn/bookmark:register-record-fn: mode must be a symbol"))
  (unless (functionp record-fn)
    (error "limn/bookmark:register-record-fn: fn must be a function"))
  (setf (gethash mode-symbol *record-fn-registry*) record-fn)
  mode-symbol)

(defun unregister-record-fn (mode-symbol)
  (when (gethash mode-symbol *record-fn-registry*)
    (remhash mode-symbol *record-fn-registry*)
    t))

(defun make-current-record (mode-symbol)
  "Run the registered record-fn for MODE-SYMBOL.  Returns the record
   plist, or NIL if no record-fn is registered for that mode.

   The bookmark-set command checks the return value and bails out
   with a user-visible message when the active mode can't bookmark."
  (let ((fn (gethash mode-symbol *record-fn-registry*)))
    (when fn (funcall fn))))

;;; ── persistence ────────────────────────────────────────────────────
;;;
;;; Single sidecar.  Mirrors the limn/history pattern, except we
;;; serialize the whole store at once (10s-100s of records, not a
;;; ring of 1000+ inputs).  Atomic write via .tmp + rename so a
;;; crash mid-save can't leave a half-written file.

(defun %home ()
  (or (and (find-symbol "GETENV" :sb-posix)
           (funcall (find-symbol "GETENV" :sb-posix) "HOME"))
      (namestring (user-homedir-pathname))))

(defun bookmarks-sidecar-path ()
  "~/.limn/bookmarks.lisp — the default persistence target."
  (pathname (format nil "~a/.limn/bookmarks.lisp" (%home))))

(defun %serialize-bookmark (b)
  "Bookmark struct → plist for read/print round-trip.  Plain plists
   are READ-back as plain plists (no make-load-form dependency on
   the struct definition surviving)."
  (list :name    (bookmark-name b)
        :handler (bookmark-handler b)
        :record  (bookmark-record b)))

(defun %deserialize-bookmark (plist)
  (make-bookmark :name    (or (getf plist :name) "")
                 :handler (getf plist :handler)
                 :record  (or (getf plist :record) '())))

(defun bookmarks-save (&optional path)
  "Write all in-memory bookmarks to PATH (default: bookmarks-sidecar-path).
   Atomic: writes to .tmp + renames.  Returns the path on success."
  (let* ((target (or path (bookmarks-sidecar-path)))
         (payload (list :version 1
                        :bookmarks (mapcar #'%serialize-bookmark
                                           (bookmark-list)))))
    (ensure-directories-exist target)
    (let ((tmp (concatenate 'string (namestring target) ".tmp")))
      (with-open-file (out tmp :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create
                                :external-format :utf-8)
        (let ((*print-readably* t)
              (*print-circle*   nil))
          (write payload :stream out :readably t)
          (terpri out)))
      (rename-file tmp target))
    target))

(defun bookmarks-load (&optional path)
  "Read bookmarks from PATH (default: bookmarks-sidecar-path) and
   ADD them to the in-memory store.  Does NOT clear first — caller
   decides (bookmark-clear if a wipe-then-load is desired).

   Missing file = silent no-op (first-run friendly, matches
   limn/history:load-history).  Malformed file = error caught and
   logged, store untouched."
  (let ((target (or path (bookmarks-sidecar-path))))
    (when (probe-file target)
      (handler-case
          (with-open-file (in target :direction :input
                                     :external-format :utf-8)
            (let* ((data (read in nil nil))
                   (bms  (and (listp data) (getf data :bookmarks))))
              (dolist (p bms)
                (when (listp p)
                  (bookmark-add (%deserialize-bookmark p))))))
        (error (e)
          (format *error-output*
                  ";; limn/bookmark: load failed for ~a: ~a~%"
                  target e)
          nil)))
    (bookmark-count)))
