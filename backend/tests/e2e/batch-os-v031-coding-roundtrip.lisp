;;;; v0.31 §B OS-tier — coding systems end-to-end (Lisp-side)
;;;;
;;;; This driver validates that the v0.31 limn/coding + limn/file modules
;;;; load and operate correctly inside the production container (nix SBCL,
;;;; full Limn binary running). It exercises Lisp-side find-file → decode
;;;; → save-buffer round-trip against real fixture files.
;;;;
;;;; NOTE on scope: as of v0.31, the production "find-file" command routes
;;;; through C++ `buffer/load-file` (which doesn't go through limn/coding).
;;;; Wiring limn/coding into the bridge file-load path is v0.32 work. So
;;;; this driver tests the Lisp-side path that v0.31 actually delivers.
;;;;
;;;; Fixtures (built into the container):
;;;;   backend/tests/fixtures/big5.txt      — "你好世界\n" in Big5
;;;;   backend/tests/fixtures/gb18030.txt   — "你好世界\n" in GB18030
;;;;   backend/tests/fixtures/sjis.txt      — "日本語テスト\n" in Shift-JIS
;;;;
;;;; Ω1: Big5 round-trip (skipped if SBCL lacks native Big5)
;;;; Ω2: GB18030 round-trip (works on Linux SBCL — :gbk format)
;;;; Ω3: Shift-JIS round-trip (works on Linux SBCL — :shift_jis format)

(in-package :cl-user)
(require :sb-posix)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))

(defun b/ (f) (concatenate 'string *bdir* f))

(defun fixture-path (name)
  (concatenate 'string *bdir* "tests/fixtures/" name))

;; ── load v0.31 backend modules ───────────────────────────────────────────

(dolist (f '("limn-hooks.lisp"
             "limn-log.lisp"
             "limn-error.lisp"
             "limn-marker.lisp"
             "limn-local.lisp"
             "limn-text-nav.lisp"
             "limn-syntax.lisp"
             "limn-coding.lisp"
             "limn-file.lisp"))
  (handler-case (load (b/ f))
    (error (e) (format t "  !! skipped ~A: ~A~%" f e))))

;; ── test harness ─────────────────────────────────────────────────────────

(defparameter *failures* nil)

(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details)
    (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun read-file-bytes (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence buf s)
      buf)))

(defun coding-native? (fmt &optional (fixture "big5.txt"))
  "Return T if SBCL can decode FIXTURE's bytes under FMT (i.e., the format
   is registered AND the bytes are valid for it).
   IMPORTANT: must BIND the decoded result so SBCL's optimizer doesn't
   elide the octets-to-string call (it treats it as pure)."
  (handler-case
      (let* ((bs (read-file-bytes (fixture-path fixture)))
             (str (sb-ext:octets-to-string bs :external-format fmt))
             (n (length str)))
        (plusp n))
    (error () nil)))

