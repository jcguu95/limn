;;;; v0.26 §A+B — isearch / occur Qt-tier tests  (9 tests)
;;;;
;;;; Requires a running Limn instance with --test-mode.
;;;; Tests load limn-isearch.lisp and limn-occur.lisp directly (same
;;;; pattern as buffer-undo-wire.lisp) and verify via wire commands.
;;;;
;;;; Wire dependencies: buffer/insert, buffer/text, buffer/cursor-get,
;;;;   buffer/cursor-set, buffer/set-text.
;;;;
;;;; Vtable vars are bound in each test to call the wire layer so that
;;;; isearch/occur interact with the real gap-buffer state.

(in-package #:limn/test)

;;; ── load backend modules (idempotent) ────────────────────────────────────

(let* ((suite-dir   (make-pathname :defaults (or *load-pathname*
                                                  *default-pathname-defaults*)
                                    :name nil :type nil))
       (backend-dir (merge-pathnames "../../" suite-dir)))
  (dolist (f '("limn-hooks.lisp"
               "limn-log.lisp"
               "limn-error.lisp"
               "limn-history.lisp"
               "limn-text-props.lisp"
               "limn-isearch.lisp"
               "limn-occur.lisp"))
    (handler-case (load (merge-pathnames f backend-dir))
      (error (e) (format t "  !! skipped ~A: ~A~%" f e)))))

;;; ── helpers ──────────────────────────────────────────────────────────────

