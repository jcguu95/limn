;;;; v0.36 — query-replace Qt-tier tests (RED)
;;;;
;;;; 真實 limn binary、走 wire；query-replace 餵 response-fn 模擬 y/n/!/q/^。
;;;;
;;;;   T1 query-replace "foo"→"bar"，y y → 'X bar X'
;;;;   T2 query-replace "foo"→"X"，y n y → 'X foo X' (middle skipped)
;;;;   T3 ! 自動換完剩餘
;;;;   T4 q 中止
;;;;   T5 . 換一個就退出
;;;;   T6 ^ 回上一個 match、改答 n、再 y
;;;;   T7 query-replace-regexp \(\d+\)px → \1em
;;;;   T8 text-mode 真按 TAB → buffer 真出 '\t' (驗 §B keymap wireup)
;;;;
;;;; SPEC §v0.36 寫 ~3 Qt；本檔 8。
;;;;
;;;; 全部 RED — limn-query-replace.lisp 未實作；§B keymap wireup 未掛。

(in-package #:limn/test)

;;; ── load backend modules (idempotent) ────────────────────────────────────

(let* ((suite-dir   (make-pathname :defaults (or *load-pathname*
                                                  *default-pathname-defaults*)
                                    :name nil :type nil))
       (backend-dir (merge-pathnames "../../" suite-dir))
       (vendor-loader (merge-pathnames "../../../vendor/cl-ppcre-load.lisp"
                                       suite-dir)))
  (handler-case (load vendor-loader)
    (error (e) (format t "  !! skipped vendor cl-ppcre: ~A~%" e)))
  (dolist (f '("limn-hooks.lisp"
               "limn-log.lisp"
               "limn-error.lisp"
               "limn-marker.lisp"
               "limn-local.lisp"
               "limn-excursion.lisp"
               "limn-regex.lisp"
               "limn-indent.lisp"
               "limn-query-replace.lisp"))
    (handler-case (load (merge-pathnames f backend-dir))
      (error (e) (format t "  !! skipped ~A: ~A~%" f e)))))

;;; ── helpers ──────────────────────────────────────────────────────────────

