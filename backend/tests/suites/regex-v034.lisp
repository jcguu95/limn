;;;; v0.34 — Real regex engine Qt-tier tests (4 tests)
;;;;
;;;; 對著真實 limn binary 跑、走實際 wire 命令，驗證 v0.34 regex 系統真的能
;;;; 在 wire 上 round-trip：text buffer 內 re-search-forward 跳 cursor、
;;;; replace-match 真的改 buffer 內容、cl-ppcre vendor 真的在 production
;;;; SBCL runtime 載入起來、Emacs syntax shim end-to-end 跑得通。
;;;;
;;;; SPEC §v0.34 規定 ~2 Qt tests；我們做 4 個：
;;;;   T1. re-search-forward 在真 text buffer 上：cursor 真的移動、
;;;;       match-string 真的有值。
;;;;   T2. replace-regexp 端到端：re-search-forward + replace-match 兩次、
;;;;       buffer/text 真的變。
;;;;   T3. cl-ppcre vendor wireup smoke：limn-regex.lisp 載入後
;;;;       (find-package :cl-ppcre) 真、(cl-ppcre:scan ...) 可呼叫。
;;;;   T4. Emacs syntax shim 端到端：\\<defun\\> 在真 buffer 找到 defun 結尾、
;;;;       cursor 移到正確位置。
;;;;
;;;; 全部 RED — limn-regex.lisp + vendor/cl-ppcre 還沒落地。

(in-package #:limn/test)

;;; ── load backend modules (idempotent, 同 isearch-v026 / excursion-v032
;;; 的 pattern) ────────────────────────────────────────────────────────────

(let* ((suite-dir   (make-pathname :defaults (or *load-pathname*
                                                  *default-pathname-defaults*)
                                    :name nil :type nil))
       (backend-dir (merge-pathnames "../../" suite-dir))
       (vendor-loader (merge-pathnames "../../../vendor/cl-ppcre-load.lisp"
                                       suite-dir)))
  ;; 先試載 vendor（不存在則 silently skip，§T3 會 RED catch）
  (handler-case (load vendor-loader)
    (error (e) (format t "  !! skipped vendor cl-ppcre: ~A~%" e)))
  (dolist (f '("limn-hooks.lisp"
               "limn-log.lisp"
               "limn-error.lisp"
               "limn-marker.lisp"
               "limn-local.lisp"
               "limn-excursion.lisp"
               "limn-regex.lisp"))
    (handler-case (load (merge-pathnames f backend-dir))
      (error (e) (format t "  !! skipped ~A: ~A~%" f e)))))

;;; ── helpers ──────────────────────────────────────────────────────────────
;;;
;;; with-wire-regex binds limn/regex 的 vtable 到實際 wire send! 上，這樣
;;; re-search-forward / replace-match / looking-at 等就能對著真 gap-buffer
;;; 做事。Pattern 對齊 isearch-v026.lisp 的 with-wire-isearch。

