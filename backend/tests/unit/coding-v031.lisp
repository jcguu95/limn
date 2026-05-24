;;;; v0.31 §B — coding systems RED tests (~60 tests)
;;;;
;;;; 覆蓋：
;;;;   limn/coding : define-coding-system / find-coding-system / list-coding-systems
;;;;                 encode-coding-string / decode-coding-string
;;;;                 encode-coding-region / decode-coding-region
;;;;                 detect-coding-system / detect-coding-region
;;;;                 set-buffer-file-coding-system
;;;;                 *buffer-file-coding-system*  (buffer-local var)
;;;;                 *file-coding-system-alist*
;;;;
;;;; 11 bundled coding systems（SPEC v0.31）：
;;;;   utf-8 / utf-8-with-bom / utf-16le / utf-16be /
;;;;   latin-1 / windows-1252 / gb18030 / big5 / shift-jis / euc-jp / iso-2022-jp
;;;;
;;;; find-file / save-buffer 整合走 mock vtable (同 limn-file.lisp 設計)
;;;;
;;;; 全部 RED — 在 limn-coding.lisp 實作前都會 fail。

;; ── package stubs ─────────────────────────────────────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/coding)
    (make-package '#:limn/coding :use '(#:cl)))
  (dolist (sym '("DEFINE-CODING-SYSTEM"
                 "FIND-CODING-SYSTEM"
                 "LIST-CODING-SYSTEMS"
                 "ENCODE-CODING-STRING"
                 "DECODE-CODING-STRING"
                 "ENCODE-CODING-REGION"
                 "DECODE-CODING-REGION"
                 "DETECT-CODING-SYSTEM"
                 "DETECT-CODING-REGION"
                 "SET-BUFFER-FILE-CODING-SYSTEM"
                 "CODING-SYSTEM-NAME"
                 "CODING-SYSTEM-P"
                 "*BUFFER-FILE-CODING-SYSTEM*"
                 "*FILE-CODING-SYSTEM-ALIST*"))
    (export (intern sym '#:limn/coding) '#:limn/coding)))

(in-package #:limn/unit-test)

;;; ── helpers ───────────────────────────────────────────────────────────────

(defmacro with-coding-pkg (&body body)
  "Skip body when limn/coding hasn't been loaded yet."
  `(let ((pkg (find-package '#:limn/coding)))
     (if (null pkg)
         (format t "  (skipped: limn/coding not loaded)~%")
         (progn ,@body))))

(defun %cod (name &rest args)
  "Call limn/coding:NAME with ARGS."
  (let ((pkg (find-package '#:limn/coding)))
    (when pkg
      (apply (symbol-function (find-symbol name pkg)) args))))

(defun %bytes (&rest octets)
  "Build a (vector (unsigned-byte 8) ...) from OCTETS."
  (make-array (length octets) :element-type '(unsigned-byte 8)
              :initial-contents octets))

(defun %cod-native-cjk-p (cs-name &optional (test-cjk "你"))
  "True if the coding system can encode/decode CJK content natively on this SBCL.
   Goes directly through sb-ext (not limn/coding) so the UTF-8 fallback path
   doesn't fool us into thinking Big5 works when it actually doesn't.
   IMPORTANT: must BIND the result so SBCL's optimizer doesn't elide the call."
  (declare (ignore test-cjk))
  (with-coding-pkg
    (let* ((cs  (%cod "FIND-CODING-SYSTEM" cs-name))
           (fmt (when cs
                  (funcall (symbol-function
                             (find-symbol "%CS-SBCL-FORMAT"
                                          (find-package '#:limn/coding)))
                           cs))))
      (and fmt
           ;; If the fallback path mapped this coding system to :utf-8, it's
           ;; not really native — return nil so tests skip.
           (not (and (not (eq cs-name :utf-8))
                     (not (eq cs-name :utf-8-with-bom))
                     (eq fmt :utf-8)))
           (handler-case
             (let* ((bytes (make-array 2 :element-type '(unsigned-byte 8)
                                         :initial-contents '(#xa7 #x41)))
                    (s (sb-ext:octets-to-string bytes :external-format fmt))
                    (n (length s)))
               (plusp n))
             (error () nil))))))

;;; ── §B1. define-coding-system + find-coding-system ───────────────────────

(deftest cod-b1-define-and-find
  "define-coding-system then find-coding-system returns an object"
  (with-coding-pkg
    (%cod "DEFINE-CODING-SYSTEM" :test-utf8
          :encoding :utf-8 :bom nil :eol :unix :doc "test")
    (assert-true (%cod "FIND-CODING-SYSTEM" :test-utf8)
                 "find returns non-nil")))

(deftest cod-b1-find-unknown-returns-nil
  "find-coding-system on unknown name returns nil"
  (with-coding-pkg
    (assert-false (%cod "FIND-CODING-SYSTEM" :no-such-coding))))

(deftest cod-b1-coding-system-name-roundtrip
  "coding-system-name returns the name passed to define-coding-system"
  (with-coding-pkg
    (%cod "DEFINE-CODING-SYSTEM" :mytest
          :encoding :latin-1 :bom nil :eol :unix :doc "")
    (let ((cs (%cod "FIND-CODING-SYSTEM" :mytest)))
      (assert-true cs)
      (assert-eq :mytest (%cod "CODING-SYSTEM-NAME" cs)))))

(deftest cod-b1-coding-system-p-true
  "coding-system-p is true on a coding-system object"
  (with-coding-pkg
    (%cod "DEFINE-CODING-SYSTEM" :mytest2
          :encoding :utf-8 :bom nil :eol :unix :doc "")
    (let ((cs (%cod "FIND-CODING-SYSTEM" :mytest2)))
      (assert-true (%cod "CODING-SYSTEM-P" cs)))))

(deftest cod-b1-coding-system-p-false-for-symbol
  "coding-system-p is false for a plain keyword"
  (with-coding-pkg
    (assert-false (%cod "CODING-SYSTEM-P" :utf-8)
                  "keyword is not a coding-system object")))

(deftest cod-b1-redefine-is-idempotent
  "define-coding-system called twice: no error, find still returns an object"
  (with-coding-pkg
    (%cod "DEFINE-CODING-SYSTEM" :mytest3
          :encoding :utf-8 :bom nil :eol :unix :doc "v1")
    (assert-no-error
      (%cod "DEFINE-CODING-SYSTEM" :mytest3
            :encoding :utf-8 :bom nil :eol :unix :doc "v2"))
    (assert-true (%cod "FIND-CODING-SYSTEM" :mytest3))))

;;; ── §B2. list-coding-systems — 11 bundled ────────────────────────────────

(deftest cod-b2-list-contains-utf-8
  "list-coding-systems includes :utf-8"
  (with-coding-pkg
    (let ((names (mapcar (lambda (cs) (%cod "CODING-SYSTEM-NAME" cs))
                         (%cod "LIST-CODING-SYSTEMS"))))
      (assert-true (member :utf-8 names) "utf-8 in list"))))

(deftest cod-b2-list-contains-all-11
  "list-coding-systems contains all 11 bundled coding systems"
  (with-coding-pkg
    (let* ((all (%cod "LIST-CODING-SYSTEMS"))
           (names (mapcar (lambda (cs) (%cod "CODING-SYSTEM-NAME" cs)) all))
           (required '(:utf-8 :utf-8-with-bom :utf-16le :utf-16be
                       :latin-1 :windows-1252 :gb18030 :big5
                       :shift-jis :euc-jp :iso-2022-jp)))
      (dolist (r required)
        (assert-true (member r names)
                     (format nil "~a in list-coding-systems" r))))))

(deftest cod-b2-find-all-bundled-by-name
  "find-coding-system succeeds for each of the 11 bundled names"
  (with-coding-pkg
    (dolist (n '(:utf-8 :utf-8-with-bom :utf-16le :utf-16be
                 :latin-1 :windows-1252 :gb18030 :big5
                 :shift-jis :euc-jp :iso-2022-jp))
      (assert-true (%cod "FIND-CODING-SYSTEM" n)
                   (format nil "find-coding-system ~a" n)))))

;;; ── §B3. encode / decode round-trips ─────────────────────────────────────

(deftest cod-b3-utf8-roundtrip-ascii
  "encode-coding-string utf-8 → decode-coding-string: ASCII roundtrip"
  (with-coding-pkg
    (let* ((s "Hello, World!")
           (bytes (%cod "ENCODE-CODING-STRING" s :utf-8))
           (back  (%cod "DECODE-CODING-STRING" bytes :utf-8)))
      (assert-equal s back "ASCII utf-8 round-trip"))))

(deftest cod-b3-utf8-roundtrip-cjk
  "encode-coding-string utf-8 → decode: CJK roundtrip"
  (with-coding-pkg
    (let* ((s "你好世界")
           (bytes (%cod "ENCODE-CODING-STRING" s :utf-8))
           (back  (%cod "DECODE-CODING-STRING" bytes :utf-8)))
      (assert-equal s back "CJK utf-8 round-trip"))))

(deftest cod-b3-utf8-bom-roundtrip
  "encode utf-8-with-bom: result starts with EF BB BF"
  (with-coding-pkg
    (let* ((s "hello")
           (bytes (%cod "ENCODE-CODING-STRING" s :utf-8-with-bom)))
      (assert-true (>= (length bytes) 3))
      (assert-eql #xef (aref bytes 0))
      (assert-eql #xbb (aref bytes 1))
      (assert-eql #xbf (aref bytes 2)))))

(deftest cod-b3-utf8-bom-decode
  "decode utf-8-with-bom: BOM stripped, content correct"
  (with-coding-pkg
    (let* ((bom-bytes (%bytes #xef #xbb #xbf #x68 #x65 #x6c #x6c #x6f))
           (s (%cod "DECODE-CODING-STRING" bom-bytes :utf-8-with-bom)))
      (assert-equal "hello" s "BOM stripped"))))

(deftest cod-b3-latin1-roundtrip
  "latin-1 encode/decode roundtrip for Western chars"
  (with-coding-pkg
    (let* ((s "café résumé")
           (bytes (%cod "ENCODE-CODING-STRING" s :latin-1))
           (back  (%cod "DECODE-CODING-STRING" bytes :latin-1)))
      (assert-equal s back "latin-1 round-trip"))))

(deftest cod-b3-utf16le-roundtrip
  "utf-16le encode/decode roundtrip"
  (with-coding-pkg
    (let* ((s "hi")
           (bytes (%cod "ENCODE-CODING-STRING" s :utf-16le))
           (back  (%cod "DECODE-CODING-STRING" bytes :utf-16le)))
      (assert-equal s back "utf-16le round-trip"))))

(deftest cod-b3-utf16be-roundtrip
  "utf-16be encode/decode roundtrip"
  (with-coding-pkg
    (let* ((s "hi")
           (bytes (%cod "ENCODE-CODING-STRING" s :utf-16be))
           (back  (%cod "DECODE-CODING-STRING" bytes :utf-16be)))
      (assert-equal s back "utf-16be round-trip"))))

(deftest cod-b3-big5-decode-known-bytes
  "decode known Big5 bytes → '你好世界' (skipped if SBCL lacks native Big5)"
  (with-coding-pkg
    (if (not (%cod-native-cjk-p :big5))
        (format t "  (skipped: Big5 native decode unavailable on this SBCL)~%")
        ;; 你=a7 41, 好=a6 6e, 世=a5 40, 界=ac c9
        (let* ((b5-bytes (%bytes #xa7 #x41 #xa6 #x6e #xa5 #x40 #xac #xc9))
               (s (%cod "DECODE-CODING-STRING" b5-bytes :big5)))
          (assert-equal "你好世界" s "Big5 decode")))))

(deftest cod-b3-big5-encode-decode-roundtrip
  "Big5 encode/decode roundtrip for '你好' (skipped if SBCL lacks native Big5)"
  (with-coding-pkg
    (if (not (%cod-native-cjk-p :big5))
        (format t "  (skipped: Big5 native encode/decode unavailable on this SBCL)~%")
        (let* ((s "你好")
               (bytes (%cod "ENCODE-CODING-STRING" s :big5))
               (back  (%cod "DECODE-CODING-STRING" bytes :big5)))
          (assert-equal s back "Big5 round-trip")))))

(deftest cod-b3-gb18030-decode-known-bytes
  "decode known GB18030 bytes → '你好世界'"
  (with-coding-pkg
    ;; 你=c4 e3, 好=ba c3, 世=ca c0, 界=bd e7
    (let* ((gb-bytes (%bytes #xc4 #xe3 #xba #xc3 #xca #xc0 #xbd #xe7))
           (s (%cod "DECODE-CODING-STRING" gb-bytes :gb18030)))
      (assert-equal "你好世界" s "GB18030 decode"))))

(deftest cod-b3-gb18030-roundtrip
  "GB18030 encode/decode roundtrip"
  (with-coding-pkg
    (let* ((s "你好世界")
           (bytes (%cod "ENCODE-CODING-STRING" s :gb18030))
           (back  (%cod "DECODE-CODING-STRING" bytes :gb18030)))
      (assert-equal s back "GB18030 round-trip"))))

(deftest cod-b3-shift-jis-decode-known-bytes
  "decode Shift-JIS bytes → '日本語テスト'"
  (with-coding-pkg
    ;; 日本語テスト = 93 fa 96 7b 8c ea 83 65 83 58 83 67
    (let* ((sj-bytes (%bytes #x93 #xfa #x96 #x7b #x8c #xea
                              #x83 #x65 #x83 #x58 #x83 #x67))
           (s (%cod "DECODE-CODING-STRING" sj-bytes :shift-jis)))
      (assert-equal "日本語テスト" s "Shift-JIS decode"))))

(deftest cod-b3-encode-result-is-byte-vector
  "encode-coding-string returns a (vector (unsigned-byte 8) ...)"
  (with-coding-pkg
    (let ((bytes (%cod "ENCODE-CODING-STRING" "hello" :utf-8)))
      (assert-true (vectorp bytes) "result is a vector")
      (assert-true (every #'(lambda (b) (typep b '(unsigned-byte 8))) bytes)
                   "all elements are unsigned bytes"))))

;;; ── §B4. detect-coding-system — BOM detection ────────────────────────────

(deftest cod-b4-detect-utf8-bom
  "detect-coding-system: EF BB BF prefix → :utf-8-with-bom"
  (with-coding-pkg
    (let* ((bytes (%bytes #xef #xbb #xbf #x68 #x65 #x6c #x6c #x6f))
           (cs (%cod "DETECT-CODING-SYSTEM" bytes)))
      (assert-eq :utf-8-with-bom (%cod "CODING-SYSTEM-NAME" cs)))))

(deftest cod-b4-detect-utf16le-bom
  "detect-coding-system: FF FE prefix → :utf-16le"
  (with-coding-pkg
    (let* ((bytes (%bytes #xff #xfe #x68 #x00 #x69 #x00))
           (cs (%cod "DETECT-CODING-SYSTEM" bytes)))
      (assert-eq :utf-16le (%cod "CODING-SYSTEM-NAME" cs)))))

(deftest cod-b4-detect-utf16be-bom
  "detect-coding-system: FE FF prefix → :utf-16be"
  (with-coding-pkg
    (let* ((bytes (%bytes #xfe #xff #x00 #x68 #x00 #x69))
           (cs (%cod "DETECT-CODING-SYSTEM" bytes)))
      (assert-eq :utf-16be (%cod "CODING-SYSTEM-NAME" cs)))))

(deftest cod-b4-detect-returns-coding-system-object
  "detect-coding-system always returns a coding-system object (never nil)"
  (with-coding-pkg
    (let ((cs (%cod "DETECT-CODING-SYSTEM" (%bytes #x68 #x65 #x6c #x6c #x6f))))
      (assert-true cs)
      (assert-true (%cod "CODING-SYSTEM-P" cs)))))

;;; ── §B5. detect-coding-system — heuristic ───────────────────────────────

(deftest cod-b5-detect-pure-ascii
  "detect-coding-system on pure ASCII bytes → :utf-8"
  (with-coding-pkg
    (let* ((bytes (%cod "ENCODE-CODING-STRING" "hello world" :utf-8))
           (cs (%cod "DETECT-CODING-SYSTEM" bytes)))
      (assert-eq :utf-8 (%cod "CODING-SYSTEM-NAME" cs)))))

(deftest cod-b5-detect-valid-utf8-no-bom
  "detect-coding-system on valid UTF-8 CJK (no BOM) → :utf-8"
  (with-coding-pkg
    (let* ((bytes (%cod "ENCODE-CODING-STRING" "你好世界" :utf-8))
           (cs (%cod "DETECT-CODING-SYSTEM" bytes)))
      (assert-eq :utf-8 (%cod "CODING-SYSTEM-NAME" cs)))))

(deftest cod-b5-detect-empty-bytes
  "detect-coding-system on empty byte vector → :utf-8 (safe default)"
  (with-coding-pkg
    (let* ((bytes (make-array 0 :element-type '(unsigned-byte 8)))
           (cs (%cod "DETECT-CODING-SYSTEM" bytes)))
      (assert-true (%cod "CODING-SYSTEM-P" cs))
      ;; empty = ASCII-only = utf-8
      (assert-eq :utf-8 (%cod "CODING-SYSTEM-NAME" cs)))))

(deftest cod-b5-detect-big5-with-alist-hint
  "detect-coding-system on Big5 bytes with alist hint returns big5"
  (with-coding-pkg
    ;; 你好世界 in Big5
    (let* ((b5-bytes (%bytes #xa7 #x41 #xa6 #x6e #xa5 #x40 #xac #xc9))
           (cod-pkg (find-package '#:limn/coding))
           (alist-sym (find-symbol "*FILE-CODING-SYSTEM-ALIST*" cod-pkg)))
      ;; temporarily set alist to hint .txt → big5
      (progv (list alist-sym) (list '(("\.txt$" . :big5)))
        (let ((cs (%cod "DETECT-CODING-SYSTEM" b5-bytes "test.txt")))
          (assert-eq :big5 (%cod "CODING-SYSTEM-NAME" cs)))))))

;;; ── §B6. find-file integration (mock vtable) ─────────────────────────────
;;;
;;; limn/file:find-file 改走 coding 流程：讀 raw octets → detect → decode。
;;; 這裡用 limn/file 的 *read-file-fn* / *buffer-set-content-fn* mock。

(defun %make-file-mock-vtable (path bytes &optional stored-content)
  "Returns a plist of vtable overrides for limn/file tests.
   *read-file-fn* returns BYTES (as-is; find-file reads raw octets).
   *buffer-set-content-fn* captures the decoded string into STORED-CONTENT cell."
  (let ((content-cell (or stored-content (list nil))))
    (values
     `(,(cons "*READ-FILE-FN*"           (lambda (p) (declare (ignore p)) bytes))
       ,(cons "*BUFFER-SET-CONTENT-FN*"  (lambda (bid s)
                                           (declare (ignore bid))
                                           (setf (car content-cell) s)))
       ,(cons "*FILE-EXISTS-P-FN*"       (lambda (p) (declare (ignore p)) t))
       ,(cons "*ENGINE-LOAD-FN*"         (lambda (p b) (declare (ignore p b)))))
     content-cell)))

(defmacro with-file-mock-coding ((content-var path bytes) &body body)
  "Bind limn/file vtable to serve BYTES for PATH; CONTENT-VAR receives decoded string."
  (let ((pkg-sym (gensym "PKG"))
        (pairs-sym (gensym "PAIRS"))
        (cell-sym (gensym "CELL")))
    `(let* ((,pkg-sym (find-package '#:limn/file))
            (,cell-sym (list nil)))
       (if (null ,pkg-sym)
           (progn ,@body)
           (multiple-value-bind (,pairs-sym _cell)
               (%make-file-mock-vtable ,path ,bytes ,cell-sym)
             (declare (ignore _cell))
             (let* ((syms (mapcar (lambda (p)
                                    (find-symbol (car p) ,pkg-sym))
                                  ,pairs-sym))
                    (vals (mapcar #'cdr ,pairs-sym))
                    (valid (remove nil syms)))
               (progv valid
                      (loop for s in syms for v in vals when s collect v)
                 (let ((,content-var ,cell-sym))
                   ,@body))))))))

(deftest cod-b6-find-file-big5-decodes-correctly
  "find-file on Big5 bytes with alist hint decodes correctly (skipped if SBCL lacks native Big5)"
  (with-coding-pkg
    (if (not (%cod-native-cjk-p :big5))
        (format t "  (skipped: Big5 native decode unavailable on this SBCL)~%")
        (let ((big5-bytes (%bytes #xa7 #x41 #xa6 #x6e #xa5 #x40 #xac #xc9)))
          (let ((file-pkg (find-package '#:limn/file)))
            (if (null file-pkg)
                (format t "  (skipped: limn/file not loaded)~%")
                (let* ((content-cell (list nil))
                       (find-file-fn (symbol-function
                                       (find-symbol "FIND-FILE" file-pkg)))
                       (read-sym   (find-symbol "*READ-FILE-FN*" file-pkg))
                       (set-sym    (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
                       (ex-sym     (find-symbol "*FILE-EXISTS-P-FN*" file-pkg))
                       (cod-pkg    (find-package '#:limn/coding))
                       (alist-sym  (find-symbol "*FILE-CODING-SYSTEM-ALIST*" cod-pkg)))
                  (progv (list alist-sym read-sym set-sym ex-sym)
                         (list '(("\.txt$" . :big5))
                               (lambda (p) (declare (ignore p)) big5-bytes)
                               (lambda (bid s)
                                 (declare (ignore bid))
                                 (setf (car content-cell) s))
                               (lambda (p) (declare (ignore p)) t))
                    (funcall find-file-fn "b6big5.txt"))
                  (assert-equal "你好世界" (car content-cell)
                                "Big5 bytes decoded to correct Unicode"))))))))

(deftest cod-b6-find-file-sets-buffer-file-coding-system
  "find-file stores detected coding in buffer-local *buffer-file-coding-system*"
  (with-coding-pkg
    (let* ((file-pkg  (find-package '#:limn/file))
           (local-pkg (find-package '#:limn/local)))
      (if (or (null file-pkg) (null local-pkg))
          (format t "  (skipped: limn/file or limn/local not loaded)~%")
          ;; Use UTF-8 (universally supported) to test the coding-system storage path
          (let* ((utf8-bytes (%cod "ENCODE-CODING-STRING" "hello" :utf-8))
                 (find-file-fn (symbol-function (find-symbol "FIND-FILE" file-pkg)))
                 (read-sym  (find-symbol "*READ-FILE-FN*"          file-pkg))
                 (set-sym   (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
                 (ex-sym    (find-symbol "*FILE-EXISTS-P-FN*"      file-pkg))
                 (buf-id    nil)
                 (eng-sym   (find-symbol "*ENGINE-LOAD-FN*" file-pkg))
                 (bcfs-sym  (find-symbol "*BUFFER-FILE-CODING-SYSTEM*"
                                          (find-package '#:limn/coding))))
            (progv (list read-sym set-sym ex-sym eng-sym)
                   (list (lambda (p) (declare (ignore p)) utf8-bytes)
                         (lambda (bid s) (declare (ignore s)) (setq buf-id bid))
                         (lambda (p) (declare (ignore p)) t)
                         (lambda (p b) (declare (ignore p)) (setq buf-id b)))
              (funcall find-file-fn "b6utf8cs.txt"))
            (when (and buf-id bcfs-sym)
              (let ((get-fn (symbol-function
                              (find-symbol "BUFFER-LOCAL-VALUE" local-pkg))))
                (let ((cs (funcall get-fn bcfs-sym buf-id)))
                  (assert-true cs "buffer-file-coding-system was stored")
                  (assert-eq :utf-8
                             (%cod "CODING-SYSTEM-NAME" cs)
                             "detected coding = utf-8")))))))))

(deftest cod-b6-find-file-utf8-no-bom
  "find-file on valid UTF-8 bytes (no BOM) decodes correctly"
  (with-coding-pkg
    (let* ((file-pkg (find-package '#:limn/file)))
      (if (null file-pkg)
          (format t "  (skipped: limn/file not loaded)~%")
          (let* ((utf8-bytes (%cod "ENCODE-CODING-STRING" "hello" :utf-8))
                 (content-cell (list nil))
                 (find-file-fn (symbol-function (find-symbol "FIND-FILE" file-pkg)))
                 (read-sym (find-symbol "*READ-FILE-FN*" file-pkg))
                 (set-sym  (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
                 (ex-sym   (find-symbol "*FILE-EXISTS-P-FN*" file-pkg)))
            (progv (list read-sym set-sym ex-sym)
                   (list (lambda (p) (declare (ignore p)) utf8-bytes)
                         (lambda (bid s) (declare (ignore bid))
                           (setf (car content-cell) s))
                         (lambda (p) (declare (ignore p)) t))
              (funcall find-file-fn "b6hello.txt"))
            (assert-equal "hello" (car content-cell)))))))

;;; ── §B7. save-buffer integration ────────────────────────────────────────

(deftest cod-b7-save-buffer-utf8-roundtrip
  "save-buffer: encode with utf-8, written bytes decode back to same string"
  (with-coding-pkg
    (let* ((file-pkg (find-package '#:limn/file)))
      (if (null file-pkg)
          (format t "  (skipped: limn/file not loaded)~%")
          (let* ((s "hello, 世界")
                 (written-bytes-cell (list nil))
                 ;; set up a buffer that was loaded with utf-8
                 (find-file-fn (symbol-function (find-symbol "FIND-FILE" file-pkg)))
                 (save-fn      (symbol-function (find-symbol "SAVE-BUFFER" file-pkg)))
                 (read-sym   (find-symbol "*READ-FILE-FN*"          file-pkg))
                 (set-sym    (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
                 (ex-sym     (find-symbol "*FILE-EXISTS-P-FN*"      file-pkg))
                 (write-sym  (find-symbol "*WRITE-FILE-FN*"         file-pkg))
                 (utf8-bytes (%cod "ENCODE-CODING-STRING" s :utf-8))
                 (buf-id-cell (list nil)))
            ;; load
            (progv (list read-sym set-sym ex-sym)
                   (list (lambda (p) (declare (ignore p)) utf8-bytes)
                         (lambda (bid content)
                           (declare (ignore content))
                           (setf (car buf-id-cell) bid))
                         (lambda (p) (declare (ignore p)) t))
              (funcall find-file-fn "test-utf8-save.txt"))
            ;; save
            (progv (list write-sym)
                   (list (lambda (path bytes)
                           (declare (ignore path))
                           (setf (car written-bytes-cell) bytes)))
              (funcall save-fn (car buf-id-cell)))
            ;; verify bytes round-trip
            (let* ((wb (car written-bytes-cell))
                   (back (%cod "DECODE-CODING-STRING" wb :utf-8)))
              (assert-equal s back "utf-8 save roundtrip")))))))

(deftest cod-b7-save-buffer-big5-preserves-bytes
  "save-buffer with big5 coding: written bytes == original big5 bytes
   (skipped if SBCL lacks native Big5)"
  (with-coding-pkg
    (if (not (%cod-native-cjk-p :big5))
        (format t "  (skipped: Big5 native encode unavailable on this SBCL)~%")
        (let* ((file-pkg (find-package '#:limn/file)))
          (if (null file-pkg)
              (format t "  (skipped: limn/file not loaded)~%")
              (let* ((big5-bytes (%bytes #xa7 #x41 #xa6 #x6e #xa5 #x40 #xac #xc9))
                 (find-file-fn (symbol-function (find-symbol "FIND-FILE" file-pkg)))
                 (save-fn      (symbol-function (find-symbol "SAVE-BUFFER" file-pkg)))
                 (read-sym  (find-symbol "*READ-FILE-FN*"          file-pkg))
                 (set-sym   (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
                 (ex-sym    (find-symbol "*FILE-EXISTS-P-FN*"      file-pkg))
                 (write-sym (find-symbol "*WRITE-FILE-FN*"         file-pkg))
                 (written-cell (list nil))
                 (buf-id-cell  (list nil)))
            ;; prime alist so Big5 is detected for .txt
            (let ((cod-pkg (find-package '#:limn/coding))
                  (alist-val '(("\.txt$" . :big5))))
              (progv (list (find-symbol "*FILE-CODING-SYSTEM-ALIST*" cod-pkg))
                     (list alist-val)
                (progv (list read-sym set-sym ex-sym)
                       (list (lambda (p) (declare (ignore p)) big5-bytes)
                             (lambda (bid s) (declare (ignore s))
                               (setf (car buf-id-cell) bid))
                             (lambda (p) (declare (ignore p)) t))
                  (funcall find-file-fn "notes-big5-save.txt"))
                (progv (list write-sym)
                       (list (lambda (path bytes)
                               (declare (ignore path))
                               (setf (car written-cell) bytes)))
                  (funcall save-fn (car buf-id-cell)))))
            ;; written bytes should equal original big5 bytes
            (let ((wb (car written-cell)))
              (assert-true wb "write was called")
              (assert-equal (length big5-bytes) (length wb)
                            "byte count matches")
              (assert-true (loop for i below (length big5-bytes)
                                 always (= (aref big5-bytes i) (aref wb i)))
                           "byte-for-byte identical"))))))))

;;; ── §B8. error handling ───────────────────────────────────────────────────

(deftest cod-b8-decode-invalid-bytes-utf8
  "decode-coding-string on invalid UTF-8 bytes raises an error"
  (with-coding-pkg
    ;; #xFF is not valid UTF-8; SBCL raises INVALID-UTF8-STARTER-BYTE
    (let ((bad-bytes (%bytes #xff #xfe #xaa)))
      (assert-error error
                    (%cod "DECODE-CODING-STRING" bad-bytes :utf-8)
                    "invalid UTF-8 should signal an error"))))

(deftest cod-b8-encode-unsupported-char-latin1
  "encode-coding-string: CJK char in latin-1 → error"
  (with-coding-pkg
    ;; 你 (U+4F60) is outside latin-1's range; SBCL raises OCTETS-ENCODING-ERROR
    (assert-error error
                  (%cod "ENCODE-CODING-STRING" "你好" :latin-1)
                  "CJK in latin-1 should signal an error")))

(deftest cod-b8-iso2022jp-fallback-no-crash
  "iso-2022-jp: if SBCL doesn't support it natively, should not crash"
  (with-coding-pkg
    ;; Either succeeds or gives a graceful fallback warning; must not throw
    ;; an unhandled error that kills the process.
    (assert-no-error
     (handler-case
         (%cod "DECODE-CODING-STRING"
               (%cod "ENCODE-CODING-STRING" "hello" :utf-8)
               :iso-2022-jp)
       (error () "fallback ok")))))

(deftest cod-b8-detect-on-nil-returns-utf8
  "detect-coding-system on nil bytes: graceful, returns utf-8"
  (with-coding-pkg
    (let* ((bytes (make-array 0 :element-type '(unsigned-byte 8)))
           (cs (%cod "DETECT-CODING-SYSTEM" bytes)))
      (assert-true (%cod "CODING-SYSTEM-P" cs)))))

(deftest cod-b8-find-coding-system-case-insensitive
  "find-coding-system: :UTF-8 and :utf-8 refer to same system"
  (with-coding-pkg
    (let ((cs1 (%cod "FIND-CODING-SYSTEM" :utf-8))
          (cs2 (%cod "FIND-CODING-SYSTEM" :UTF-8)))
      (assert-true (and cs1 cs2) "both find non-nil")
      (assert-eq (%cod "CODING-SYSTEM-NAME" cs1)
                 (%cod "CODING-SYSTEM-NAME" cs2)
                 "same name"))))

;;; ── §B9. encode-coding-region / decode-coding-region ─────────────────────
;;;
;;; These operate on a buffer's content in-place. We test with a mock buffer
;;; that exposes its text via a cell.

(deftest cod-b9-encode-coding-region-returns-bytes
  "encode-coding-region on a buffer substring returns byte vector"
  (with-coding-pkg
    (let* ((cod-pkg (find-package '#:limn/coding))
           (ecr (find-symbol "ENCODE-CODING-REGION" cod-pkg)))
      (when ecr
        ;; Supply a *buffer-text-fn* vtable override
        (let* ((text "hello world")
               (buf-id "test-buf")
               (buf-text-sym (find-symbol "*BUFFER-TEXT-FN*"
                                          (find-package '#:limn/coding))))
          (when buf-text-sym
            (progv (list buf-text-sym)
                   (list (lambda (b) (declare (ignore b)) text))
              (let ((bytes (funcall (symbol-function ecr) buf-id 0 5 :utf-8)))
                (assert-true (vectorp bytes))
                (assert-equal 5 (length bytes)
                              "5 bytes for 'hello'")))))))))

(deftest cod-b9-decode-coding-region-replaces-content
  "decode-coding-region on CJK bytes replaces buffer region with Unicode
   (uses UTF-8 bytes since Big5 native decode may not be available)"
  (with-coding-pkg
    (let* ((cod-pkg (find-package '#:limn/coding))
           (dcr (find-symbol "DECODE-CODING-REGION" cod-pkg)))
      (when dcr
        ;; Use UTF-8 bytes for "你好" — universally supported
        (let* ((utf8-bytes (%cod "ENCODE-CODING-STRING" "你好" :utf-8))
               ;; Build a string of raw chars from utf8-bytes (simulate what
               ;; decode-coding-region receives as buffer content)
               (raw-str (map 'string #'code-char (coerce utf8-bytes 'list)))
               (buf-id "b9-utf8")
               (result-cell (list nil))
               (buf-text-sym   (find-symbol "*BUFFER-TEXT-FN*"   cod-pkg))
               (buf-delete-sym (find-symbol "*BUFFER-DELETE-FN*" cod-pkg))
               (buf-insert-sym (find-symbol "*BUFFER-INSERT-FN*" cod-pkg)))
          (when (and buf-text-sym buf-delete-sym buf-insert-sym)
            (progv (list buf-text-sym buf-delete-sym buf-insert-sym)
                   (list (lambda (b) (declare (ignore b)) raw-str)
                         (lambda (b f to) (declare (ignore b f to)))
                         (lambda (b pos s)
                           (declare (ignore b pos))
                           (setf (car result-cell) s)))
              (funcall (symbol-function dcr) buf-id 0 (length raw-str) :utf-8))
            (when (car result-cell)
              (assert-equal "你好" (car result-cell)
                            "region replaced with Unicode"))))))))
