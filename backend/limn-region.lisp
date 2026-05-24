;;;; limn-region — v0.33 §C region 視覺化（transient-mark-mode integration）
;;;;
;;;; Holds a per-buffer overlay that highlights [point, mark) using the
;;;; `region` face. update-region-overlay reads the current cursor and
;;;; mark from limn/mark + a cursor-fn vtable, then creates / moves /
;;;; clears the overlay accordingly.
;;;;
;;;; Connects to limn/mark via *region-deactivate-hook*: when a
;;;; command-class transition fires deactivate-mark, this module hooks
;;;; in and drops its overlay automatically.

(defpackage #:limn/region
  (:use #:cl)
  (:export #:*region-overlay*
           #:update-region-overlay
           #:clear-region-overlay
           #:region-overlay-for
           ;; vtable — caller wires the cursor-of-buffer fn
           #:*buffer-cursor-fn*))

(in-package #:limn/region)

;;; ── vtable ─────────────────────────────────────────────────────────────

(defvar *buffer-cursor-fn*
  (lambda (bid) (declare (ignore bid)) 0)
  "(buf-id) → cursor offset. Used by update-region-overlay to find
   the region's point endpoint. Defaults to 0.")

;;; ── per-buffer overlay state ───────────────────────────────────────────

(defvar *region-overlay* (make-hash-table :test 'equal)
  "Buf-id → overlay (or nil). The single overlay representing the
   current region in each buffer.")

(defun region-overlay-for (buf-id)
  "Return the region overlay currently shown for BUF-ID, or nil."
  (gethash buf-id *region-overlay*))

;;; ── late binding (gracefully tolerate missing deps) ────────────────────

(defun %mark-pkg () (find-package '#:limn/mark))
(defun %ov-pkg   () (find-package '#:limn/overlays))

(defun %transient-mark-on-p ()
  (let ((p (%mark-pkg)))
    (and p
         (let ((sym (find-symbol "*TRANSIENT-MARK-MODE*" p)))
           (and sym (boundp sym) (symbol-value sym))))))

(defun %mark-active-p (buf-id)
  (let* ((p (%mark-pkg))
         (f (and p (find-symbol "MARK-ACTIVE-P" p))))
    (and f (fboundp f) (funcall f buf-id))))

(defun %mark-of (buf-id)
  (let* ((p (%mark-pkg))
         (f (and p (find-symbol "MARK" p))))
    (and f (fboundp f) (funcall f buf-id))))

(defun %cursor-of (buf-id)
  (funcall *buffer-cursor-fn* buf-id))

(defun %make-overlay (start end buf-id)
  (let* ((p (%ov-pkg))
         (f (and p (find-symbol "MAKE-OVERLAY" p))))
    (when (and f (fboundp f))
      (funcall f start end buf-id))))

(defun %move-overlay (ov start end &optional buf-id)
  (let* ((p (%ov-pkg))
         (f (and p (find-symbol "MOVE-OVERLAY" p))))
    (when (and f (fboundp f))
      (if buf-id
          (funcall f ov start end buf-id)
          (funcall f ov start end)))))

(defun %overlay-put (ov key val)
  (let* ((p (%ov-pkg))
         (f (and p (find-symbol "OVERLAY-PUT" p))))
    (when (and f (fboundp f))
      (funcall f ov key val))))

(defun %delete-overlay (ov)
  (let* ((p (%ov-pkg))
         (f (and p (find-symbol "DELETE-OVERLAY" p))))
    (when (and f (fboundp f))
      (funcall f ov))))

;;; ── public API ────────────────────────────────────────────────────────

(defun clear-region-overlay (buf-id)
  "Drop the region overlay for BUF-ID (if any). Idempotent."
  (let ((ov (gethash buf-id *region-overlay*)))
    (when ov
      (%delete-overlay ov)
      (remhash buf-id *region-overlay*))
    nil))

(defun update-region-overlay (buf-id)
  "Refresh BUF-ID's region overlay to cover [min(point,mark),
   max(point,mark)). When transient-mark-mode is off, or mark is
   inactive / unset, or point == mark, the overlay is cleared instead."
  (cond
    ((not (%transient-mark-on-p))
     (clear-region-overlay buf-id))
    ((not (%mark-active-p buf-id))
     (clear-region-overlay buf-id))
    (t
     (let* ((mk (%mark-of    buf-id))
            (pt (%cursor-of  buf-id)))
       (cond
         ((or (null mk) (eql mk pt))
          (clear-region-overlay buf-id))
         (t
          (let* ((s   (min mk pt))
                 (e   (max mk pt))
                 (cur (gethash buf-id *region-overlay*)))
            (cond
              ((null cur)
               (let ((ov (%make-overlay s e buf-id)))
                 (when ov
                   (%overlay-put ov 'face   'region)
                   (%overlay-put ov 'priority -10)   ; under most other faces
                   (setf (gethash buf-id *region-overlay*) ov))
                 ov))
              (t
               (%move-overlay cur s e)
               cur)))))))))

;;; ── auto-clear on mark deactivate ─────────────────────────────────────
;;;
;;; Install ourselves into limn/mark's *region-deactivate-hook* so that
;;; when a command deactivates the mark (edit command, C-g), the region
;;; overlay disappears without callers having to remember to update.

(let ((mp (%mark-pkg)))
  (when mp
    (let ((hook-sym (find-symbol "*REGION-DEACTIVATE-HOOK*" mp)))
      (when (and hook-sym (boundp hook-sym))
        (set hook-sym #'clear-region-overlay)))))