(defmacro with-text-buf-content34 ((buf-var content) &body body)
  "Open a text-engine buffer, insert CONTENT, then run BODY. Uses
   buffer/insert (the actual wire command — there is no buffer/set-text)."
  `(let* ((r0 (send! "bridge/engine-load"
                     :|win-id| "w1" :|engine| "text" :|path| ""))
          (,buf-var (json-get* r0 :|data| :|buffer-id|)))
     (unwind-protect
          (progn
            (send! "buffer/cursor-set" :|buffer-id| ,buf-var :|offset| 0)
            (send! "buffer/insert" :|buffer-id| ,buf-var :|text| ,content)
            ,@body)
       (when ,buf-var
         (ignore-errors (send! "buffer/close" :|buffer-id| ,buf-var))))))

(defmacro with-wire-regex ((buf-var) &body body)
  "Bind limn/regex 跟 limn/excursion 的 vtable 到 wire；*current-buffer*
   設成 BUF-VAR；reset match-data。"
  (let ((rpkg (gensym "RPKG"))
        (xpkg (gensym "XPKG")))
    `(let* ((,rpkg (find-package '#:limn/regex))
            (,xpkg (find-package '#:limn/excursion)))
       (if (null ,rpkg)
           (progn ,@body)
           (let* ((rpairs
                    (list
                     (cons (find-symbol "*BUFFER-TEXT-FN*" ,rpkg)
                           (lambda (bid)
                             (json-get* (send! "buffer/text"
                                               :|buffer-id| bid)
                                        :|data| :|text|)))
                     (cons (find-symbol "*BUFFER-SET-TEXT-FN*" ,rpkg)
                           ;; No wire-level set-text exists; emulate via
                           ;; delete (whole buffer) + insert at 0.
                           ;; (buffer/delete keys are :from / :to per
                           ;; limn_command.cpp:cmd_buffer_delete.)
                           (lambda (bid text)
                             (let* ((r (send! "buffer/text"
                                              :|buffer-id| bid))
                                    (old (json-get* r :|data| :|text|))
                                    (len (if (stringp old) (length old) 0)))
                               (when (> len 0)
                                 (send! "buffer/delete"
                                        :|buffer-id| bid
                                        :|from| 0 :|to| len))
                               (send! "buffer/cursor-set"
                                      :|buffer-id| bid :|offset| 0)
                               (send! "buffer/insert"
                                      :|buffer-id| bid :|text| text))))
                     (cons (find-symbol "*POINT-FN*" ,rpkg)
                           (lambda (bid)
                             (json-get* (send! "buffer/cursor-get"
                                               :|buffer-id| bid)
                                        :|data| :|offset|)))
                     (cons (find-symbol "*SET-POINT-FN*" ,rpkg)
                           (lambda (bid off)
                             (send! "buffer/cursor-set"
                                    :|buffer-id| bid :|offset| off)))
                     (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,rpkg)
                           (lambda (bid)
                             (let ((txt (json-get*
                                         (send! "buffer/text"
                                                :|buffer-id| bid)
                                         :|data| :|text|)))
                               (if (stringp txt) (length txt) 0))))))
                  (xpairs
                    (when ,xpkg
                      (list
                       (cons (find-symbol "*CURRENT-BUFFER*" ,xpkg)
                             ,buf-var))))
                  (live (remove-if (lambda (p) (null (car p)))
                                   (append rpairs xpairs))))
             (when ,rpkg
               (let ((r (find-symbol "RESET-MATCH-DATA" ,rpkg)))
                 (when r (funcall r))))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T1. re-search-forward over real wire: cursor moves, match-string set
;;; ════════════════════════════════════════════════════════════════════════

(deftest v034-qt-re-search-forward-moves-cursor
  "open text buffer 'foo bar baz', set point=0, call re-search-forward
   \"bar\" → cursor 變 7 (end of 'bar'), match-string 0 = 'bar'."
  (with-text-buf-content34 (buf "foo bar baz")
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
    (with-wire-regex (buf)
      (let* ((pkg (find-package '#:limn/regex))
             (rsf (and pkg (find-symbol "RE-SEARCH-FORWARD" pkg)))
             (ms  (and pkg (find-symbol "MATCH-STRING" pkg))))
        (unless (and rsf ms)
          (return-from v034-qt-re-search-forward-moves-cursor
            (assert-true nil "limn/regex API missing — expected RED")))
        (let ((rv (funcall rsf "bar")))
          (assert-equal 7 rv "re-search-forward returns 7 (match end)"))
        (let ((r (send! "buffer/cursor-get" :|buffer-id| buf)))
          (assert-ok r "cursor-get succeeds")
          (assert-equal 7 (json-get* r :|data| :|offset|)
                        "cursor really moved to 7 on the wire"))
        (assert-equal "bar" (funcall ms 0)
                      "match-string 0 = 'bar' after wire round-trip")))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T2. replace-regexp end-to-end: loop re-search-forward + replace-match,
;;;     buffer/text really changes on the wire.
;;; ════════════════════════════════════════════════════════════════════════

(deftest v034-qt-replace-regexp-end-to-end
  "open text buffer 'name=Alice; name=Bob', loop re-search-forward
   \"name=\\\\(\\\\w+\\\\)\" + replace-match \"user(\\\\1)\" 兩次 →
   buffer/text = 'user(Alice); user(Bob)'."
  (with-text-buf-content34 (buf "name=Alice; name=Bob")
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
    (with-wire-regex (buf)
      (let* ((pkg (find-package '#:limn/regex))
             (rsf (and pkg (find-symbol "RE-SEARCH-FORWARD" pkg)))
             (rm  (and pkg (find-symbol "REPLACE-MATCH"     pkg))))
        (unless (and rsf rm)
          (return-from v034-qt-replace-regexp-end-to-end
            (assert-true nil "limn/regex API missing — expected RED")))
        (loop repeat 2
              while (funcall rsf "name=\\(\\w+\\)" nil t)
              do (funcall rm "user(\\1)"))
        (let ((r (send! "buffer/text" :|buffer-id| buf)))
          (assert-ok r "buffer/text succeeds")
          (assert-equal "user(Alice); user(Bob)"
                        (json-get* r :|data| :|text|)
                        "buffer text after 2 replace-match"))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T3. cl-ppcre vendor wireup smoke
;;;
;;; Verifies that vendor/cl-ppcre-load.lisp actually loaded in this SBCL
;;; (post limn-regex.lisp init). Catches the v0.29 / v0.32-style wireup
;;; regressions where vendor isn't reachable from production load path.
;;; ════════════════════════════════════════════════════════════════════════

(deftest v034-qt-cl-ppcre-vendor-loaded-in-process
  "limn-regex.lisp 載入後 cl-ppcre package 存在、SCAN 可呼叫、回 0 for
   literal at start。"
  (let ((pkg (find-package '#:cl-ppcre)))
    (assert-true pkg "cl-ppcre package loaded in this SBCL image")
    (let ((scan (and pkg (find-symbol "SCAN" pkg))))
      (assert-true (and scan (fboundp scan))
                   "cl-ppcre:scan is fbound")
      (when (and scan (fboundp scan))
        (let ((s (funcall scan "a" "abc")))
          (assert-equal 0 s "scan literal at start returns 0"))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; T4. Emacs syntax shim end-to-end on real wire buffer
;;;
;;; '\\<defun\\>' is Emacs word-start + word-end syntax. Must be translated
;;; to PCRE equivalents and find 'defun' in real wire text.
;;; ════════════════════════════════════════════════════════════════════════

(deftest v034-qt-emacs-syntax-shim-end-to-end
  "real wire buffer 'predefun defun bar' (注意第一個是 'predefun'，不是
   word-bounded 'defun')，re-search-forward \"\\\\<defun\\\\>\" 應 skip
   predefun、命中第二個 'defun'。"
  (with-text-buf-content34 (buf "predefun defun bar")
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
    (with-wire-regex (buf)
      (let* ((pkg (find-package '#:limn/regex))
             (rsf (and pkg (find-symbol "RE-SEARCH-FORWARD" pkg))))
        (unless rsf
          (return-from v034-qt-emacs-syntax-shim-end-to-end
            (assert-true nil "limn/regex API missing — expected RED")))
        (let ((rv (funcall rsf "\\<defun\\>")))
          ;; "predefun defun bar" — word-bounded 'defun' starts at offset 9,
          ;; ends at 14
          (assert-equal 14 rv
                        "re-search-forward \\<defun\\> end = 14 (skips predefun)"))
        (let ((r (send! "buffer/cursor-get" :|buffer-id| buf)))
          (assert-equal 14 (json-get* r :|data| :|offset|)
                        "wire cursor really at 14"))))))
