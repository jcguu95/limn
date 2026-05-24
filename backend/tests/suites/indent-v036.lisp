;;;; v0.36 — Indent + current-column Qt-tier tests (RED)
;;;;
;;;; 真實 limn binary、走 wire 命令。驗證 v0.36 indent 系統 + current-column
;;;; 在 production SBCL runtime 上、對真 gap-buffer 真的能 round-trip：
;;;;
;;;;   T1 indent-to 8 / indent-tabs-mode=t / tab-width=8 → buffer/text "\t"
;;;;   T2 indent-to 8 / indent-tabs-mode=nil → 8 spaces
;;;;   T3 indent-to 10 / tabs-mode=t / tab-width=8 → "\t  "
;;;;   T4 current-column on CJK buffer "中文a" point 在尾 → 5
;;;;   T5 current-column on '\tabc' point 在 'a' / tab-width=8 → 8
;;;;   T6 move-to-column 4 on "abcdef" → cursor 4
;;;;   T7 move-to-column 10 :force t on "abc" → buffer "abc       ", cursor 10
;;;;   T8 back-to-indentation on "   \tfoo" → cursor 在 'f'
;;;;
;;;; SPEC §v0.36 寫 ~3 Qt；我們做 8 加碼覆蓋三層完整。
;;;;
;;;; 全部 RED — limn-indent.lisp 未實作。

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
               "limn-indent.lisp"))
    (handler-case (load (merge-pathnames f backend-dir))
      (error (e) (format t "  !! skipped ~A: ~A~%" f e)))))

;;; ── helpers ──────────────────────────────────────────────────────────────

