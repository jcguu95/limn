;;;; limn-file — find-file / save-buffer / revert-buffer + hooks (v0.24 §E, v0.31 §B).
;;;;
;;;; This module wraps v0.22's basic file open/save with the hook chain
;;;; (find-file-hook / before-save-hook / after-save-hook /
;;;; after-revert-hook), buffer-modified-p tracking, path normalization,
;;;; and revert-buffer semantics. I/O is mediated through a vtable so
;;;; unit tests can run against a virtual disk.

(defpackage #:limn/file
  (:use #:cl)
  (:export #:find-file #:save-buffer #:revert-buffer
           #:file-type
           #:visited-file-name
           #:buffer-modified-p #:set-buffer-modified-p
           #:*find-file-hook* #:*before-save-hook*
           #:*after-save-hook* #:*after-revert-hook*
           #:*require-final-newline*
           #:*file-type-alist* #:*default-directory*
           #:*read-file-fn* #:*write-file-fn*
           #:*file-exists-p-fn* #:*engine-load-fn*
           #:*buffer-set-content-fn* #:*minibuffer-yes-no-fn*
           #:*open-text-engine-fn* #:*fetch-wire-content-fn*
           #:buffer-wire-id))

(in-package #:limn/file)

(defvar *find-file-hook*    '())
(defvar *before-save-hook*  '())
(defvar *after-save-hook*   '())
(defvar *after-revert-hook* '())

(defvar *require-final-newline* nil)

(defvar *default-directory*
  (or (handler-case (sb-posix:getcwd) (error () nil)) "/"))

(defvar *file-type-alist*
  '(("pdf"  . :pdf)
    ("epub" . :pdf)
    ("djvu" . :pdf)
    ("txt"  . :text)
    ("lisp" . :text)
    ("md"   . :text)
    ("org"  . :text)
    ("c"    . :text)
    ("h"    . :text)
    ("cpp"  . :text)
    ("py"   . :text)))

(defvar *read-file-fn*
  (lambda (path)
    ;; Read as bytes so limn/coding can detect/decode (Big5, GB18030, etc.).
    ;; If limn/coding isn't loaded, %decode-file-content returns the raw
    ;; bytes-as-string fallback via (or raw "").
    (with-open-file (s path :direction :input
                            :element-type '(unsigned-byte 8)
                            :if-does-not-exist :error)
      (let ((buf (make-array (file-length s)
                             :element-type '(unsigned-byte 8))))
        (read-sequence buf s)
        buf))))

(defvar *write-file-fn*
  (lambda (path content)
    ;; CONTENT may be a string (no buffer-local coding) or a byte vector
    ;; (encoded via limn/coding).  Dispatch on type so both paths work.
    (if (typep content '(vector (unsigned-byte 8)))
        (with-open-file (s path :direction :output
                                :element-type '(unsigned-byte 8)
                                :if-exists :supersede
                                :if-does-not-exist :create)
          (write-sequence content s))
        (with-open-file (s path :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create)
          (write-string content s)))))

(defvar *file-exists-p-fn*
  (lambda (path) (probe-file path)))

(defvar *engine-load-fn*
  (lambda (path bid) (declare (ignore path bid))))

(defvar *buffer-set-content-fn*
  (lambda (bid content) (declare (ignore bid content))))

(defvar *minibuffer-yes-no-fn*
  (lambda (prompt) (declare (ignore prompt)) nil))

;;; v0.39 B10 — text-engine bridge.  Pre-v0.39, find-file created a fbuf
;;; in *bufs* but never told C++ that a text buffer existed.  As a result
;;; xdotool keystrokes fell on whatever window happened to be focused
;;; (usually still the empty PDF view) and self-insert wrote to a buffer
;;; that nobody was reading from on save.  These two hooks let the
;;; runtime bridge inject the wire calls (bridge/engine-load engine=text
;;; + buffer/load-file + text-mode activate) without making limn/file
;;; depend on limn:call directly — unit tests still bind both to no-op.
(defvar *open-text-engine-fn*
  (lambda (path content)
    (declare (ignore path content))
    nil)
  "Hook called when find-file opens a non-PDF (text) buffer.  Receives
   the absolute path and the decoded content already cached on the Lisp
   side.  Should perform the C++-side setup (bridge/engine-load
   engine=text, buffer/load-file to register the path, activate
   text-mode on w1) and return the wire-side buffer-id (string) so
   subsequent save-buffer calls can fetch live content back, or NIL if
   no wire side is available (unit-tier).")

(defvar *fetch-wire-content-fn*
  (lambda (wire-id)
    (declare (ignore wire-id))
    nil)
  "Hook called by save-buffer when an fbuf has a wire-id.  Should
   return the current text content (string) of the C++-side buffer so
   we write the user's edits to disk instead of the stale Lisp-cached
   open-time snapshot.  Returns NIL if unavailable, in which case
   save-buffer falls back to the cached fbuf-content.")

(defstruct fbuf
  id
  path
  content
  (modified-p nil)
  ;; v0.39 B10 — C++ text_buffers id (e.g. "t1") for text-engine buffers.
  ;; NIL for PDF buffers and for unit-tier opens (where no wire is wired).
  (wire-id nil))

(defun buffer-wire-id (buf-id)
  "C++ text_buffers id for BUF-ID, or NIL.  Mirrors visited-file-name in
   shape — exposed so callers (chrome modeline, REPL inspection) can
   chase the wire side without poking at the fbuf struct directly."
  (let ((b (gethash buf-id *bufs*)))
    (and b (fbuf-wire-id b))))

(defvar *bufs*    (make-hash-table :test 'equal))   ; buf-id → fbuf
(defvar *by-path* (make-hash-table :test 'equal))   ; path → buf-id
(defvar *next-id* 1)

(defun %fresh-id ()
  (prog1 (format nil "limn-file-buf-~a" *next-id*) (incf *next-id*)))

(defun %normalize (path)
  "Make PATH absolute relative to *default-directory* if necessary."
  (cond
    ((null path) nil)
    ((and (stringp path) (plusp (length path))
          (char= (char path 0) #\/))
     path)
    (t
     (concatenate 'string
                  (if (and (plusp (length *default-directory*))
                           (char= (char *default-directory*
                                        (1- (length *default-directory*)))
                                  #\/))
                      *default-directory*
                      (concatenate 'string *default-directory* "/"))
                  path))))

(defun %extension (path)
  "Lowercase extension (no dot), or nil if path has none."
  (let ((dot (position #\. path :from-end t)))
    (when (and dot (< dot (1- (length path))))
      (string-downcase (subseq path (1+ dot))))))

(defun file-type (path)
  "Return :pdf / :text / :binary based on *file-type-alist*."
  (let* ((ext (%extension path))
         (hit (and ext (cdr (assoc ext *file-type-alist* :test #'string=)))))
    (or hit :binary)))

(defun visited-file-name (buf-id)
  (let ((b (gethash buf-id *bufs*)))
    (and b (fbuf-path b))))

(defun buffer-modified-p (buf-id)
  (let ((b (gethash buf-id *bufs*)))
    (and b (fbuf-modified-p b))))

(defun set-buffer-modified-p (buf-id flag)
  (let ((b (gethash buf-id *bufs*)))
    (when b (setf (fbuf-modified-p b) (and flag t)))))

(defun %run-hooks-safely (hooks &rest args)
  (dolist (h hooks)
    (handler-case (apply h args)
      (error () nil))))

(defun find-file (path)
  "Open the file at PATH. If a buffer for that (normalized) path
   already exists, return its buf-id without re-reading. Otherwise
   read content (or create empty buffer if file does not exist) and
   fire *find-file-hook*.

   v0.38 B8: matches Emacs semantics — for a non-existent text path,
   open a fresh buffer with empty content + path visited, so the
   user can type and `save-buffer` materializes the file.  Pre-v0.38
   the call raised an error which made `C-x C-f new-file` unusable.
   PDF paths still error when missing (no point opening a 'new PDF'
   buffer)."
  (let* ((abs (%normalize path))
         (existing (gethash abs *by-path*)))
    (if existing
        existing
        (let* ((file-exists-p (funcall *file-exists-p-fn* abs))
               (kind  (file-type abs)))
          (when (and (not file-exists-p) (eq kind :pdf))
            (error "limn/file: PDF file does not exist: ~s" abs))
          (let* ((id    (%fresh-id))
                 (raw   (when (and file-exists-p (not (eq kind :pdf)))
                          (funcall *read-file-fn* abs)))
                 (content (cond
                            ((eq kind :pdf) "")
                            ((not file-exists-p) "")          ; new file: empty
                            (t (%decode-file-content raw abs id)))))
            (when (and file-exists-p (eq kind :pdf))
              (handler-case (funcall *engine-load-fn* abs id)
                (error () nil)))
            (funcall *buffer-set-content-fn* id content)
            ;; v0.39 B10 — text-engine bridge.  For text kind, ask the
            ;; runtime bridge to do bridge/engine-load engine=text +
            ;; buffer/load-file so C++ knows about this buffer and
            ;; xdotool keystrokes route to it via text-mode.  The hook
            ;; returns the C++ wire-id (or NIL in unit-tier where no
            ;; wire is bound).  Wrapped in handler-case so a wire error
            ;; never poisons the Lisp-side fbuf registration.
            (let ((wire (when (not (eq kind :pdf))
                          (handler-case
                              (funcall *open-text-engine-fn* abs content)
                            (error () nil)))))
              (let ((b (make-fbuf :id id :path abs :content content
                                  :modified-p nil :wire-id wire)))
                (setf (gethash id  *bufs*)    b
                      (gethash abs *by-path*) id)))
            (%run-hooks-safely *find-file-hook* id abs)
            id)))))

(defun %decode-file-content (raw abs buf-id)
  "If limn/coding is available and RAW is a byte vector, detect coding
   and decode to string.  Otherwise fall back to a guaranteed-string
   result: bytes are coerced via octets-to-string (UTF-8, lax), strings
   pass through, NIL becomes \"\".  Always returns a string so downstream
   code (bridge JSON encoder, buffer-set-content-fn) never sees raw bytes."
  (let ((cod-pkg (find-package '#:limn/coding)))
    (cond
      ;; Byte vector + coding available → full detection path
      ;; (stringp check needed: strings are vectors in CL, (vectorp "x") = T)
      ((and cod-pkg (typep raw '(vector (unsigned-byte 8))))
       (let* ((detect-fn (symbol-function (find-symbol "DETECT-CODING-SYSTEM" cod-pkg)))
              (decode-fn (symbol-function (find-symbol "DECODE-CODING-STRING" cod-pkg)))
              (set-fn    (symbol-function (find-symbol "SET-BUFFER-FILE-CODING-SYSTEM" cod-pkg)))
              (cs        (funcall detect-fn raw abs))
              (text      (funcall decode-fn raw cs)))
         (funcall set-fn buf-id cs)
         text))
      ;; Byte vector without limn/coding loaded — defense-in-depth UTF-8
      ;; decode so the bridge JSON encoder never sees raw bytes.  Lax
      ;; replacement avoids decoder errors on non-UTF-8 input.
      ((typep raw '(vector (unsigned-byte 8)))
       (handler-case
           (sb-ext:octets-to-string raw :external-format '(:utf-8 :replacement #\?))
         (error () (map 'string #'code-char raw))))
      ;; String (old path, no coding needed)
      (t (or raw "")))))

(defun %encode-buffer-content (content buf-id)
  "If limn/coding is available and the buffer has a coding system,
   encode CONTENT to bytes.  Otherwise return CONTENT (string) unchanged."
  (let ((cod-pkg   (find-package '#:limn/coding))
        (local-pkg (find-package '#:limn/local)))
    (if (and cod-pkg local-pkg)
        (let* ((bcfs-sym (find-symbol "*BUFFER-FILE-CODING-SYSTEM*" cod-pkg))
               (get-fn   (find-symbol "BUFFER-LOCAL-VALUE" local-pkg))
               (cs (when (and bcfs-sym get-fn)
                     (funcall (symbol-function get-fn) bcfs-sym buf-id))))
          (if cs
              (funcall (symbol-function (find-symbol "ENCODE-CODING-STRING" cod-pkg))
                       content cs)
              content))
        content)))

(defun save-buffer (buf-id &optional path)
  "Save the buffer's contents to PATH (or its visited-file-name when
   PATH is nil). Runs *before-save-hook* before writing — errors from
   before-save propagate out so write is skipped. Runs *after-save-hook*
   after writing succeeds."
  (let* ((b (or (gethash buf-id *bufs*)
                (error "limn/file: unknown buffer ~s" buf-id)))
         (target (or path (fbuf-path b))))
    (unless target
      (error "limn/file: no path to save buffer ~s" buf-id))
    ;; v0.39 B10 — for text-engine buffers with a wire-id, the user has
    ;; been typing into the C++ GapBuffer; the Lisp-side fbuf-content is
    ;; the stale open-time snapshot.  Fetch live content first so the
    ;; rest of the save pipeline (hooks, *require-final-newline*,
    ;; *encode-buffer-content*) sees what the user actually edited.
    ;; If the fetch hook returns NIL (unit-tier or wire error), keep
    ;; the cached content — backwards-compatible with v0.38 tests.
    (when (fbuf-wire-id b)
      (let ((live (handler-case
                      (funcall *fetch-wire-content-fn* (fbuf-wire-id b))
                    (error () nil))))
        (when (stringp live)
          (setf (fbuf-content b) live))))
    ;; before-save hooks: errors propagate (cancels save)
    (dolist (h *before-save-hook*)
      (funcall h buf-id))
    (let* ((raw-content (fbuf-content b))
           (content (if (and *require-final-newline*
                             (or (zerop (length raw-content))
                                 (not (char= (char raw-content (1- (length raw-content)))
                                             #\newline))))
                        (concatenate 'string raw-content (string #\newline))
                        raw-content))
           (payload (%encode-buffer-content content buf-id)))
      (funcall *write-file-fn* target payload))
    (setf (fbuf-modified-p b) nil)
    (unless (equal target (fbuf-path b))
      (setf (gethash (fbuf-path b) *by-path*) nil
            (fbuf-path b) target
            (gethash target *by-path*) buf-id))
    (%run-hooks-safely *after-save-hook* buf-id)
    target))

(defun revert-buffer (buf-id &key (confirm t))
  "Re-read the buffer's content from disk. With :confirm t (default),
   prompts the user via *minibuffer-yes-no-fn*. Fires *after-revert-hook*.
   Raw bytes returned by *read-file-fn* are run through %decode-file-content
   (same as find-file) so the buffer always sees a string. v0.35: auto-revert
   needs this to round-trip text correctly via the file-notify event path."
  (let* ((b (or (gethash buf-id *bufs*)
                (error "limn/file: unknown buffer ~s" buf-id)))
         (path (fbuf-path b)))
    (unless path
      (error "limn/file: buffer ~s has no visited file" buf-id))
    (when (and confirm
               (not (funcall *minibuffer-yes-no-fn*
                             (format nil "Revert ~a from disk?" path))))
      (return-from revert-buffer nil))
    (let* ((raw     (or (funcall *read-file-fn* path) ""))
           (content (%decode-file-content raw path buf-id)))
      (setf (fbuf-content b) content
            (fbuf-modified-p b) nil)
      (funcall *buffer-set-content-fn* buf-id content))
    (%run-hooks-safely *after-revert-hook* buf-id)
    buf-id))
