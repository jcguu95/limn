;;;; limn-bookmark-handlers — per-mode record/jump handlers for the
;;;; cross-buffer bookmark module (v0.37 "bookmark everywhere").
;;;;
;;;; Each major mode that supports bookmarks ships two thunks:
;;;;   record-fn — capture the current location → plist
;;;;   jump-fn   — given that plist, navigate the focus there
;;;;
;;;; This module wires them up for the built-in modes:
;;;;
;;;;   text-mode  / org-mode  → file + cursor offset
;;;;   pdf-mode               → file + page + offset-y + offset-x
;;;;
;;;; All wire I/O goes through a small vtable so unit-tier tests can
;;;; rebind the funs to in-memory mocks — no live Limn binary needed.

(defpackage #:limn/bookmark-handlers
  (:use #:cl)
  (:export #:install
           ;; vtable (rebind in tests)
           #:*text-record-fn*
           #:*text-jump-fn*
           #:*pdf-record-fn*
           #:*pdf-jump-fn*
           ;; default impls (exposed so callers can compose)
           #:default-text-record
           #:default-text-jump
           #:default-pdf-record
           #:default-pdf-jump))

(in-package #:limn/bookmark-handlers)

;;; ── shared helpers ─────────────────────────────────────────────────

(defun %limn-call (cmd &rest kw)
  "Send a wire CMD when the bridge is live; otherwise NIL."
  (let* ((pkg (find-package '#:limn))
         (fn  (and pkg (find-symbol "CALL" pkg))))
    (when (and fn (fboundp fn))
      (handler-case (apply (symbol-function fn) cmd kw)
        (error () nil)))))

(defun %response-data (r)
  (let* ((pkg (find-package '#:limn/bridge))
         (rd  (and pkg (find-symbol "RESPONSE-DATA" pkg))))
    (when (and rd (fboundp rd) r)
      (funcall (symbol-function rd) r))))

(defun %view-get (&optional (win-id "w1"))
  (%response-data (%limn-call "view/get" :|win-id| win-id)))

;;; ── text-mode handler ──────────────────────────────────────────────
;;;
;;; record: (:file PATH :position N)
;;; jump:   open file (idempotent if already open) + buffer/cursor-set

(defun %text-buffer-path (wire-bid)
  "Reverse-look-up the file path for WIRE-BID by scanning the lisp-side
   fbuf table.  limn/file's find-file stores wire-id on each fbuf
   (B10), so this is just a linear scan — text-buffer count is
   typically <10, well below a hashed index's break-even."
  (when wire-bid
    (let ((bufs (find-symbol "*BUFS*" :limn/file)))
      (when (and bufs (boundp bufs))
        (let ((found nil))
          (maphash (lambda (id b)
                     (declare (ignore id))
                     (when (and (not found)
                                (equal wire-bid
                                       (funcall (find-symbol "FBUF-WIRE-ID"
                                                             :limn/file)
                                                b)))
                       (setf found
                             (funcall (find-symbol "FBUF-PATH" :limn/file)
                                      b))))
                   (symbol-value bufs))
          found)))))

(defun default-text-record ()
  "Capture (:file PATH :position N) from the currently-focused text
   buffer.  Returns NIL when there's no focused text buffer or its
   path is unknown (e.g. a never-saved scratch buffer)."
  (let* ((view (%view-get))
         (bid  (and view (getf view :|buffer-id|)))
         (cur  (when bid
                 (or (getf (%response-data
                            (%limn-call "buffer/cursor-get"
                                        :|buffer-id| bid))
                           :|offset|)
                     0)))
         (path (and bid (%text-buffer-path bid))))
    (when (and path cur)
      (list :file path :position cur))))

(defun default-text-jump (record)
  "find-file the recorded path (idempotent — switches to existing
   buffer if open), then cursor-set to the recorded position.

   Signals clearly when the bookmark's :file no longer exists on
   disk — without this check limn/file:find-file would silently
   open an empty new buffer, hiding the fact that the user's note
   was moved or deleted.  cmd-bookmark-jump's handler-case echoes
   the message to the minibuffer."
  (let* ((path (getf record :file))
         (pos  (or (getf record :position) 0))
         (ff   (find-symbol "FIND-FILE" :limn/file)))
    (unless path
      (error "bookmark record missing :file"))
    (unless (probe-file path)
      (error "bookmark target file no longer exists: ~a" path))
    (when (and ff (fboundp ff))
      (let ((fbuf (funcall (symbol-function ff) path)))
        ;; find-file returned the lisp fbuf id; the wire id is what
        ;; buffer/cursor-set wants.
        (let ((wire (let ((wid (find-symbol "BUFFER-WIRE-ID" :limn/file)))
                      (and wid (fboundp wid)
                           (funcall (symbol-function wid) fbuf)))))
          (when wire
            (%limn-call "buffer/cursor-set"
                        :|buffer-id| wire :|offset| pos))
          fbuf)))))

(defvar *text-record-fn* #'default-text-record)
(defvar *text-jump-fn*   #'default-text-jump)

;;; ── pdf-mode handler ───────────────────────────────────────────────
;;;
;;; record: (:path PATH :page P :y-offset Y :x-offset X)
;;; jump:   find-file PATH (loads via mupdf engine) then view/set
;;;         page + offset-y + offset-x

(defun %pdf-buffer-path (bid)
  (when bid
    (let ((tab (find-symbol "*BUFFER-ID-TO-PATH*" :limn/pdf-mode)))
      (and tab (boundp tab)
           (gethash bid (symbol-value tab))))))

(defun default-pdf-record ()
  "Capture (:path P :page N :y-offset Y :x-offset X) for the focused
   PDF buffer.  Returns NIL if the focus isn't a PDF buffer (no
   buffer-id, or no known path)."
  (let* ((view (%view-get))
         (bid  (and view (getf view :|buffer-id|)))
         (path (and bid (%pdf-buffer-path bid))))
    (when path
      (list :path     path
            :page     (or (getf view :|page|) 0)
            :y-offset (or (getf view :|offset-y|) 0)
            :x-offset (or (getf view :|offset-x|) 0)))))

(defun default-pdf-jump (record)
  "Open the PDF at PATH (idempotent) and view/set page + offsets.

   v0.37 fix #1: page + offsets travel in ONE view/set call.  Two
   separate calls let the second one clobber the first (e.g.
   :offset-y 0.0 = absolute doc-coord 0 = page 1, which would
   undo a :page 2 set in the previous call).  C++ cmd_view_set
   handles all three fields atomically in one repaint.

   v0.37 fix #2: missing :path / moved file signals loudly so
   cmd-bookmark-jump's handler-case can echo to the user."
  (let ((path     (getf record :path))
        (page     (or (getf record :page) 0))
        (offset-y (or (getf record :y-offset) 0))
        (offset-x (or (getf record :x-offset) 0))
        (ff       (find-symbol "FIND-FILE" :limn/file)))
    (unless path
      (error "bookmark record missing :path"))
    (unless (probe-file path)
      (error "bookmark target file no longer exists: ~a" path))
    (when (and ff (fboundp ff))
      ;; find-file is idempotent for already-open PDFs.  If it errors
      ;; for an exotic reason (encrypted, mupdf can't parse), we let
      ;; the error propagate — cmd-bookmark-jump catches it.
      (funcall (symbol-function ff) path)
      (%limn-call "view/set" :|win-id| "w1"
                  :|page|     page
                  :|offset-y| (coerce offset-y 'double-float)
                  :|offset-x| (coerce offset-x 'double-float))
      t)))

(defvar *pdf-record-fn* #'default-pdf-record)
(defvar *pdf-jump-fn*   #'default-pdf-jump)

;;; ── installation ───────────────────────────────────────────────────

(defun install ()
  "Register text-mode, org-mode, and pdf-mode handlers with
   limn/bookmark.  Idempotent.  Called from limn.lisp's
   %bootstrap-runtime so a fresh session has them wired before
   the first user keystroke."
  ;; text-mode + org-mode share the same record/jump shape — file +
  ;; cursor offset.  Register identical thunks; we close over the
  ;; vtable vars so user-side rebinding still takes effect.
  (limn/bookmark:register-record-fn
   (intern "TEXT-MODE" :cl-user) (lambda () (funcall *text-record-fn*)))
  (limn/bookmark:register-handler
   (intern "TEXT-MODE" :cl-user) (lambda (rec) (funcall *text-jump-fn* rec)))
  (limn/bookmark:register-record-fn
   (intern "ORG-MODE" :cl-user)  (lambda () (funcall *text-record-fn*)))
  (limn/bookmark:register-handler
   (intern "ORG-MODE" :cl-user)  (lambda (rec) (funcall *text-jump-fn* rec)))
  ;; pdf-mode
  (limn/bookmark:register-record-fn
   (intern "PDF-MODE" :cl-user)  (lambda () (funcall *pdf-record-fn*)))
  (limn/bookmark:register-handler
   (intern "PDF-MODE" :cl-user)  (lambda (rec) (funcall *pdf-jump-fn* rec)))
  t)

(install)