(defmacro with-text-buf-content36 ((buf-var content) &body body)
  "Open a text-engine buffer, insert CONTENT, then run BODY."
  `(let* ((r0 (send! "bridge/engine-load"
                     :|win-id| "w1" :|engine| "text" :|path| ""))
          (,buf-var (json-get* r0 :|data| :|buffer-id|)))
     (unwind-protect
          (progn
            (send! "buffer/cursor-set" :|buffer-id| ,buf-var :|offset| 0)
            (when (and ,content (> (length ,content) 0))
              (send! "buffer/insert" :|buffer-id| ,buf-var :|text| ,content))
            ,@body)
       (when ,buf-var
         (ignore-errors (send! "buffer/close" :|buffer-id| ,buf-var))))))

(defmacro with-wire-indent ((buf-var) &body body)
  "Bind limn/indent + limn/excursion vtable to real wire."
  (let ((ipkg (gensym "IPKG"))
        (xpkg (gensym "XPKG"))
        (lpkg (gensym "LPKG")))
    `(let* ((,ipkg (find-package '#:limn/indent))
            (,xpkg (find-package '#:limn/excursion))
            (,lpkg (find-package '#:limn/local)))
       (if (null ,ipkg)
           (progn ,@body)
           (let* ((ipairs
                    (list
                     (cons (find-symbol "*BUFFER-TEXT-FN*" ,ipkg)
                           (lambda (bid)
                             (json-get* (send! "buffer/text"
                                               :|buffer-id| bid)
                                        :|data| :|text|)))
                     (cons (find-symbol "*BUFFER-INSERT-FN*" ,ipkg)
                           (lambda (bid off str)
                             ;; Move cursor to off first, then insert.
                             (send! "buffer/cursor-set"
                                    :|buffer-id| bid :|offset| off)
                             (send! "buffer/insert"
                                    :|buffer-id| bid :|text| str)))
                     (cons (find-symbol "*BUFFER-DELETE-FN*" ,ipkg)
                           (lambda (bid from to)
                             (send! "buffer/delete"
                                    :|buffer-id| bid
                                    :|from| from :|to| to)))
                     (cons (find-symbol "*POINT-FN*" ,ipkg)
                           (lambda (bid)
                             (json-get* (send! "buffer/cursor-get"
                                               :|buffer-id| bid)
                                        :|data| :|offset|)))
                     (cons (find-symbol "*SET-POINT-FN*" ,ipkg)
                           (lambda (bid off)
                             (send! "buffer/cursor-set"
                                    :|buffer-id| bid :|offset| off)))
                     (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,ipkg)
                           (lambda (bid)
                             (let ((txt (json-get*
                                         (send! "buffer/text"
                                                :|buffer-id| bid)
                                         :|data| :|text|)))
                               (if (stringp txt) (length txt) 0))))))
                  (xpairs
                    (when ,xpkg
                      (list (cons (find-symbol "*CURRENT-BUFFER*" ,xpkg)
                                  ,buf-var))))
                  (lpairs
                    (when ,lpkg
                      (list (cons (find-symbol "*CURRENT-BUFFER-ID*" ,lpkg)
                                  ,buf-var))))
                  (live (remove-if (lambda (p) (null (car p)))
                                   (append ipairs xpairs lpairs))))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))

(defun %qt-setq-local (sym value buf-id)
  (let ((pkg (find-package '#:limn/local)))
    (when pkg
      (let ((fn (find-symbol "SET-BUFFER-LOCAL-VALUE" pkg)))
        (when (and fn (fboundp fn))
          (funcall fn sym value buf-id))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T1. indent-to 8 / tabs-mode=t / tab-width=8 → "\t"
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-indent-to-tabs-mode-on
  "On empty text buffer, indent-to 8 with *indent-tabs-mode*=t /
   *tab-width*=8 → buffer/text 真出單一 TAB。"
  (with-text-buf-content36 (buf "")
    (with-wire-indent (buf)
      (%qt-setq-local (intern "*INDENT-TABS-MODE*" :cl-user) t   buf)
      (%qt-setq-local (intern "*TAB-WIDTH*"        :cl-user) 8   buf)
      (let* ((pkg (find-package '#:limn/indent))
             (fn  (and pkg (find-symbol "INDENT-TO" pkg))))
        (unless fn
          (return-from v036-qt-indent-to-tabs-mode-on
            (assert-true nil "limn/indent:indent-to missing — expected RED")))
        (funcall fn 8))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-ok r "buffer/text ok")
        (assert-equal (string #\Tab) (json-get* r :|data| :|text|)
                      "buffer contains single TAB")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T2. indent-to 8 / tabs-mode=nil → 8 spaces
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-indent-to-tabs-mode-off
  "indent-to 8 with *indent-tabs-mode*=nil → 8 個 ASCII 空白。"
  (with-text-buf-content36 (buf "")
    (with-wire-indent (buf)
      (%qt-setq-local (intern "*INDENT-TABS-MODE*" :cl-user) nil buf)
      (let* ((pkg (find-package '#:limn/indent))
             (fn  (and pkg (find-symbol "INDENT-TO" pkg))))
        (unless fn
          (return-from v036-qt-indent-to-tabs-mode-off
            (assert-true nil "indent-to missing")))
        (funcall fn 8))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal "        " (json-get* r :|data| :|text|)
                      "8 spaces")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T3. indent-to 10 / tabs-mode=t / tab-width=8 → "\t  " (1 TAB + 2 SPC)
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-indent-to-mixed-tab-and-space
  "indent-to 10 → TAB(8) + 2 個 SPC。"
  (with-text-buf-content36 (buf "")
    (with-wire-indent (buf)
      (%qt-setq-local (intern "*INDENT-TABS-MODE*" :cl-user) t   buf)
      (%qt-setq-local (intern "*TAB-WIDTH*"        :cl-user) 8   buf)
      (let* ((pkg (find-package '#:limn/indent))
             (fn  (and pkg (find-symbol "INDENT-TO" pkg))))
        (unless fn
          (return-from v036-qt-indent-to-mixed-tab-and-space
            (assert-true nil "indent-to missing")))
        (funcall fn 10))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal (format nil "~C  " #\Tab) (json-get* r :|data| :|text|)
                      "TAB + 2 SPC")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T4. current-column on CJK buffer "中文a" → 5 (2+2+1)
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-current-column-cjk
  "插 '中文a'、cursor 移到尾、(current-column) 真回 5。"
  (with-text-buf-content36 (buf
                            (concatenate 'string
                                         (string (code-char #x4E2D))
                                         (string (code-char #x6587))
                                         "a"))
    ;; cursor now at end (insert leaves point at end)
    (with-wire-indent (buf)
      (let* ((pkg (find-package '#:limn/indent))
             (fn  (and pkg (find-symbol "CURRENT-COLUMN" pkg))))
        (unless fn
          (return-from v036-qt-current-column-cjk
            (assert-true nil "current-column missing")))
        (assert-equal 5 (funcall fn)
                      "中(2) + 文(2) + a(1) = column 5")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T5. current-column after TAB / tab-width=8 → 8
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-current-column-after-tab
  "插 '\\tabc'、cursor 移到 'a' offset 1、(current-column) 真回 8。"
  (with-text-buf-content36 (buf (format nil "~Cabc" #\Tab))
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 1)
    (with-wire-indent (buf)
      (%qt-setq-local (intern "*TAB-WIDTH*" :cl-user) 8 buf)
      (let* ((pkg (find-package '#:limn/indent))
             (fn  (and pkg (find-symbol "CURRENT-COLUMN" pkg))))
        (unless fn
          (return-from v036-qt-current-column-after-tab
            (assert-true nil "current-column missing")))
        (assert-equal 8 (funcall fn)
                      "TAB advances to next tab-stop (col 8)")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T6. move-to-column 4 on "abcdef" → cursor offset 4
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-move-to-column-basic
  "插 'abcdef'、cursor 在 0、move-to-column 4 → cursor 真到 4。"
  (with-text-buf-content36 (buf "abcdef")
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
    (with-wire-indent (buf)
      (let* ((pkg (find-package '#:limn/indent))
             (fn  (and pkg (find-symbol "MOVE-TO-COLUMN" pkg))))
        (unless fn
          (return-from v036-qt-move-to-column-basic
            (assert-true nil "move-to-column missing")))
        (funcall fn 4))
      (let ((r (send! "buffer/cursor-get" :|buffer-id| buf)))
        (assert-equal 4 (json-get* r :|data| :|offset|)
                      "wire cursor really at 4")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T7. move-to-column 10 :force t on "abc" → buffer 補空白、cursor 10
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-move-to-column-force-extends
  "On 'abc' move-to-column 6 :force t → buffer 真補 3 空白、cursor 真到 6。"
  (with-text-buf-content36 (buf "abc")
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
    (with-wire-indent (buf)
      (let* ((pkg (find-package '#:limn/indent))
             (fn  (and pkg (find-symbol "MOVE-TO-COLUMN" pkg))))
        (unless fn
          (return-from v036-qt-move-to-column-force-extends
            (assert-true nil "move-to-column missing")))
        (funcall fn 6 t))
      (let ((r (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal "abc   " (json-get* r :|data| :|text|)
                      "buffer extended to col 6"))
      (let ((r (send! "buffer/cursor-get" :|buffer-id| buf)))
        (assert-equal 6 (json-get* r :|data| :|offset|)
                      "wire cursor at 6")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T8. back-to-indentation on "   \tfoo"
;;; ════════════════════════════════════════════════════════════════════════

(deftest v036-qt-back-to-indentation
  "On '   \\tfoo' cursor 在尾、back-to-indentation → cursor 真在 'f' (offset 4)。"
  (with-text-buf-content36 (buf (format nil "   ~Cfoo" #\Tab))
    ;; cursor at end after insert; explicitly seek to end to be safe
    (let ((r (send! "buffer/text" :|buffer-id| buf)))
      (send! "buffer/cursor-set" :|buffer-id| buf
             :|offset| (length (json-get* r :|data| :|text|))))
    (with-wire-indent (buf)
      (let* ((pkg (find-package '#:limn/indent))
             (fn  (and pkg (find-symbol "BACK-TO-INDENTATION" pkg))))
        (unless fn
          (return-from v036-qt-back-to-indentation
            (assert-true nil "back-to-indentation missing")))
        (funcall fn))
      (let ((r (send! "buffer/cursor-get" :|buffer-id| buf)))
        (assert-equal 4 (json-get* r :|data| :|offset|)
                      "wire cursor at offset 4 (first non-whitespace)")))))
