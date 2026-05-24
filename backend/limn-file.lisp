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
           #:*buffer-set-content-fn* #:*minibuffer-yes-no-fn*))

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

(defstruct fbuf
  id
  path
  content
  (modified-p nil))

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
   read content, create a buffer, fire *find-file-hook*."
  (let* ((abs (%normalize path))
         (existing (gethash abs *by-path*)))
    (if existing
        existing
        (progn
          (unless (funcall *file-exists-p-fn* abs)
            (error "limn/file: file does not exist: ~s" abs))
          (let* ((kind  (file-type abs))
                 (id    (%fresh-id))
                 (raw   (if (eq kind :pdf)
                            nil
                            (funcall *read-file-fn* abs)))
                 (content (if (eq kind :pdf)
                              ""
                              (%decode-file-content raw abs id))))
            (when (eq kind :pdf)
              (handler-case (funcall *engine-load-fn* abs id)
                (error () nil)))
            (funcall *buffer-set-content-fn* id content)
            (let ((b (make-fbuf :id id :path abs :content content
                                :modified-p nil)))
              (setf (gethash id  *bufs*)    b
                    (gethash abs *by-path*) id))
            (%run-hooks-safely *find-file-hook* id abs)
            id)))))

(defun %decode-file-content (raw abs buf-id)
  "If limn/coding is available and RAW is a byte vector, detect coding
   and decode to string.  Otherwise return raw as-is (string fallback)."
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
   prompts the user via *minibuffer-yes-no-fn*. Fires *after-revert-hook*."
  (let* ((b (or (gethash buf-id *bufs*)
                (error "limn/file: unknown buffer ~s" buf-id)))
         (path (fbuf-path b)))
    (unless path
      (error "limn/file: buffer ~s has no visited file" buf-id))
    (when (and confirm
               (not (funcall *minibuffer-yes-no-fn*
                             (format nil "Revert ~a from disk?" path))))
      (return-from revert-buffer nil))
    (let ((content (or (funcall *read-file-fn* path) "")))
      (setf (fbuf-content b) content
            (fbuf-modified-p b) nil)
      (funcall *buffer-set-content-fn* buf-id content))
    (%run-hooks-safely *after-revert-hook* buf-id)
    buf-id))
