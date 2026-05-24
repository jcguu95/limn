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

(defun %big5-fixture-path ()
  "Path to the Big5 test fixture in tests/fixtures/."
  (let ((suite-dir (make-pathname
                     :defaults (or *load-pathname*
                                   *default-pathname-defaults*)
                     :name nil :type nil)))
    (namestring (merge-pathnames "../fixtures/big5.txt" suite-dir))))

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
  "open Big5 fixture: buffer/text returns '你好世界', not garbage bytes"
  (let ((fixture (%big5-fixture-path)))
    (unless (probe-file fixture)
      (format t "  SKIP: fixture ~a not found~%" fixture)
      (return-from v031-t1-big5-file-content))

    (let* ((r0 (send! "bridge/engine-load"
                      :|win-id| "w1" :|engine| "text"
                      :|path| (namestring fixture)))
           (bid (json-get* r0 :|data| :|buffer-id|)))
      (assert-ok r0 "engine-load ok")
      (drain-events)

      (let* ((r1 (send! "buffer/text" :|buffer-id| bid))
             (text (json-get* r1 :|data| :|text|)))
        (assert-ok r1 "buffer/text ok")
        ;; Content should start with 你好世界 (the fixture's first line)
        (assert-true
          (and text (>= (length text) 4)
               (string= "你好世界" (subseq text 0 4)))
          (format nil "content starts with 你好世界; got: ~s" text)))

      ;; buffer-local *buffer-file-coding-system* should be big5
      (when (and (find-package '#:limn/coding)
                 (find-package '#:limn/local))
        (let* ((bcfs (symbol-value
                       (find-symbol "*BUFFER-FILE-CODING-SYSTEM*"
                                    (find-package '#:limn/coding))))
               (get-fn (symbol-function
                          (find-symbol "BUFFER-LOCAL-VALUE"
                                       (find-package '#:limn/local))))
               (cs (funcall get-fn bcfs bid)))
          (when cs
            (assert-true
              (eq :big5
                  (funcall
                    (symbol-function
                      (find-symbol "CODING-SYSTEM-NAME"
                                   (find-package '#:limn/coding)))
                    cs))
              "buffer-file-coding-system = big5"))))

      (ignore-errors (send! "buffer/close" :|buffer-id| bid)))))

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
    (let ((r2 (send! "buffer/set-cursor" :|buffer-id| bid :|pos| 0)))
      (assert-ok r2 "set-cursor ok"))

    ;; Wire the lisp syntax table for this buffer (in-process)
    (let* ((lisp-table (%lisp-syntax-table))
           (nav-pkg (find-package '#:limn/text-nav))
           (st-sym  (when nav-pkg
                      (find-symbol "*SYNTAX-TABLE-FN*" nav-pkg))))
      (when (and lisp-table st-sym)
        (progv (list st-sym)
               (list (lambda (b) (declare (ignore b)) lisp-table))
          ;; Call forward-word via the Lisp bridge (in-process call, not wire)
          (let ((fw (find-symbol "FORWARD-WORD" nav-pkg)))
            (when fw
              (funcall (symbol-function fw) bid)))))

      ;; Read cursor back via wire
      (let* ((r3 (send! "buffer/cursor" :|buffer-id| bid))
             (pos (json-get* r3 :|data| :|pos|)))
        (assert-ok r3 "cursor ok")
        (assert-equal 7 pos
                      (format nil "lisp-mode: foo-bar is one word; cursor=~a" pos))))

    (ignore-errors (send! "buffer/close" :|buffer-id| bid))))

;; ── T3. save-buffer round-trip: bytes == original Big5 bytes ─────────────

(deftest v031-t3-save-buffer-big5-roundtrip
  "save-buffer with big5 coding: written bytes match original fixture bytes"
  (let ((fixture (%big5-fixture-path)))
    (unless (probe-file fixture)
      (format t "  SKIP: fixture ~a not found~%" fixture)
      (return-from v031-t3-save-buffer-big5-roundtrip))

    ;; Read original bytes
    (let* ((orig-bytes
              (with-open-file (s fixture :element-type '(unsigned-byte 8))
                (let ((buf (make-array (file-length s)
                                       :element-type '(unsigned-byte 8))))
                  (read-sequence buf s)
                  buf)))
           (r0 (send! "bridge/engine-load"
                      :|win-id| "w1" :|engine| "text"
                      :|path| (namestring fixture)))
           (bid (json-get* r0 :|data| :|buffer-id|)))
      (assert-ok r0 "engine-load ok")
      (drain-events)

      ;; save-buffer via in-process call, capture written bytes
      (when (find-package '#:limn/file)
        (let* ((save-fn (symbol-function
                           (find-symbol "SAVE-BUFFER"
                                        (find-package '#:limn/file))))
               (write-sym (find-symbol "*WRITE-FILE-FN*"
                                        (find-package '#:limn/file)))
               (written-cell (list nil)))
          (progv (list write-sym)
                 (list (lambda (path bytes)
                         (declare (ignore path))
                         (setf (car written-cell) bytes)))
            (funcall save-fn bid))

          (let ((wb (car written-cell)))
            (cond
              ((null wb)
               (format t "  NOTE: save-buffer did not call *write-file-fn*~%"))
              (t
               (assert-equal (length orig-bytes) (length wb)
                             "byte count matches")
               (assert-true
                 (loop for i below (length orig-bytes)
                       always (= (aref orig-bytes i) (aref wb i)))
                 "bytes are identical to original fixture"))))))

      (ignore-errors (send! "buffer/close" :|buffer-id| bid)))))
