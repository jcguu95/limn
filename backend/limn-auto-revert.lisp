;;;; limn-auto-revert — v0.35 §B: auto-revert-mode + global + tail mode.
;;;;
;;;; A buffer-local minor mode: when enabled, the buffer subscribes to
;;;; filesystem changes via limn/file-notify and, on :modified events,
;;;; re-reads the file (via limn/file:revert-buffer). Modified buffers
;;;; (with unsaved edits) are NOT silently overwritten — they just get a
;;;; *Messages* warning.
;;;;
;;;; All I/O is mediated through a vtable (*revert-buffer-fn*, etc.) so
;;;; unit tests can run against a virtual buffer registry and a mock
;;;; file-notify.

(defpackage #:limn/auto-revert
  (:use #:cl)
  (:export #:auto-revert-mode
           #:global-auto-revert-mode
           #:auto-revert-tail-mode
           #:auto-revert-enabled-p
           #:*auto-revert-interval*
           #:*auto-revert-stop-on-user-input*
           #:tick
           #:reset-auto-revert
           ;; vtable
           #:*file-notify-add-fn*
           #:*file-notify-rm-fn*
           #:*revert-buffer-fn*
           #:*buffer-modified-p-fn*
           #:*visited-file-name-fn*
           #:*buffer-list-fn*
           #:*buffer-text-fn*
           #:*cursor-set-fn*
           #:*message-fn*))

(in-package #:limn/auto-revert)

;;; ── config / vtable defaults ────────────────────────────────────────────

(defvar *auto-revert-interval* 5
  "Seconds between fallback polling ticks (when no file-notify event arrived).")

(defvar *auto-revert-stop-on-user-input* nil
  "If non-nil, auto-revert pauses while the user is typing. Reserved.")

(defvar *file-notify-add-fn*
  (lambda (path flags cb)
    (let ((fn (and (find-package '#:limn/file-notify)
                   (find-symbol "FILE-NOTIFY-ADD-WATCH"
                                '#:limn/file-notify))))
      (if fn (funcall fn path flags cb)
          (error "limn/auto-revert: limn/file-notify not loaded")))))

(defvar *file-notify-rm-fn*
  (lambda (desc)
    (let ((fn (and (find-package '#:limn/file-notify)
                   (find-symbol "FILE-NOTIFY-RM-WATCH"
                                '#:limn/file-notify))))
      (when fn (funcall fn desc)))))

(defvar *revert-buffer-fn*
  (lambda (id &key (confirm t))
    (let ((fn (and (find-package '#:limn/file)
                   (find-symbol "REVERT-BUFFER" '#:limn/file))))
      (if fn (funcall fn id :confirm confirm)
          (error "limn/auto-revert: limn/file not loaded")))))

(defvar *buffer-modified-p-fn*
  (lambda (id)
    (let ((fn (and (find-package '#:limn/file)
                   (find-symbol "BUFFER-MODIFIED-P" '#:limn/file))))
      (when fn (funcall fn id)))))

(defvar *visited-file-name-fn*
  (lambda (id)
    (let ((fn (and (find-package '#:limn/file)
                   (find-symbol "VISITED-FILE-NAME" '#:limn/file))))
      (when fn (funcall fn id)))))

(defvar *buffer-list-fn*
  (lambda () nil))

(defvar *buffer-text-fn*
  (lambda (id) (declare (ignore id)) ""))

(defvar *cursor-set-fn*
  (lambda (id pos) (declare (ignore id pos))))

(defvar *message-fn*
  (lambda (fmt &rest args)
    (let ((fn (and (find-package '#:limn/log)
                   (find-symbol "MESSAGE" '#:limn/log))))
      (if fn (apply fn fmt args)
          (apply #'format *error-output* fmt args)))))

;;; ── state ──────────────────────────────────────────────────────────────

(defstruct ar-entry
  buffer-id
  path
  descriptor
  tail-p)

(defvar *entries* '()                 ; list of AR-ENTRY
  "Per-buffer auto-revert state. One entry per enabled buffer.")

(defvar *global-on* nil
  "True after (global-auto-revert-mode 1).")

(defun reset-auto-revert ()
  "Clear all entries. Intended for tests."
  (dolist (e *entries*)
    (handler-case (funcall *file-notify-rm-fn* (ar-entry-descriptor e))
      (error () nil)))
  (setf *entries* '()
        *global-on* nil)
  nil)

(defun %entry-for (buf-id)
  (find buf-id *entries* :key #'ar-entry-buffer-id :test #'equal))

(defun auto-revert-enabled-p (buf-id)
  (and (%entry-for buf-id) t))

;;; ── event handler ──────────────────────────────────────────────────────

(defun %handle-event (buf-id event)
  "Dispatch an event for BUF-ID. Reverts the buffer for :modified or
   :attribute-changed if the buffer has no unsaved edits."
  (let ((action (getf event :action)))
    (when (member action '(:modified :attribute-changed))
      (cond
        ((funcall *buffer-modified-p-fn* buf-id)
         (funcall *message-fn*
                  "Buffer ~a has unsaved changes; skipping auto-revert"
                  buf-id))
        (t
         (let ((entry (%entry-for buf-id)))
           (handler-case
               (funcall *revert-buffer-fn* buf-id :confirm nil)
             (error (e)
               (funcall *message-fn*
                        "auto-revert: revert failed on ~a: ~a" buf-id e)))
           (when (and entry (ar-entry-tail-p entry))
             (let* ((text (funcall *buffer-text-fn* buf-id))
                    (n (and text (length text))))
               (when n
                 (funcall *cursor-set-fn* buf-id n))))))))))

;;; ── enable / disable ───────────────────────────────────────────────────

(defun %install-watch (buf-id path tail-p)
  "Subscribe BUF-ID to filesystem events on PATH, store the entry."
  (let* ((cb (lambda (ev) (%handle-event buf-id ev)))
         (desc (funcall *file-notify-add-fn* path '(:change) cb)))
    (push (make-ar-entry :buffer-id buf-id
                          :path path
                          :descriptor desc
                          :tail-p tail-p)
          *entries*)
    desc))

(defun %disable (buf-id)
  (let ((e (%entry-for buf-id)))
    (when e
      (handler-case (funcall *file-notify-rm-fn* (ar-entry-descriptor e))
        (error () nil))
      (setf *entries* (remove e *entries* :test #'eq)))))

(defun %enable (buf-id &key tail-p)
  (let ((path (funcall *visited-file-name-fn* buf-id)))
    (unless path
      (error "limn/auto-revert: buffer ~a has no visited file" buf-id))
    (let ((existing (%entry-for buf-id)))
      (cond
        ;; Already on: just update tail-p (idempotent).
        (existing
         (setf (ar-entry-tail-p existing) tail-p)
         existing)
        (t
         (%install-watch buf-id path tail-p))))))

(defun auto-revert-mode (buf-id)
  "Toggle auto-revert on BUF-ID."
  (if (auto-revert-enabled-p buf-id)
      (progn (%disable buf-id) nil)
      (%enable buf-id :tail-p nil)))

(defun auto-revert-tail-mode (buf-id)
  "Toggle tail-revert on BUF-ID (cursor follows append)."
  (if (auto-revert-enabled-p buf-id)
      (progn (%disable buf-id) nil)
      (%enable buf-id :tail-p t)))

(defun global-auto-revert-mode (arg)
  "ARG > 0 → enable on every file-backed buffer.
   ARG < 0 → disable on every buffer.
   The global flag also affects newly-discovered buffers (via tick)."
  (cond
    ((or (and (numberp arg) (plusp arg)) (eq arg t))
     (setf *global-on* t)
     (dolist (id (funcall *buffer-list-fn*))
       (when (and (funcall *visited-file-name-fn* id)
                  (not (auto-revert-enabled-p id)))
         (handler-case (%enable id :tail-p nil) (error () nil)))))
    (t
     (setf *global-on* nil)
     (dolist (e (copy-list *entries*))
       (%disable (ar-entry-buffer-id e))))))

;;; ── tick (fallback polling + buffer-list reconciliation) ───────────────

(defun tick ()
  "Reconciliation pass:
     - drop entries for buffers that have disappeared from buffer-list
     - if no file-notify is available, revert clean buffers anyway
       (interval-based fallback)
     - if global-auto-revert-mode is on, add watches for new file buffers"
  (let ((live (funcall *buffer-list-fn*)))
    ;; Drop entries for dead buffers
    (dolist (e (copy-list *entries*))
      (unless (member (ar-entry-buffer-id e) live :test #'equal)
        (%disable (ar-entry-buffer-id e))))
    ;; Global mode: enable on new file buffers
    (when *global-on*
      (dolist (id live)
        (when (and (funcall *visited-file-name-fn* id)
                   (not (auto-revert-enabled-p id)))
          (handler-case (%enable id :tail-p nil) (error () nil)))))
    ;; Interval fallback: revert clean buffers regardless of events
    (dolist (e (copy-list *entries*))
      (let ((id (ar-entry-buffer-id e)))
        (unless (funcall *buffer-modified-p-fn* id)
          (handler-case
              (funcall *revert-buffer-fn* id :confirm nil)
            (error () nil))))))
  nil)