(defun lisp-find-file (path)
  "Call limn/file:find-file and capture the decoded content via the
   *buffer-set-content-fn* vtable. Returns (values buf-id decoded-text)."
  (let* ((file-pkg (find-package '#:limn/file))
         (find-fn  (symbol-function (find-symbol "FIND-FILE" file-pkg)))
         (cont-sym (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
         (got      (list nil)))
    (progv (list cont-sym)
           (list (lambda (bid s) (declare (ignore bid)) (setf (car got) s)))
      (values (funcall find-fn path) (car got)))))

(defun lisp-save-buffer-bytes (buf-id)
  "Call limn/file:save-buffer on BUF-ID, capture and return the bytes
   that *write-file-fn* received."
  (let* ((file-pkg  (find-package '#:limn/file))
         (save-fn   (symbol-function (find-symbol "SAVE-BUFFER" file-pkg)))
         (write-sym (find-symbol "*WRITE-FILE-FN*" file-pkg))
         (got       (list nil)))
    (progv (list write-sym)
           (list (lambda (path bytes)
                   (declare (ignore path))
                   (setf (car got) bytes)))
      (funcall save-fn buf-id))
    (car got)))

(defun prime-alist (entries)
  "Bind limn/coding:*file-coding-system-alist* to ENTRIES for the dynamic
   extent of the immediately-following form (used by the cases below)."
  (let* ((cod-pkg   (find-package '#:limn/coding))
         (alist-sym (find-symbol "*FILE-CODING-SYSTEM-ALIST*" cod-pkg)))
    (values alist-sym entries)))

;; ── Ω1. Big5 round-trip ──────────────────────────────────────────────────

(format t "~%--- Ω1: Big5 find-file + save-buffer round-trip ---~%")
(cond
  ((not (probe-file (fixture-path "big5.txt")))
   (format t "  SKIP: fixture big5.txt not found~%"))
  ((not (coding-native? :big5))
   (format t "  SKIP: SBCL on this platform lacks native Big5 support~%"))
  (t
   (handler-case
       (multiple-value-bind (sym val) (prime-alist '(("\.txt$" . :big5)))
         (progv (list sym) (list val)
           (multiple-value-bind (bid decoded)
               (lisp-find-file (fixture-path "big5.txt"))
             (check "Ω1 find-file returned buffer-id" (stringp bid))
             (check "Ω1 decoded text starts with '你好世界'"
                    (and decoded (>= (length decoded) 4)
                         (string= "你好世界" (subseq decoded 0 4)))
                    (format nil "got: ~s" decoded))
             ;; Round-trip: save and compare with original
             (let ((orig (read-file-bytes (fixture-path "big5.txt")))
                   (saved (lisp-save-buffer-bytes bid)))
               (check "Ω1 save-buffer produced bytes" (not (null saved)))
               (when saved
                 (check "Ω1 round-trip byte-for-byte"
                        (and (= (length orig) (length saved))
                             (loop for i below (length orig)
                                   always (= (aref orig i) (aref saved i))))
                        (format nil "orig=~a saved=~a"
                                (length orig) (length saved))))))))
     (error (e)
       (check "Ω1 no unhandled error" nil (format nil "~A" e))))))

;; ── Ω2. GB18030 decode + content check ───────────────────────────────────

(format t "~%--- Ω2: GB18030 find-file ---~%")
(cond
  ((not (probe-file (fixture-path "gb18030.txt")))
   (format t "  SKIP: fixture gb18030.txt not found~%"))
  ((not (coding-native? :gbk "gb18030.txt"))
   (format t "  SKIP: SBCL on this platform lacks :gbk support~%"))
  (t
   (handler-case
       (multiple-value-bind (sym val) (prime-alist '(("\.txt$" . :gb18030)))
         (progv (list sym) (list val)
           (multiple-value-bind (bid decoded)
               (lisp-find-file (fixture-path "gb18030.txt"))
             (check "Ω2 find-file returned buffer-id" (stringp bid))
             (check "Ω2 decoded text starts with '你好世界'"
                    (and decoded (>= (length decoded) 4)
                         (string= "你好世界" (subseq decoded 0 4)))
                    (format nil "got: ~s" decoded)))))
     (error (e)
       (check "Ω2 no unhandled error" nil (format nil "~A" e))))))

;; ── Ω3. Shift-JIS decode + content check ─────────────────────────────────

(format t "~%--- Ω3: Shift-JIS find-file ---~%")
(cond
  ((not (probe-file (fixture-path "sjis.txt")))
   (format t "  SKIP: fixture sjis.txt not found~%"))
  ((not (coding-native? :shift_jis "sjis.txt"))
   (format t "  SKIP: SBCL on this platform lacks :shift_jis support~%"))
  (t
   (handler-case
       (multiple-value-bind (sym val) (prime-alist '(("sjis\.txt$" . :shift-jis)))
         (progv (list sym) (list val)
           (multiple-value-bind (bid decoded)
               (lisp-find-file (fixture-path "sjis.txt"))
             (check "Ω3 find-file returned buffer-id" (stringp bid))
             (check "Ω3 decoded text starts with '日本語テスト'"
                    (and decoded (>= (length decoded) 6)
                         (string= "日本語テスト" (subseq decoded 0 6)))
                    (format nil "got: ~s" decoded)))))
     (error (e)
       (check "Ω3 no unhandled error" nil (format nil "~A" e))))))

;; ── summary ──────────────────────────────────────────────────────────────

(format t "~%=== v0.31 coding OS-tier: ~a failure(s) ===~%"
        (length *failures*))
(when *failures*
  (format t "Failed checks:~%")
  (dolist (f (reverse *failures*))
    (format t "  - ~a~%" f)))

(format t "VERDICT: ~a~%" (if *failures* "✗ FAIL" "✓ PASS"))
(sb-ext:exit :code (if *failures* 1 0))
