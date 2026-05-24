;;;; v0.31 §A+B — syntax tables + coding systems Qt-tier tests
;;;;
;;;; 走真實 limn binary（headless bridge），測三件事：
;;;;
;;;;   T1 coding: 開 Big5 fixture txt → buffer/text 內容正確（非亂碼）
;;;;              buffer-local *buffer-file-coding-system* 值 = big5
;;;;
;;;;   T2 syntax/nav: text buffer 載入 lisp-mode syntax table（'-' = :symbol）
;;;;                  → forward-word 把 "foo-bar" 當一個 word
;;;;                    cursor 從 0 跳到 7
;;;;
;;;;   T3 coding round-trip: save-buffer 後 written bytes 與原始 Big5 bytes 相同
;;;;
;;;; 依賴：
;;;;   - limn/syntax     (v0.31 §A)
;;;;   - limn/coding     (v0.31 §B)
;;;;   - limn/local      (v0.30 §B buffer-local vars)
;;;;   - limn/text-nav   (v0.28, updated for §A)
;;;;   - limn/file       (v0.24, updated for §B)

(in-package #:limn/test)

;; ── load backend modules in-process ──────────────────────────────────────
;;
;; Qt-tier framework handles the bridge wire; we also load Lisp modules
;; so we can call limn/syntax:char-syntax, limn/coding:find-coding-system,
;; and limn/local:buffer-local-value directly in assertions.

(let* ((suite-dir (make-pathname
                    :defaults (or *load-pathname*
                                  *default-pathname-defaults*)
                    :name nil :type nil))
       (backend-dir (merge-pathnames "../../" suite-dir)))
  (dolist (f '("limn-hooks.lisp"
               "limn-log.lisp"
               "limn-error.lisp"
               "limn-marker.lisp"
               "limn-local.lisp"
               "limn-mark.lisp"
               "limn-text-nav.lisp"
               "limn-syntax.lisp"   ; v0.31 §A
               "limn-coding.lisp"   ; v0.31 §B
               "limn-file.lisp"))
    (handler-case
        (load (merge-pathnames f backend-dir))
      (error (e)
        (format t "  !! skipped ~A: ~A~%" f e)))))

;; ── fixture helpers ───────────────────────────────────────────────────────

;; Resolve fixture dir at LOAD TIME (when *load-pathname* is bound to this
;; file).  At deftest run time *load-pathname* is NIL, so deferring this
;; computation would point at the wrong place.
(defparameter *v031-fixtures-dir*
  (let ((this-file (or *load-pathname*
                       *default-pathname-defaults*)))
    (namestring (merge-pathnames "../fixtures/"
                                  (make-pathname :defaults this-file
                                                 :name nil :type nil)))))

(defun %big5-fixture-path ()
  "Path to the Big5 test fixture in tests/fixtures/."
  (namestring (merge-pathnames "big5.txt" *v031-fixtures-dir*)))

