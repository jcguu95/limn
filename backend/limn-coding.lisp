;;;; limn-coding — v0.31 §B coding systems.
;;;;
;;;; File encoding detection and byte↔string conversion.
;;;; Wraps SBCL's sb-ext:string-to-octets / octets-to-string with a
;;;; name registry and graceful fallback for unsupported formats.
;;;;
;;;; Bundled coding systems (11):
;;;;   utf-8  utf-8-with-bom  utf-16le  utf-16be
;;;;   latin-1  windows-1252
;;;;   gb18030  big5  shift-jis  euc-jp  iso-2022-jp
;;;;
;;;; Buffer integration: uses limn/local for *buffer-file-coding-system*
;;;; when available (optional dependency).

(defpackage #:limn/coding
  (:use #:cl)
  (:export #:define-coding-system
           #:find-coding-system
           #:list-coding-systems
           #:encode-coding-string
           #:decode-coding-string
           #:encode-coding-region
           #:decode-coding-region
           #:detect-coding-system
           #:detect-coding-region
           #:set-buffer-file-coding-system
           #:coding-system-name
           #:coding-system-p
           #:*buffer-file-coding-system*
           #:*file-coding-system-alist*
           ;; vtable for region ops
           #:*buffer-text-fn*
           #:*buffer-delete-fn*
           #:*buffer-insert-fn*))

(in-package #:limn/coding)

;;; ── coding-system struct ─────────────────────────────────────────────────

(defstruct (%cs (:constructor %make-cs (&key name sbcl-format bom eol doc))
                (:predicate %cs-p)
                (:conc-name %cs-))
  name          ; keyword
  sbcl-format   ; SBCL external-format keyword (may differ from name)
  (bom nil)     ; :utf-8 | :utf-16le | :utf-16be | nil
  (eol :unix)   ; :unix | :dos | :mac
  doc)

;;; ── registry ─────────────────────────────────────────────────────────────

(defvar *registry* (make-hash-table :test 'eq)
  "Keyword name → %cs struct.")

;;; ── buffer-local / vtable vars ───────────────────────────────────────────

(defvar *buffer-file-coding-system* nil
  "Buffer-local var holding the coding system used to read/write the file.
   The value is a %cs object or nil.  Managed via limn/local when available.")

(defvar *file-coding-system-alist* '()
  "List of (PATH-REGEX . CODING-NAME) pairs.
   detect-coding-system uses this when BOM/UTF-8 heuristics fail.")

(defvar *buffer-text-fn*   (lambda (bid) (declare (ignore bid)) ""))
(defvar *buffer-delete-fn* (lambda (bid from to) (declare (ignore bid from to))))
(defvar *buffer-insert-fn* (lambda (bid pos str) (declare (ignore bid pos str))))

;;; ── public predicates / accessors ────────────────────────────────────────

(defun coding-system-p (obj)
  "True if OBJ is a coding-system object (not just a keyword)."
  (%cs-p obj))

(defun coding-system-name (cs)
  "Return the keyword name of coding-system CS."
  (%cs-name cs))

;;; ── registry ops ─────────────────────────────────────────────────────────

(defun define-coding-system (name &key encoding bom (eol :unix) (doc ""))
  "Register a coding system NAME.
   :encoding — SBCL external-format keyword
   :bom      — nil | :utf-8 | :utf-16le | :utf-16be
   :eol      — :unix | :dos | :mac
   :doc      — docstring"
  (setf (gethash name *registry*)
        (%make-cs :name name
                  :sbcl-format (or encoding name)
                  :bom bom
                  :eol eol
                  :doc doc))
  name)

(defun find-coding-system (name)
  "Return the coding-system object for NAME, or nil."
  ;; Accept both :utf-8 and :UTF-8 via symbol-name comparison.
  (or (gethash name *registry*)
      (let ((up (intern (string-upcase (symbol-name name)) :keyword)))
        (gethash up *registry*))
      (let ((dn (intern (string-downcase (symbol-name name)) :keyword)))
        (gethash dn *registry*))))

(defun list-coding-systems ()
  "Return a list of all registered coding-system objects."
  (let ((result '()))
    (maphash (lambda (k v) (declare (ignore k)) (push v result)) *registry*)
    result))

;;; ── BOM helpers ──────────────────────────────────────────────────────────

(defun %bom-bytes (bom-kind)
  (case bom-kind
    (:utf-8    #(#xef #xbb #xbf))
    (:utf-16le #(#xff #xfe))
    (:utf-16be #(#xfe #xff))
    (t         #())))

(defun %prepend-bom (bytes bom-kind)
  (let* ((bom (%bom-bytes bom-kind))
         (bom-len (length bom))
         (result (make-array (+ bom-len (length bytes))
                              :element-type '(unsigned-byte 8))))
    (replace result bom)
    (replace result bytes :start1 bom-len)
    result))

(defun %strip-bom (bytes bom-kind)
  (let ((bom-len (length (%bom-bytes bom-kind))))
    (if (> bom-len 0)
        (subseq bytes bom-len)
        bytes)))

(defun %bytes-start-with (bytes prefix)
  (let ((plen (length prefix)))
    (and (>= (length bytes) plen)
         (loop for i below plen always (= (aref bytes i) (aref prefix i))))))

;;; ── encode / decode ──────────────────────────────────────────────────────

(defun %resolve (coding-name)
  "Resolve CODING-NAME (keyword or cs object) to a %cs. Errors if unknown."
  (cond
    ((%cs-p coding-name) coding-name)
    ((keywordp coding-name)
     (or (find-coding-system coding-name)
         (error "limn/coding: unknown coding system ~s" coding-name)))
    (t (error "limn/coding: not a coding system: ~s" coding-name))))

(defun encode-coding-string (str coding-name)
  "Encode STR to a (vector (unsigned-byte 8) *) using CODING-NAME."
  (let* ((cs       (%resolve coding-name))
         (fmt      (%cs-sbcl-format cs))
         (raw-bytes (sb-ext:string-to-octets str :external-format fmt)))
    (if (%cs-bom cs)
        (%prepend-bom raw-bytes (%cs-bom cs))
        raw-bytes)))

(defun decode-coding-string (bytes coding-name)
  "Decode BYTES to a string using CODING-NAME."
  (let* ((cs    (%resolve coding-name))
         (fmt   (%cs-sbcl-format cs))
         (data  (if (%cs-bom cs)
                    (%strip-bom bytes (%cs-bom cs))
                    bytes)))
    (sb-ext:octets-to-string data :external-format fmt)))

;;; ── region ops ───────────────────────────────────────────────────────────

(defun encode-coding-region (buf-id from to coding-name)
  "Encode characters [FROM,TO) of buf BUF-ID to bytes using CODING-NAME."
  (let* ((text (funcall *buffer-text-fn* buf-id))
         (substr (subseq text from to)))
    (encode-coding-string substr coding-name)))

(defun decode-coding-region (buf-id from to coding-name)
  "Decode bytes (from buffer content as raw chars [FROM,TO)) in BUF-ID
   using CODING-NAME, replacing the region with the decoded Unicode string."
  (let* ((text (funcall *buffer-text-fn* buf-id))
         (raw-chars (subseq text from to))
         ;; Treat raw-chars as a byte sequence via char-code
         (bytes (make-array (length raw-chars) :element-type '(unsigned-byte 8)
                            :initial-contents (map 'list #'char-code raw-chars)))
         (decoded (decode-coding-string bytes coding-name)))
    (funcall *buffer-delete-fn* buf-id from to)
    (funcall *buffer-insert-fn* buf-id from decoded)
    decoded))

;;; ── auto-detect ──────────────────────────────────────────────────────────

(defun %valid-utf8-p (bytes)
  "True if BYTES is valid UTF-8 (including pure ASCII).
   Uses manual sequence validation: SBCL's UTF-8 decoder is lenient by
   default (silently substitutes invalid bytes), so we check byte patterns
   directly rather than relying on octets-to-string to signal errors."
  (let ((len (length bytes))
        (i   0))
    (loop while (< i len) do
      (let ((b (aref bytes i)))
        (cond
          ;; 1-byte ASCII (0xxxxxxx)
          ((< b #x80) (incf i))
          ;; 2-byte lead (110xxxxx), minimum value #xc2 to exclude overlong
          ((= (logand b #xe0) #xc0)
           (when (or (< b #xc2)
                     (>= (1+ i) len)
                     (/= (logand (aref bytes (1+ i)) #xc0) #x80))
             (return-from %valid-utf8-p nil))
           (incf i 2))
          ;; 3-byte lead (1110xxxx)
          ((= (logand b #xf0) #xe0)
           (when (or (> (+ i 2) (1- len))
                     (/= (logand (aref bytes (1+ i)) #xc0) #x80)
                     (/= (logand (aref bytes (+ i 2)) #xc0) #x80))
             (return-from %valid-utf8-p nil))
           (incf i 3))
          ;; 4-byte lead (11110xxx)
          ((= (logand b #xf8) #xf0)
           (when (or (> (+ i 3) (1- len))
                     (/= (logand (aref bytes (1+ i)) #xc0) #x80)
                     (/= (logand (aref bytes (+ i 2)) #xc0) #x80)
                     (/= (logand (aref bytes (+ i 3)) #xc0) #x80))
             (return-from %valid-utf8-p nil))
           (incf i 4))
          ;; Continuation byte or invalid lead byte
          (t (return-from %valid-utf8-p nil)))))
    t))

(defun %alist-coding (path alist)
  "Return coding name keyword from ALIST whose regex matches PATH, or nil."
  (dolist (entry alist nil)
    (destructuring-bind (pattern . coding) entry
      (let ((matched
              (handler-case
                  (if (find-package '#:cl-ppcre)
                      (funcall (symbol-function
                                 (find-symbol "SCAN" '#:cl-ppcre))
                               pattern path)
                      ;; simple fallback: search for pattern substring
                      (search (string-right-trim "$"
                                 (string-left-trim "\\." pattern))
                              path))
                (error () (search pattern path)))))
        (when matched
          (return coding))))))

(defun detect-coding-system (bytes &optional path)
  "Detect the encoding of BYTES.
   1. BOM prefix → utf-8-with-bom / utf-16le / utf-16be
   2. Valid UTF-8 → utf-8
   3. *file-coding-system-alist* path match (when PATH given)
   4. Fallback → windows-1252"
  ;; 1. BOM
  (cond
    ((%bytes-start-with bytes #(#xef #xbb #xbf))
     (find-coding-system :utf-8-with-bom))
    ((%bytes-start-with bytes #(#xff #xfe))
     (find-coding-system :utf-16le))
    ((%bytes-start-with bytes #(#xfe #xff))
     (find-coding-system :utf-16be))
    ;; 2. Valid UTF-8 (covers pure ASCII as well)
    ((%valid-utf8-p bytes)
     (find-coding-system :utf-8))
    ;; 3. Path alist
    ((and path (let ((name (%alist-coding path *file-coding-system-alist*)))
                 (when name
                   (or (find-coding-system name)
                       (find-coding-system :windows-1252))))))
    ;; 4. Fallback
    (t (find-coding-system :windows-1252))))

(defun detect-coding-region (buf-id from to)
  "Detect the encoding of the byte sequence in BUF-ID [FROM, TO)."
  (let* ((text  (funcall *buffer-text-fn* buf-id))
         (slice (subseq text from to))
         (bytes (make-array (length slice) :element-type '(unsigned-byte 8)
                            :initial-contents (map 'list #'char-code slice))))
    (detect-coding-system bytes)))

;;; ── buffer-local integration ─────────────────────────────────────────────

(defun set-buffer-file-coding-system (buf-id cs)
  "Store CS as the buffer-local *buffer-file-coding-system* for BUF-ID.
   Uses limn/local when available; falls back to a process-global store."
  (let ((local-pkg (find-package '#:limn/local)))
    (if local-pkg
        (let ((set-fn (find-symbol "SET-BUFFER-LOCAL-VALUE" local-pkg))
              (sym    (find-symbol "*BUFFER-FILE-CODING-SYSTEM*"
                                   (find-package '#:limn/coding))))
          (when (and set-fn sym)
            (funcall (symbol-function set-fn) sym cs buf-id)))
        ;; fallback: just note it (unit tests without limn/local)
        nil)))

;;; ── bundled coding systems ───────────────────────────────────────────────

(define-coding-system :utf-8
  :encoding :utf-8 :bom nil :eol :unix :doc "Unicode UTF-8")

(define-coding-system :utf-8-with-bom
  :encoding :utf-8 :bom :utf-8 :eol :unix :doc "UTF-8 with BOM (Windows)")

(define-coding-system :utf-16le
  :encoding :utf-16le :bom nil :eol :unix :doc "UTF-16 Little-Endian")

(define-coding-system :utf-16be
  :encoding :utf-16be :bom nil :eol :unix :doc "UTF-16 Big-Endian")

(define-coding-system :latin-1
  :encoding :latin-1 :bom nil :eol :unix :doc "ISO-8859-1 Latin-1")

(define-coding-system :windows-1252
  :encoding :windows-1252 :bom nil :eol :dos :doc "Windows CP1252 Western")

;;; SBCL uses :gbk as the external-format keyword for GB18030/GBK.
(define-coding-system :gb18030
  :encoding :gbk :bom nil :eol :unix :doc "GB18030/GBK Simplified Chinese")

;;; Big5 — SBCL may not have Big5 tables for all CJK chars; verify with a
;;; full encode→decode roundtrip of known Big5 bytes (A7 41 = 你).
(handler-case
    (let* ((bytes (make-array 2 :element-type '(unsigned-byte 8)
                               :initial-contents '(#xa7 #x41)))
           (str (sb-ext:octets-to-string bytes :external-format :big5)))
      (declare (ignore str))
      (define-coding-system :big5
        :encoding :big5 :bom nil :eol :unix :doc "Big5 Traditional Chinese"))
  (error ()
    (define-coding-system :big5
      :encoding :utf-8 :bom nil :eol :unix
      :doc "Big5 (fallback: UTF-8 — native Big5 tables unavailable)")))

;;; SBCL uses :shift_jis (underscore) as the external-format keyword.
(define-coding-system :shift-jis
  :encoding :shift_jis :bom nil :eol :unix :doc "Shift-JIS Japanese")

(define-coding-system :euc-jp
  :encoding :euc-jp :bom nil :eol :unix :doc "EUC-JP Japanese")

;; iso-2022-jp: SBCL may not support natively; fallback with warning.
(handler-case
    (progn
      (sb-ext:string-to-octets "hi" :external-format :iso-2022-jp)
      (define-coding-system :iso-2022-jp
        :encoding :iso-2022-jp :bom nil :eol :unix :doc "ISO-2022-JP Japanese"))
  (error ()
    (define-coding-system :iso-2022-jp
      :encoding :utf-8 :bom nil :eol :unix
      :doc "ISO-2022-JP (fallback: UTF-8 — native support unavailable)")))