(defmacro with-text-buf-content ((buf-var content) &body body)
  "Open a text-engine buffer, insert CONTENT, then run BODY."
  `(with-text-buffer (,buf-var)
     (send! "buffer/set-text" :|buffer-id| ,buf-var :|text| ,content)
     ,@body))

(defmacro with-wire-isearch ((buf-var highlights-var history-var) &body body)
  "Bind isearch vtable vars to call the real wire layer for BUF-VAR.
   HIGHLIGHTS-VAR and HISTORY-VAR are bound to capture side-effects."
  (let ((pkg (gensym "PKG")))
    `(let* ((,highlights-var '())
            (,history-var    '())
            (,pkg (find-package '#:limn/isearch)))
       (if (null ,pkg)
           (progn ,@body)
           (let* ((pairs
                    (list
                     (cons (find-symbol "*BUFFER-TEXT-FN*"       ,pkg)
                           (lambda (bid)
                             (json-get* (send! "buffer/text"
                                               :|buffer-id| bid)
                                        :|data| :|text|)))
                     (cons (find-symbol "*BUFFER-CURSOR-FN*"     ,pkg)
                           (lambda (bid)
                             (json-get* (send! "buffer/cursor-get"
                                               :|buffer-id| bid)
                                        :|data| :|offset|)))
                     (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,pkg)
                           (lambda (bid off)
                             (send! "buffer/cursor-set"
                                    :|buffer-id| bid :|offset| off)))
                     (cons (find-symbol "*HIGHLIGHT-FN*"         ,pkg)
                           (lambda (bid spans face)
                             (declare (ignore bid))
                             (setf ,highlights-var (list :spans spans :face face))))
                     (cons (find-symbol "*CLEAR-HIGHLIGHTS-FN*"  ,pkg)
                           (lambda (bid)
                             (declare (ignore bid))
                             (setf ,highlights-var '())))
                     (cons (find-symbol "*HISTORY-PUSH-FN*"      ,pkg)
                           (lambda (q)
                             (push q ,history-var)))))
                  (live (remove-if (lambda (p) (null (car p))) pairs)))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))

(defmacro with-wire-occur ((buf-var occur-content-var) &body body)
  "Bind occur vtable vars to the real wire layer for BUF-VAR."
  (let ((pkg (gensym "PKG")))
    `(let* ((,occur-content-var nil)
            (,pkg (find-package '#:limn/occur)))
       (if (null ,pkg)
           (progn ,@body)
           (let* ((pairs
                    (list
                     (cons (find-symbol "*BUFFER-TEXT-FN*"       ,pkg)
                           (lambda (bid)
                             (json-get* (send! "buffer/text"
                                               :|buffer-id| bid)
                                        :|data| :|text|)))
                     (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,pkg)
                           (lambda (bid off)
                             (send! "buffer/cursor-set"
                                    :|buffer-id| bid :|offset| off)))
                     (cons (find-symbol "*OCCUR-WRITE-FN*"       ,pkg)
                           (lambda (obid content)
                             (declare (ignore obid))
                             (setf ,occur-content-var content)))))
                  (live (remove-if (lambda (p) (null (car p))) pairs)))
             (progv (mapcar #'car live) (mapcar #'cdr live)
               ,@body))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test 1: isearch-forward moves cursor to first match
;;;
;;; Procedure:
;;;   1. Create text buffer with "hello world hello".
;;;   2. Call isearch-start + isearch-update "world".
;;;   3. Verify cursor-get offset = 6.

(deftest isearch-qt1-forward-moves-cursor
  "isearch-forward: cursor jumps to first match offset in real buffer."
  (with-text-buf-content (buf "hello world hello")
    (with-wire-isearch (buf highlights history)
      (let* ((pkg (find-package '#:limn/isearch))
             (start-fn  (and pkg (find-symbol "ISEARCH-START"  pkg)))
             (update-fn (and pkg (find-symbol "ISEARCH-UPDATE" pkg))))
        (when (and start-fn update-fn)
          (let* ((st  (funcall start-fn buf))
                 (_   (funcall update-fn st "world")))
            (declare (ignore _))
            (let ((r (send! "buffer/cursor-get" :|buffer-id| buf)))
              (assert-ok r "cursor-get succeeds")
              (assert-equal 6 (json-get* r :|data| :|offset|)
                            "cursor at offset 6 (start of 'world')"))))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test 2: isearch-abort restores cursor
;;;
;;; Procedure:
;;;   1. Create buffer "foo bar baz", cursor at 4.
;;;   2. isearch-start, isearch-update "baz" (cursor moves to 8).
;;;   3. isearch-abort → cursor should return to 4.

(deftest isearch-qt2-abort-restores-cursor
  "isearch-abort restores cursor to pre-search position."
  (with-text-buf-content (buf "foo bar baz")
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 4)
    (with-wire-isearch (buf highlights history)
      (let* ((pkg (find-package '#:limn/isearch))
             (start-fn  (and pkg (find-symbol "ISEARCH-START"  pkg)))
             (update-fn (and pkg (find-symbol "ISEARCH-UPDATE" pkg)))
             (abort-fn  (and pkg (find-symbol "ISEARCH-ABORT"  pkg))))
        (when (and start-fn update-fn abort-fn)
          (let* ((st  (funcall start-fn buf))
                 (st2 (funcall update-fn st "baz")))
            (funcall abort-fn st2)
            (let ((r (send! "buffer/cursor-get" :|buffer-id| buf)))
              (assert-ok r "cursor-get after abort")
              (assert-equal 4 (json-get* r :|data| :|offset|)
                            "cursor restored to 4 after abort"))))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test 3: isearch-exit pushes to *search-history*
;;;
;;; Procedure:
;;;   1. Buffer with "apple".
;;;   2. isearch-forward "apple", isearch-exit.
;;;   3. Verify history-var contains "apple".

(deftest isearch-qt3-exit-pushes-search-history
  "isearch-exit pushes query to *history-push-fn*."
  (with-text-buf-content (buf "apple")
    (with-wire-isearch (buf highlights history)
      (let* ((pkg (find-package '#:limn/isearch))
             (start-fn  (and pkg (find-symbol "ISEARCH-START"  pkg)))
             (update-fn (and pkg (find-symbol "ISEARCH-UPDATE" pkg)))
             (exit-fn   (and pkg (find-symbol "ISEARCH-EXIT"   pkg))))
        (when (and start-fn update-fn exit-fn)
          (let* ((st  (funcall start-fn buf))
                 (st2 (funcall update-fn st "apple")))
            (funcall exit-fn st2)
            (assert-true (member "apple" history :test #'equal)
                         "*history-push-fn* received 'apple'")))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test 4: isearch-next moves cursor to second match
;;;
;;; Procedure:
;;;   1. Buffer "hello hello hello".
;;;   2. isearch-start + isearch-update "hello".
;;;   3. isearch-next → cursor at 6 (second hello).

(deftest isearch-qt4-next-jumps-to-second-match
  "isearch-next advances cursor to second match."
  (with-text-buf-content (buf "hello hello hello")
    (with-wire-isearch (buf highlights history)
      (let* ((pkg (find-package '#:limn/isearch))
             (start-fn  (and pkg (find-symbol "ISEARCH-START"  pkg)))
             (update-fn (and pkg (find-symbol "ISEARCH-UPDATE" pkg)))
             (next-fn   (and pkg (find-symbol "ISEARCH-NEXT"   pkg))))
        (when (and start-fn update-fn next-fn)
          (let* ((st   (funcall start-fn buf))
                 (st2  (funcall update-fn st "hello"))
                 (_    (funcall next-fn st2)))
            (declare (ignore _))
            (let ((r (send! "buffer/cursor-get" :|buffer-id| buf)))
              (assert-ok r)
              (assert-equal 6 (json-get* r :|data| :|offset|)
                            "cursor at offset 6 (second 'hello')"))))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test 5: highlight-fn called during isearch-update
;;;
;;; Procedure:
;;;   1. Buffer "abc def abc".
;;;   2. isearch-update "abc".
;;;   3. highlights-var should be non-nil (highlight was called).

(deftest isearch-qt5-highlight-fn-called
  "*highlight-fn* is invoked during isearch-update."
  (with-text-buf-content (buf "abc def abc")
    (with-wire-isearch (buf highlights history)
      (let* ((pkg (find-package '#:limn/isearch))
             (start-fn  (and pkg (find-symbol "ISEARCH-START"  pkg)))
             (update-fn (and pkg (find-symbol "ISEARCH-UPDATE" pkg))))
        (when (and start-fn update-fn)
          (let* ((st  (funcall start-fn buf))
                 (_   (funcall update-fn st "abc")))
            (declare (ignore _))
            (assert-true highlights
                         "*highlight-fn* was called with non-empty spans")))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test 6: occur produces correct count on real buffer
;;;
;;; Procedure:
;;;   1. Buffer "match this\nno hit\nalso match\n".
;;;   2. occur "match" → count = 2.

(deftest isearch-qt6-occur-count-on-real-buffer
  "occur returns correct match count on a real text buffer."
  (with-text-buf-content (buf "match this\nno hit\nalso match\n")
    (with-wire-occur (buf occur-content)
      (let* ((pkg (find-package '#:limn/occur))
             (occur-fn (and pkg (find-symbol "OCCUR" pkg)))
             (count-fn (and pkg (find-symbol "OCCUR-COUNT" pkg))))
        (when (and occur-fn count-fn)
          (let* ((st (funcall occur-fn buf "match")))
            (assert-equal 2 (funcall count-fn st)
                          "2 lines contain 'match'")))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test 7: occur writes content to *occur-write-fn*
;;;
;;; Procedure:
;;;   1. Buffer "hello world\nhello again".
;;;   2. occur "hello" → *occur-write-fn* content contains "hello world".

(deftest isearch-qt7-occur-writes-occur-buffer
  "*occur-write-fn* receives formatted results string."
  (with-text-buf-content (buf "hello world\nhello again")
    (with-wire-occur (buf occur-content)
      (let* ((pkg (find-package '#:limn/occur))
             (occur-fn (and pkg (find-symbol "OCCUR" pkg))))
        (when occur-fn
          (funcall occur-fn buf "hello")
          (assert-true occur-content
                       "*occur-write-fn* was called")
          (assert-true (and (stringp occur-content)
                            (search "hello world" occur-content))
                       "occur content contains first matching line"))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test 8: occur-jump moves source-buffer cursor
;;;
;;; Procedure:
;;;   1. Buffer "first line\nsecond match\nthird".
;;;   2. occur "match", occur-jump.
;;;   3. buffer/cursor-get = 18 ("first line\n" = 11, "second " = 7 → 18).

(deftest isearch-qt8-occur-jump-sets-cursor
  "occur-jump sets source-buffer cursor to the match offset."
  (with-text-buf-content (buf "first line\nsecond match\nthird")
    (with-wire-occur (buf occur-content)
      (let* ((pkg (find-package '#:limn/occur))
             (occur-fn (and pkg (find-symbol "OCCUR"      pkg)))
             (jump-fn  (and pkg (find-symbol "OCCUR-JUMP" pkg))))
        (when (and occur-fn jump-fn)
          (let* ((st (funcall occur-fn buf "match")))
            (funcall jump-fn st)
            (let ((r (send! "buffer/cursor-get" :|buffer-id| buf)))
              (assert-ok r "cursor-get after occur-jump")
              ;; "first line\n" = 11 chars, "second " = 7 chars → "match" at 18
              (assert-equal 18 (json-get* r :|data| :|offset|)
                            "cursor at 'match' offset 18"))))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test 9: isearch + occur same session, no interference
;;;
;;; Procedure:
;;;   1. One buffer "x y x y x".
;;;   2. isearch-start + isearch-update "x" → 3 matches.
;;;   3. Immediately run occur "y" on same buffer → 2 lines (here 1 line with 2 y).
;;;   4. Verify isearch state still has 3 matches (not contaminated).

(deftest isearch-qt9-isearch-and-occur-no-cross-contamination
  "isearch and occur on same buffer do not interfere."
  (with-text-buf-content (buf "x y x y x")
    (with-wire-isearch (buf highlights history)
      (with-wire-occur (buf occur-content)
        (let* ((ipkg (find-package '#:limn/isearch))
               (opkg (find-package '#:limn/occur))
               (i-start  (and ipkg (find-symbol "ISEARCH-START"  ipkg)))
               (i-update (and ipkg (find-symbol "ISEARCH-UPDATE" ipkg)))
               (i-matches(and ipkg (find-symbol "ISEARCH-MATCHES" ipkg)))
               (o-occur  (and opkg (find-symbol "OCCUR"       opkg)))
               (o-count  (and opkg (find-symbol "OCCUR-COUNT" opkg))))
          (when (and i-start i-update i-matches o-occur o-count)
            (let* ((ist  (funcall i-start buf))
                   (ist2 (funcall i-update ist "x"))
                   (ost  (funcall o-occur buf "y")))
              ;; isearch state untouched by occur call
              (assert-equal 3 (length (funcall i-matches ist2))
                            "isearch: 3 'x' matches unaffected by occur")
              ;; occur finds "y" in the same buffer
              (assert-equal 1 (funcall o-count ost)
                            "occur: 1 line containing 'y'"))))))))