(defun %lisp-syntax-table ()
  "Build a lisp-mode syntax table: '-' and '?' are :symbol."
  (when (find-package '#:limn/syntax)
    (let* ((syn-pkg (find-package '#:limn/syntax))
           (make-fn (symbol-function (find-symbol "MAKE-SYNTAX-TABLE" syn-pkg)))
           (mod-fn  (symbol-function (find-symbol "MODIFY-SYNTAX-ENTRY" syn-pkg)))
           (std     (symbol-value    (find-symbol "*STANDARD-SYNTAX-TABLE*" syn-pkg)))
           (t1 (funcall make-fn std)))
      (funcall mod-fn #\- :symbol t1)
      (funcall mod-fn #\? :symbol t1)
      t1)))

;; ── T1. Big5 file → correct buffer content ────────────────────────────────

(deftest v031-t1-big5-file-content
  "limn/file:find-file on Big5 fixture decodes to correct Unicode and
   stores :big5 in buffer-local *buffer-file-coding-system*.
   (Tests Lisp-side coding integration; bridge file-load on the C++ side
   does not currently route through limn/coding.)"
  (let ((fixture (%big5-fixture-path))
        (file-pkg (find-package '#:limn/file))
        (cod-pkg  (find-package '#:limn/coding))
        (local-pkg (find-package '#:limn/local)))
    (unless (probe-file fixture)
      (format t "  SKIP: fixture ~a not found~%" fixture)
      (return-from v031-t1-big5-file-content))
    (unless (and file-pkg cod-pkg local-pkg)
      (format t "  SKIP: limn/file or limn/coding or limn/local not loaded~%")
      (return-from v031-t1-big5-file-content))
    ;; Robust capability check: actually try to decode the fixture's full
    ;; byte sequence (some SBCL builds accept partial Big5 inputs but fail
    ;; on longer real-world content).
    ;; CRITICAL: bind octets-to-string's result so the optimizer can't
    ;; eliminate the call (it considers octets-to-string pure).
    (let* ((cod-native
            (handler-case
                (let* ((bs (with-open-file (s fixture :element-type '(unsigned-byte 8))
                             (let ((b (make-array (file-length s)
                                                   :element-type '(unsigned-byte 8))))
                               (read-sequence b s)
                               b)))
                       (str (sb-ext:octets-to-string bs :external-format :big5)))
                  (and str (plusp (length str))))
              (error () nil))))
      (unless cod-native
        (format t "  SKIP: SBCL on this platform lacks native Big5 decode~%")
        (return-from v031-t1-big5-file-content)))
    ;; prime alist hint so detect-coding-system picks :big5
    (let* ((alist-sym (find-symbol "*FILE-CODING-SYSTEM-ALIST*" cod-pkg))
           (find-fn   (symbol-function (find-symbol "FIND-FILE" file-pkg)))
           (cont-sym  (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
           (got-text  (list nil)))
      (progv (list alist-sym cont-sym)
             (list '(("\.txt$" . :big5))
                   (lambda (bid s) (declare (ignore bid))
                     (setf (car got-text) s)))
        (let ((bid (funcall find-fn fixture)))
          (assert-true bid "find-file returned a buffer id")
          (assert-true (car got-text) "buffer-set-content received decoded text")
          (let ((decoded (car got-text)))
            (assert-true
              (and decoded (>= (length decoded) 4)
                   (string= "你好世界" (subseq decoded 0 4)))
              (format nil "content starts with 你好世界; got: ~s" decoded)))
          ;; Buffer-local coding system was stored as :big5
          (let* ((bcfs-sym (find-symbol "*BUFFER-FILE-CODING-SYSTEM*" cod-pkg))
                 (get-fn   (symbol-function
                             (find-symbol "BUFFER-LOCAL-VALUE" local-pkg)))
                 (cs       (funcall get-fn bcfs-sym bid)))
            (assert-true cs "*buffer-file-coding-system* was stored")
            (assert-eq :big5
                       (funcall (symbol-function
                                  (find-symbol "CODING-SYSTEM-NAME" cod-pkg))
                                cs)
                       "buffer-file-coding-system = :big5")))))))

;; ── T2. forward-word in lisp-mode: "foo-bar" is one word ─────────────────

(deftest v031-t2-forward-word-lisp-syntax
  "lisp-mode syntax table: forward-word on 'foo-bar baz' from 0 → cursor = 7"
  (let* ((r0 (send! "bridge/engine-load"
                    :|win-id| "w1" :|engine| "text" :|path| ""))
         (bid (json-get* r0 :|data| :|buffer-id|)))
    (assert-ok r0 "engine-load ok")
    (drain-events)

    ;; Insert text
    (let ((r1 (send! "buffer/insert"
                     :|buffer-id| bid :|at| 0 :|text| "foo-bar baz")))
      (assert-ok r1 "insert ok"))
    (drain-events)

    ;; Set cursor to 0
    (let ((r2 (send! "buffer/cursor-set" :|buffer-id| bid :|offset| 0)))
      (assert-ok r2 "cursor-set ok"))

    ;; Wire the lisp syntax table + buffer vtable for this buffer
    ;; (the production text-nav vtable defaults are no-ops; we bridge
    ;;  them to the wire for the duration of this test).
    (let* ((lisp-table (%lisp-syntax-table))
           (nav-pkg    (find-package '#:limn/text-nav))
           (st-sym     (when nav-pkg (find-symbol "*SYNTAX-TABLE-FN*"        nav-pkg)))
           (text-sym   (when nav-pkg (find-symbol "*BUFFER-TEXT-FN*"         nav-pkg)))
           (cur-sym    (when nav-pkg (find-symbol "*BUFFER-CURSOR-FN*"       nav-pkg)))
           (scur-sym   (when nav-pkg (find-symbol "*BUFFER-SET-CURSOR-FN*"   nav-pkg))))
      (when (and lisp-table st-sym text-sym cur-sym scur-sym)
        (progv (list st-sym text-sym cur-sym scur-sym)
               (list (lambda (b) (declare (ignore b)) lisp-table)
                     (lambda (b)
                       (json-get* (send! "buffer/text" :|buffer-id| b)
                                  :|data| :|text|))
                     (lambda (b)
                       (json-get* (send! "buffer/cursor-get" :|buffer-id| b)
                                  :|data| :|offset|))
                     (lambda (b off)
                       (send! "buffer/cursor-set"
                              :|buffer-id| b :|offset| off)))
          ;; Call forward-word — now reads/writes via wire vtable.
          (let ((fw (find-symbol "FORWARD-WORD" nav-pkg)))
            (when fw
              (funcall (symbol-function fw) bid)))))

      ;; Read cursor back via wire
      (let* ((r3 (send! "buffer/cursor-get" :|buffer-id| bid))
             (pos (json-get* r3 :|data| :|offset|)))
        (assert-ok r3 "cursor-get ok")
        (assert-equal 7 pos
                      (format nil "lisp-mode: foo-bar is one word; cursor=~a" pos))))

    (ignore-errors (send! "buffer/close" :|buffer-id| bid))))

;; ── T3. save-buffer round-trip: bytes == original Big5 bytes ─────────────

(deftest v031-t3-save-buffer-big5-roundtrip
  "limn/file:find-file then save-buffer: written bytes byte-identical to original Big5.
   (Tests Lisp-side find-file → save-buffer round-trip with limn/coding.)"
  (let ((fixture (%big5-fixture-path))
        (file-pkg (find-package '#:limn/file))
        (cod-pkg  (find-package '#:limn/coding)))
    (unless (probe-file fixture)
      (format t "  SKIP: fixture ~a not found~%" fixture)
      (return-from v031-t3-save-buffer-big5-roundtrip))
    (unless (and file-pkg cod-pkg)
      (format t "  SKIP: limn/file or limn/coding not loaded~%")
      (return-from v031-t3-save-buffer-big5-roundtrip))
    ;; Capability check — CRITICAL: use the result so the optimizer can't
    ;; elide the call (SBCL treats octets-to-string as pure).
    (unless (handler-case
                (let* ((bs (with-open-file (s fixture :element-type '(unsigned-byte 8))
                             (let ((b (make-array (file-length s)
                                                    :element-type '(unsigned-byte 8))))
                               (read-sequence b s)
                               b)))
                       (decoded (sb-ext:octets-to-string bs :external-format :big5))
                       (encoded (sb-ext:string-to-octets decoded :external-format :big5)))
                  (and decoded encoded
                       (plusp (length decoded))
                       (plusp (length encoded))))
              (error () nil))
      (format t "  SKIP: SBCL on this platform lacks native Big5 round-trip~%")
      (return-from v031-t3-save-buffer-big5-roundtrip))

    (let* ((orig-bytes
              (with-open-file (s fixture :element-type '(unsigned-byte 8))
                (let ((buf (make-array (file-length s)
                                       :element-type '(unsigned-byte 8))))
                  (read-sequence buf s)
                  buf)))
           (alist-sym (find-symbol "*FILE-CODING-SYSTEM-ALIST*" cod-pkg))
           (find-fn   (symbol-function (find-symbol "FIND-FILE"    file-pkg)))
           (save-fn   (symbol-function (find-symbol "SAVE-BUFFER"  file-pkg)))
           (write-sym (find-symbol "*WRITE-FILE-FN*" file-pkg))
           (cont-sym  (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
           (written-cell (list nil)))
      (progv (list alist-sym cont-sym)
             (list '(("\.txt$" . :big5))
                   (lambda (bid s) (declare (ignore bid s)) nil))
        (let ((bid (funcall find-fn fixture)))
          (assert-true bid "find-file returned a buffer id")
          ;; Now save: capture bytes written by *write-file-fn*
          (progv (list write-sym)
                 (list (lambda (path bytes)
                         (declare (ignore path))
                         (setf (car written-cell) bytes)))
            (funcall save-fn bid))
          (let ((wb (car written-cell)))
            (assert-true wb "save-buffer called *write-file-fn*")
            (when wb
              (assert-equal (length orig-bytes) (length wb)
                            "byte count matches original")
              (assert-true
                (loop for i below (length orig-bytes)
                      always (= (aref orig-bytes i) (aref wb i)))
                "bytes byte-identical to original fixture"))))))))