(defmacro with-text-buf-qr ((buf-var content) &body body)
  `(let* ((r0 (send! "bridge/engine-load"
                     :|win-id| "w1" :|engine| "text" :|path| ""))
          (,buf-var (json-get* r0 :|data| :|buffer-id|)))
     (unwind-protect
          (progn
            (send! "buffer/cursor-set" :|buffer-id| ,buf-var :|offset| 0)
            (when (and ,content (> (length ,content) 0))
              (send! "buffer/insert" :|buffer-id| ,buf-var :|text| ,content))
            (send! "buffer/cursor-set" :|buffer-id| ,buf-var :|offset| 0)
            ,@body)
       (when ,buf-var
         (ignore-errors (send! "buffer/close" :|buffer-id| ,buf-var))))))

(defmacro with-wire-qr ((buf-var) &body body)
  "Bind limn/query-replace + limn/regex + limn/excursion vtable to wire."
  (let ((qpkg (gensym "QPKG"))
        (rpkg (gensym "RPKG"))
        (xpkg (gensym "XPKG"))
        (lpkg (gensym "LPKG")))
    `(let* ((,qpkg (find-package '#:limn/query-replace))
            (,rpkg (find-package '#:limn/regex))
            (,xpkg (find-package '#:limn/excursion))
            (,lpkg (find-package '#:limn/local)))
       (if (null ,qpkg)
           (progn ,@body)
           (let* ((wire-text
                    (lambda (bid)
                      (json-get* (send! "buffer/text" :|buffer-id| bid)
                                 :|data| :|text|)))
                  (wire-set-text
                    (lambda (bid txt)
                      (let* ((r (send! "buffer/text" :|buffer-id| bid))
                             (old (json-get* r :|data| :|text|))
                             (len (if (stringp old) (length old) 0)))
                        (when (> len 0)
                          (send! "buffer/delete" :|buffer-id| bid
                                 :|from| 0 :|to| len))
                        (send! "buffer/cursor-set" :|buffer-id| bid
                               :|offset| 0)
                        (send! "buffer/insert" :|buffer-id| bid
                               :|text| txt))))
                  (wire-insert
                    (lambda (bid off str)
                      (send! "buffer/cursor-set" :|buffer-id| bid
                             :|offset| off)
                      (send! "buffer/insert" :|buffer-id| bid :|text| str)))
                  (wire-delete
                    (lambda (bid from to)
                      (send! "buffer/delete" :|buffer-id| bid
                             :|from| from :|to| to)))
                  (wire-point
                    (lambda (bid)
                      (json-get* (send! "buffer/cursor-get" :|buffer-id| bid)
                                 :|data| :|offset|)))
                  (wire-set-point
                    (lambda (bid off)
                      (send! "buffer/cursor-set" :|buffer-id| bid
                             :|offset| off)))
                  (wire-text-len
                    (lambda (bid)
                      (let ((txt (json-get*
                                  (send! "buffer/text" :|buffer-id| bid)
                                  :|data| :|text|)))
                        (if (stringp txt) (length txt) 0))))
                  (qpairs
                    (when ,qpkg
                      (list
                       (cons (find-symbol "*BUFFER-TEXT-FN*"     ,qpkg) wire-text)
                       (cons (find-symbol "*BUFFER-INSERT-FN*"   ,qpkg) wire-insert)
                       (cons (find-symbol "*BUFFER-DELETE-FN*"   ,qpkg) wire-delete)
                       (cons (find-symbol "*POINT-FN*"           ,qpkg) wire-point)
                       (cons (find-symbol "*SET-POINT-FN*"       ,qpkg) wire-set-point)
                       (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,qpkg) wire-text-len))))
                  (rpairs
                    (when ,rpkg
                      (list
                       (cons (find-symbol "*BUFFER-TEXT-FN*"     ,rpkg) wire-text)
                       (cons (find-symbol "*BUFFER-SET-TEXT-FN*" ,rpkg) wire-set-text)
                       (cons (find-symbol "*POINT-FN*"           ,rpkg) wire-point)
                       (cons (find-symbol "*SET-POINT-FN*"       ,rpkg) wire-set-point)
                       (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,rpkg) wire-text-len))))
                  (xpairs
                    (when ,xpkg
                      (list (cons (find-symbol "*CURRENT-BUFFER*" ,xpkg)
                                  ,buf-var))))
                  (lpairs
                    (when ,lpkg
                      (list (cons (find-symbol "*CURRENT-BUFFER-ID*" ,lpkg)
                                  ,buf-var))))
                  (live (remove-if (lambda (p) (null (car p)))
                                   (append qpairs rpairs xpairs lpairs))))
             (when ,rpkg
               (let ((r (find-symbol "RESET-MATCH-DATA" ,rpkg)))
                 (when r (funcall r))))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))

(defun %qt-make-responder (responses)
  (let ((box (copy-list responses)))
    (lambda () (pop box))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T1. y y replaces both
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-qr-literal-y-y
  "插 'foo bar foo'、query-replace 'foo' → 'X'，y y → 'X bar X'。"
  (with-text-buf-qr (buf "foo bar foo")
    (with-wire-qr (buf)
      (let* ((pkg (find-package '#:limn/query-replace))
             (fn  (and pkg (find-symbol "QUERY-REPLACE" pkg))))
        (unless fn
          (return-from v036-qt-qr-literal-y-y
            (assert-true nil "query-replace missing — RED")))
        (funcall fn "foo" "X" :response-fn (%qt-make-responder '("y" "y"))))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal "X bar X" (json-get* r :|data| :|text|)
                      "wire buffer = 'X bar X'")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T2. y n y skips middle (note: 3 foos)
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-qr-literal-y-n-y
  "'foo foo foo' y n y → 'X foo X'。"
  (with-text-buf-qr (buf "foo foo foo")
    (with-wire-qr (buf)
      (let* ((pkg (find-package '#:limn/query-replace))
             (fn  (and pkg (find-symbol "QUERY-REPLACE" pkg))))
        (unless fn
          (return-from v036-qt-qr-literal-y-n-y
            (assert-true nil "query-replace missing — RED")))
        (funcall fn "foo" "X"
                 :response-fn (%qt-make-responder '("y" "n" "y"))))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal "X foo X" (json-get* r :|data| :|text|)
                      "middle foo kept")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T3. ! auto-replaces remaining
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-qr-literal-bang
  "'a a a a a' ! → 'B B B B B'。"
  (with-text-buf-qr (buf "a a a a a")
    (with-wire-qr (buf)
      (let* ((pkg (find-package '#:limn/query-replace))
             (fn  (and pkg (find-symbol "QUERY-REPLACE" pkg))))
        (unless fn
          (return-from v036-qt-qr-literal-bang
            (assert-true nil "query-replace missing — RED")))
        (funcall fn "a" "B" :response-fn (%qt-make-responder '("!"))))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal "B B B B B" (json-get* r :|data| :|text|)
                      "all replaced")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T4. q quits after first
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-qr-literal-q
  "'foo foo foo' y q → 'X foo foo'。"
  (with-text-buf-qr (buf "foo foo foo")
    (with-wire-qr (buf)
      (let* ((pkg (find-package '#:limn/query-replace))
             (fn  (and pkg (find-symbol "QUERY-REPLACE" pkg))))
        (unless fn
          (return-from v036-qt-qr-literal-q
            (assert-true nil "query-replace missing — RED")))
        (funcall fn "foo" "X" :response-fn (%qt-make-responder '("y" "q"))))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal "X foo foo" (json-get* r :|data| :|text|)
                      "quit after first")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T5. . replaces this then quits
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-qr-literal-dot
  "'foo foo foo' . → 'X foo foo' (dot 換並退出)。"
  (with-text-buf-qr (buf "foo foo foo")
    (with-wire-qr (buf)
      (let* ((pkg (find-package '#:limn/query-replace))
             (fn  (and pkg (find-symbol "QUERY-REPLACE" pkg))))
        (unless fn
          (return-from v036-qt-qr-literal-dot
            (assert-true nil "query-replace missing — RED")))
        (funcall fn "foo" "X" :response-fn (%qt-make-responder '("."))))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal "X foo foo" (json-get* r :|data| :|text|)
                      ". replaces this then quits")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T6. ^ goes back to previous match
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-qr-literal-caret-back
  "'foo foo foo' y ^ n y y → 'foo X X'。
   y: first → X. ^: revert. n: keep first. y: replace 2nd. y: replace 3rd."
  (with-text-buf-qr (buf "foo foo foo")
    (with-wire-qr (buf)
      (let* ((pkg (find-package '#:limn/query-replace))
             (fn  (and pkg (find-symbol "QUERY-REPLACE" pkg))))
        (unless fn
          (return-from v036-qt-qr-literal-caret-back
            (assert-true nil "query-replace missing — RED")))
        (funcall fn "foo" "X"
                 :response-fn (%qt-make-responder
                               '("y" "^" "n" "y" "y"))))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal "foo X X" (json-get* r :|data| :|text|)
                      "after ^: first kept, rest replaced")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T7. query-replace-regexp \([0-9]+\)px → \1em
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-qr-regexp-group-ref
  "插 '12px 34px 56px'、! → '12em 34em 56em'。"
  (with-text-buf-qr (buf "12px 34px 56px")
    (with-wire-qr (buf)
      (let* ((pkg (find-package '#:limn/query-replace))
             (fn  (and pkg (find-symbol "QUERY-REPLACE-REGEXP" pkg))))
        (unless fn
          (return-from v036-qt-qr-regexp-group-ref
            (assert-true nil "query-replace-regexp missing — RED")))
        (funcall fn "\\([0-9]+\\)px" "\\1em"
                 :response-fn (%qt-make-responder '("!"))))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal "12em 34em 56em" (json-get* r :|data| :|text|)
                      "group ref substituted end-to-end")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T8. TAB key in text-mode → indent-for-tab-command → buffer gets TAB
;;;
;;; This is the §B keymap wireup test.
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-text-mode-tab-key
  "Activate text-mode、按 TAB key (wire) → buffer 真出 '\\t' (預設
   indent-tabs-mode=t)。"
  (with-text-buf-qr (buf "")
    ;; Make sure text-mode is active on the window's mode-buffer.
    (let* ((r (send! "view/get" :|win-id| "w1"))
           (mb (json-get* r :|data| :|mode-buffer-id|)))
      (when mb
        (send! "mode/activate" :|buffer-id| mb :|mode| "text-mode")))
    ;; Send a TAB key event through the wire input layer.
    (let ((r (send! "key/send" :|win-id| "w1" :|key| "TAB")))
      (declare (ignore r)))
    ;; Buffer content should now have a single \t (or 8 spaces if
    ;; indent-tabs-mode=nil — but default is t).
    (let* ((r (send! "buffer/text" :|buffer-id| buf))
           (txt (json-get* r :|data| :|text|)))
      (assert-true (or (equal txt (string #\Tab))
                       (equal txt "        "))
                   "buffer has TAB or 8 spaces after pressing TAB key"))))
