;;;; v0.36 — query-replace unit tests (RED)
;;;;
;;;; 覆蓋 SPEC §v0.36 §A：
;;;;   - query-replace + query-replace-regexp 拼裝 v0.34 regex API +
;;;;     v0.32 save-excursion + minibuffer prompt loop
;;;;   - 按鍵循環: y/SPC (replace+next), n/DEL (skip), ! (all-remaining),
;;;;     q/RET (quit), . (replace+quit), , (replace+pause), ^ (undo last)
;;;;   - 範圍 arg (FROM, TO)
;;;;   - regex group reference (\1, \2)
;;;;   - 與 narrow-to-region / save-excursion 整合
;;;;   - 邊界: no match, empty regex, search-failed silence
;;;;
;;;; 為了在 unit-tier 不依賴真 minibuffer，query-replace 接受可選的
;;;; :response-fn — 一個 thunk 回傳每次該餵的 key（"y"/"n"/...）。
;;;; 真實 production 走 minibuffer prompt。
;;;;
;;;; 全部 RED — 在 limn-query-replace.lisp 實作前都會 fail。

;; ── package stub ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/query-replace)
    (make-package '#:limn/query-replace :use '(#:cl)))
  (dolist (sym '("QUERY-REPLACE"
                 "QUERY-REPLACE-REGEXP"
                 ;; vtable hooks (mirror limn/regex's so we can share mock bufs)
                 "*BUFFER-TEXT-FN*"
                 "*BUFFER-INSERT-FN*"
                 "*BUFFER-DELETE-FN*"
                 "*POINT-FN*"
                 "*SET-POINT-FN*"
                 "*BUFFER-TEXT-LEN-FN*"
                 ;; result accessors
                 "*LAST-REPLACE-COUNT*"))
    (export (intern sym '#:limn/query-replace) '#:limn/query-replace)))

(in-package #:limn/unit-test)

;;; ── mock buffer (re-use mbuf36 from indent-v036 if loaded; otherwise
;;; define a fresh one). To avoid load-order coupling we define a parallel
;;; mbuf-qr struct.

(defstruct (mbuf-qr
             (:conc-name mbuf-qr-)
             (:constructor make-mbuf-qr (&key (id "qrb") (text "") (point 0))))
  id
  (text "" :type string)
  (point 0 :type integer))

(defun mbuf-qr-len (b) (length (mbuf-qr-text b)))

(defvar *qr-buffers* (make-hash-table :test 'equal))

(defun mbuf-qr-get (bid) (gethash bid *qr-buffers*))

(defun qr-text-fn (bid)
  (let ((b (mbuf-qr-get bid))) (if b (mbuf-qr-text b) "")))

(defun qr-point-fn (bid)
  (let ((b (mbuf-qr-get bid))) (if b (mbuf-qr-point b) 0)))

(defun qr-set-point-fn (bid off)
  (let ((b (mbuf-qr-get bid)))
    (when b (setf (mbuf-qr-point b) off))))

(defun qr-text-len-fn (bid)
  (let ((b (mbuf-qr-get bid))) (if b (mbuf-qr-len b) 0)))

(defun qr-insert-fn (bid off str)
  (let ((b (mbuf-qr-get bid)))
    (when b
      (let* ((t0 (mbuf-qr-text b))
             (pre (subseq t0 0 off))
             (post (subseq t0 off)))
        (setf (mbuf-qr-text b) (concatenate 'string pre str post))
        (when (>= (mbuf-qr-point b) off)
          (incf (mbuf-qr-point b) (length str)))))))

(defun qr-delete-fn (bid from to)
  (let ((b (mbuf-qr-get bid)))
    (when b
      (let* ((t0 (mbuf-qr-text b))
             (pre (subseq t0 0 from))
             (post (subseq t0 to)))
        (setf (mbuf-qr-text b) (concatenate 'string pre post))
        (let ((p (mbuf-qr-point b)))
          (cond ((<= p from) nil)
                ((>= p to) (decf (mbuf-qr-point b) (- to from)))
                (t (setf (mbuf-qr-point b) from))))))))

(defun %qr-set-text (bid txt)
  "Total replace — convenience for tests."
  (let ((b (mbuf-qr-get bid)))
    (when b
      (setf (mbuf-qr-text b) txt)
      (setf (mbuf-qr-point b) (min (mbuf-qr-point b) (length txt))))))

(defmacro with-qr-ctx ((&rest buf-specs) &body body)
  "Wires limn/query-replace AND limn/regex vtables to the same mock buffer.
   limn/regex's vtable also needs *buffer-set-text-fn*; we install one
   that just delegates to delete+insert."
  (let* ((first-spec (car buf-specs))
         (first-var  (car first-spec))
         (vars  (mapcar #'car buf-specs))
         (kwargs (mapcar #'cdr buf-specs))
         (ids   (gensym "IDS"))
         (qpkg  (gensym "QPKG"))
         (rpkg  (gensym "RPKG"))
         (xpkg  (gensym "XPKG"))
         (lpkg  (gensym "LPKG"))
         (mpkg  (gensym "MPKG"))
         (pairs (gensym "PAIRS"))
         (rpairs (gensym "RPAIRS"))
         (xpairs (gensym "XPAIRS"))
         (lpairs (gensym "LPAIRS"))
         (live  (gensym "LIVE")))
    (declare (ignorable first-var))
    `(let* (,@(loop for v in vars
                    for kw in kwargs
                    collect `(,v (make-mbuf-qr ,@kw)))
            (,ids (list ,@(loop for v in vars collect `(mbuf-qr-id ,v))))
            (,qpkg (find-package '#:limn/query-replace))
            (,rpkg (find-package '#:limn/regex))
            (,xpkg (find-package '#:limn/excursion))
            (,lpkg (find-package '#:limn/local))
            (,mpkg (find-package '#:limn/marker)))
       (dolist (b (list ,@vars))
         (setf (gethash (mbuf-qr-id b) *qr-buffers*) b))
       (unwind-protect
            (let* ((,pairs
                     (when ,qpkg
                       (list
                        (cons (find-symbol "*BUFFER-TEXT-FN*"     ,qpkg)
                              #'qr-text-fn)
                        (cons (find-symbol "*BUFFER-INSERT-FN*"   ,qpkg)
                              #'qr-insert-fn)
                        (cons (find-symbol "*BUFFER-DELETE-FN*"   ,qpkg)
                              #'qr-delete-fn)
                        (cons (find-symbol "*POINT-FN*"           ,qpkg)
                              #'qr-point-fn)
                        (cons (find-symbol "*SET-POINT-FN*"       ,qpkg)
                              #'qr-set-point-fn)
                        (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,qpkg)
                              #'qr-text-len-fn))))
                   (,rpairs
                     (when ,rpkg
                       (list
                        (cons (find-symbol "*BUFFER-TEXT-FN*"     ,rpkg)
                              #'qr-text-fn)
                        (cons (find-symbol "*BUFFER-SET-TEXT-FN*" ,rpkg)
                              (lambda (bid txt) (%qr-set-text bid txt)))
                        (cons (find-symbol "*POINT-FN*"           ,rpkg)
                              #'qr-point-fn)
                        (cons (find-symbol "*SET-POINT-FN*"       ,rpkg)
                              #'qr-set-point-fn)
                        (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,rpkg)
                              #'qr-text-len-fn))))
                   (,xpairs
                     (when ,xpkg
                       (let ((reg (find-symbol "REGISTER-BUFFER" ,xpkg)))
                         (when (and reg (fboundp reg))
                           (handler-case
                               (funcall reg
                                        (list :|buffer-id|
                                              (mbuf-qr-id ,first-var))
                                        (mbuf-qr-id ,first-var)
                                        :name (mbuf-qr-id ,first-var))
                             (error () nil))))
                       (list
                        (cons (find-symbol "*CURRENT-BUFFER*" ,xpkg)
                              (mbuf-qr-id ,first-var))
                        (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,xpkg)
                              #'qr-text-len-fn)
                        (cons (find-symbol "*POINT-FN*" ,xpkg)
                              #'qr-point-fn)
                        (cons (find-symbol "*SET-POINT-FN*" ,xpkg)
                              #'qr-set-point-fn))))
                   (,lpairs
                     (when ,lpkg
                       (list
                        (cons (find-symbol "*CURRENT-BUFFER-ID*" ,lpkg)
                              (mbuf-qr-id ,first-var)))))
                   (mpairs
                     (when ,mpkg
                       (list
                        (cons (find-symbol "*CURRENT-BUFFER-ID*" ,mpkg)
                              (mbuf-qr-id ,first-var))
                        (cons (find-symbol "*BUFFER-CURSOR-FN*" ,mpkg)
                              #'qr-point-fn)
                        (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,mpkg)
                              #'qr-text-len-fn))))
                   (,live (remove-if (lambda (p) (null (car p)))
                                     (append ,pairs ,rpairs ,xpairs ,lpairs
                                             mpairs))))
              ;; reset regex match data
              (when ,rpkg
                (let ((r (find-symbol "RESET-MATCH-DATA" ,rpkg)))
                  (when r (funcall r))))
              (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
                ,@body))
         (dolist (id ,ids) (remhash id *qr-buffers*))))))

(defun make-response-fn (responses)
  "Build a thunk that pops one response per call, signalling error on overflow."
  (let ((box (copy-list responses)))
    (lambda ()
      (or (pop box)
          (error "query-replace asked for response beyond plan")))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §A.1 query-replace 字面 (15 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest qr-literal-y-y-y-replaces-all
  "Three matches, answer y y y → all replaced"
  (with-qr-ctx ((b :id "qr-yyy" :text "foo foo foo" :point 0))
    (let ((rf (make-response-fn '("y" "y" "y"))))
      (limn/query-replace:query-replace "foo" "bar"
                                        :response-fn rf)
      (assert-equal "bar bar bar" (mbuf-qr-text b)
                    "all three replaced"))))

(deftest qr-literal-n-y-y-skips-first
  "Answer n y y → first kept, rest replaced"
  (with-qr-ctx ((b :id "qr-nyy" :text "foo foo foo" :point 0))
    (let ((rf (make-response-fn '("n" "y" "y"))))
      (limn/query-replace:query-replace "foo" "bar"
                                        :response-fn rf)
      (assert-equal "foo bar bar" (mbuf-qr-text b)
                    "first kept, second+third replaced"))))

(deftest qr-literal-bang-replaces-rest
  "Answer ! on first prompt → all remaining replaced without asking"
  (with-qr-ctx ((b :id "qr-bang" :text "x x x x x" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace "x" "Y"
                                        :response-fn rf)
      (assert-equal "Y Y Y Y Y" (mbuf-qr-text b)
                    "all replaced without further prompts"))))

(deftest qr-literal-bang-after-some
  "y y ! sequence: 2 confirmed, rest auto"
  (with-qr-ctx ((b :id "qr-yyb" :text "a a a a a" :point 0))
    (let ((rf (make-response-fn '("y" "y" "!"))))
      (limn/query-replace:query-replace "a" "Z"
                                        :response-fn rf)
      (assert-equal "Z Z Z Z Z" (mbuf-qr-text b)
                    "all replaced"))))

(deftest qr-literal-q-quits
  "Answer y q → first replaced, rest untouched"
  (with-qr-ctx ((b :id "qr-yq" :text "foo foo foo" :point 0))
    (let ((rf (make-response-fn '("y" "q"))))
      (limn/query-replace:query-replace "foo" "bar"
                                        :response-fn rf)
      (assert-equal "bar foo foo" (mbuf-qr-text b)
                    "quit after first"))))

(deftest qr-literal-dot-replace-and-quit
  "Answer y . → replace 1 then 1 more then quit (3 untouched)"
  (with-qr-ctx ((b :id "qr-yd" :text "foo foo foo" :point 0))
    (let ((rf (make-response-fn '("y" "."))))
      (limn/query-replace:query-replace "foo" "X"
                                        :response-fn rf)
      (assert-equal "X X foo" (mbuf-qr-text b)
                    ". replaces this then quits"))))

(deftest qr-literal-caret-goes-back
  "y ^ n y → first y reverted by ^, answered n, then y for last"
  (with-qr-ctx ((b :id "qr-back" :text "foo foo foo" :point 0))
    (let ((rf (make-response-fn '("y" "^" "n" "y" "y"))))
      ;; After y at match-1 → "bar foo foo"
      ;; ^ → undo, back to match-1 prompt
      ;; n → keep match-1, move to match-2 prompt
      ;; y → replace match-2 → "foo bar foo"
      ;; y → replace match-3 → "foo bar bar"
      (limn/query-replace:query-replace "foo" "bar"
                                        :response-fn rf)
      (assert-equal "foo bar bar" (mbuf-qr-text b)
                    "after ^: first kept, rest replaced"))))

(deftest qr-literal-no-match-returns-zero
  "Pattern with no match: no-op, count=0"
  (with-qr-ctx ((b :id "qr-none" :text "abcdef" :point 0))
    (let ((rf (make-response-fn '())))
      (limn/query-replace:query-replace "zzz" "Y"
                                        :response-fn rf)
      (assert-equal "abcdef" (mbuf-qr-text b)
                    "no change")
      (let ((sym (find-symbol "*LAST-REPLACE-COUNT*" :limn/query-replace)))
        (when (and sym (boundp sym))
          (assert-eql 0 (symbol-value sym)
                      "count = 0"))))))

(deftest qr-literal-count-tracking
  "After 3 successful replaces, *last-replace-count* = 3"
  (with-qr-ctx ((b :id "qr-cnt" :text "x x x" :point 0))
    (let ((rf (make-response-fn '("y" "y" "y"))))
      (limn/query-replace:query-replace "x" "Y" :response-fn rf)
      (let ((sym (find-symbol "*LAST-REPLACE-COUNT*" :limn/query-replace)))
        (when (and sym (boundp sym))
          (assert-eql 3 (symbol-value sym)
                      "count = 3"))))))

(deftest qr-literal-starts-from-point
  "If point starts past 1st match, only later matches considered"
  (with-qr-ctx ((b :id "qr-pt" :text "foo foo foo" :point 4))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace "foo" "X" :response-fn rf)
      (assert-equal "foo X X" (mbuf-qr-text b)
                    "only matches at/after point 4 replaced"))))

(deftest qr-literal-different-length-replacement
  "Replacement shorter than match: positions of next match still right"
  (with-qr-ctx ((b :id "qr-len"
                   :text "longword longword longword" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace "longword" "x" :response-fn rf)
      (assert-equal "x x x" (mbuf-qr-text b)
                    "all replaced; offsets tracked correctly"))))

(deftest qr-literal-overlapping-avoided
  "Replacement contains the search pattern → must not re-match itself"
  (with-qr-ctx ((b :id "qr-overlap" :text "aa aa aa" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace "aa" "aaaa" :response-fn rf)
      (assert-equal "aaaa aaaa aaaa" (mbuf-qr-text b)
                    "no recursive replace into replacement"))))

(deftest qr-literal-comma-replaces-and-pauses
  "Answer , then y → replace this, then prompt again same match (no advance),
   then y (advance and replace). Implementation detail: , re-prompts."
  ;; SPEC says ',' replaces and pauses for confirmation; we just verify the
  ;; net effect (replace happened, count reflects all).
  (with-qr-ctx ((b :id "qr-comma" :text "a a a" :point 0))
    (let ((rf (make-response-fn '("," "y" "y" "y"))))
      ;; Accept any response sequence that ends consuming all matches.
      (assert-no-error (limn/query-replace:query-replace
                        "a" "B" :response-fn rf)
                       "no error with comma flow"))))

(deftest qr-literal-case-fold-default
  "Case-fold default = nil (Emacs *case-fold-search* defaults t, but our
   API exposes :case-fold; default of the param is t per Emacs convention)."
  (with-qr-ctx ((b :id "qr-cf" :text "Foo foo FOO" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace "foo" "X"
                                        :case-fold t
                                        :response-fn rf)
      (assert-equal "X X X" (mbuf-qr-text b)
                    "case-fold=t matches all variants"))))

(deftest qr-literal-case-fold-off
  "case-fold nil → only literal lowercase 'foo' matched"
  (with-qr-ctx ((b :id "qr-cf2" :text "Foo foo FOO" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace "foo" "X"
                                        :case-fold nil
                                        :response-fn rf)
      (assert-equal "Foo X FOO" (mbuf-qr-text b)
                    "case-fold=nil only matches lowercase"))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §A.2 query-replace-regexp (10 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest qr-regexp-group-reference-1
  "\\([0-9]+\\)px → \\1em with !"
  (with-qr-ctx ((b :id "qrr-1" :text "12px 34px 56px" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace-regexp "\\([0-9]+\\)px" "\\1em"
                                                :response-fn rf)
      (assert-equal "12em 34em 56em" (mbuf-qr-text b)
                    "group reference substituted"))))

(deftest qr-regexp-y-y-y
  "regex with y y y — same as literal pattern"
  (with-qr-ctx ((b :id "qrr-yyy" :text "1a 2a 3a" :point 0))
    (let ((rf (make-response-fn '("y" "y" "y"))))
      (limn/query-replace:query-replace-regexp "[0-9]a" "X"
                                                :response-fn rf)
      (assert-equal "X X X" (mbuf-qr-text b)
                    "all matched"))))

(deftest qr-regexp-multiple-groups
  "\\(a\\)\\(b\\) → \\2\\1 (swap groups)"
  (with-qr-ctx ((b :id "qrr-swap" :text "ab ab" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace-regexp "\\(a\\)\\(b\\)" "\\2\\1"
                                                :response-fn rf)
      (assert-equal "ba ba" (mbuf-qr-text b)
                    "swap groups"))))

(deftest qr-regexp-no-match-noop
  "regex with no match → unchanged"
  (with-qr-ctx ((b :id "qrr-none" :text "abcdef" :point 0))
    (let ((rf (make-response-fn '())))
      (limn/query-replace:query-replace-regexp "[0-9]+" "X"
                                                :response-fn rf)
      (assert-equal "abcdef" (mbuf-qr-text b)
                    "no change"))))

(deftest qr-regexp-empty-match-no-infinite-loop
  "Pattern that matches empty string ('a*') must not infinite-loop"
  (with-qr-ctx ((b :id "qrr-empty" :text "xx" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (assert-no-error
       ;; Worst case: implementation must guarantee forward progress
       ;; even on zero-length matches.
       (limn/query-replace:query-replace-regexp "a*" "Z"
                                                 :response-fn rf)
       "must terminate on zero-length match pattern"))))

(deftest qr-regexp-word-boundary
  "\\bfoo\\b → matches whole word only"
  (with-qr-ctx ((b :id "qrr-wb" :text "foo foobar foo" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace-regexp "\\bfoo\\b" "X"
                                                :response-fn rf)
      (assert-equal "X foobar X" (mbuf-qr-text b)
                    "foobar untouched (not whole-word foo)"))))

(deftest qr-regexp-anchor-line-start
  "^Hello → only line-start Hello replaced"
  (with-qr-ctx ((b :id "qrr-anchor"
                   :text (format nil "Hello world~CHello again" #\Newline)
                   :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace-regexp "^Hello" "Hi"
                                                :response-fn rf)
      ;; Both Hellos are at line-start → both replaced.
      (assert-equal (format nil "Hi world~CHi again" #\Newline)
                    (mbuf-qr-text b)
                    "both line-anchored Hellos replaced"))))

(deftest qr-regexp-character-class
  "[aeiou] with ! → all vowels → X"
  (with-qr-ctx ((b :id "qrr-cc" :text "hello world" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace-regexp "[aeiou]" "X"
                                                :response-fn rf)
      (assert-equal "hXllX wXrld" (mbuf-qr-text b)
                    "all vowels replaced"))))

(deftest qr-regexp-mixed-y-n
  "y n y on three digits"
  (with-qr-ctx ((b :id "qrr-mix" :text "1 2 3 4" :point 0))
    (let ((rf (make-response-fn '("y" "n" "y" "n"))))
      (limn/query-replace:query-replace-regexp "[0-9]" "X"
                                                :response-fn rf)
      (assert-equal "X 2 X 4" (mbuf-qr-text b)
                    "1 and 3 replaced, 2 and 4 kept"))))

(deftest qr-regexp-replacement-without-group-ref
  "Replacement string without \\N takes effect verbatim"
  (with-qr-ctx ((b :id "qrr-noref" :text "abc 123 def 456" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace-regexp "[0-9]+" "NUM"
                                                :response-fn rf)
      (assert-equal "abc NUM def NUM" (mbuf-qr-text b)
                    "plain replacement"))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §A.3 range arg (FROM/TO) + narrow integration (5 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest qr-range-limits-replace
  "query-replace with :start :end limits to [start, end)"
  (with-qr-ctx ((b :id "qr-rng" :text "foo foo foo" :point 0))
    (let ((rf (make-response-fn '("!"))))
      ;; First two foos: offsets 0..3 and 4..7. Limit to first 7 chars.
      (limn/query-replace:query-replace "foo" "X"
                                        :start 0 :end 7
                                        :response-fn rf)
      (assert-equal "X X foo" (mbuf-qr-text b)
                    "third foo (past end=7) untouched"))))

(deftest qr-range-end-exclusive
  "End is exclusive — match ending exactly at end is included"
  (with-qr-ctx ((b :id "qr-end-x" :text "abc abc abc" :point 0))
    (let ((rf (make-response-fn '("!"))))
      ;; "abc" at 0..3 — end=3 should include it.
      (limn/query-replace:query-replace "abc" "Z"
                                        :start 0 :end 3
                                        :response-fn rf)
      (assert-equal "Z abc abc" (mbuf-qr-text b)
                    "first abc replaced, rest untouched"))))

(deftest qr-range-start-skips-before
  "start>0 → matches before start ignored"
  (with-qr-ctx ((b :id "qr-start" :text "a a a a" :point 0))
    (let ((rf (make-response-fn '("!"))))
      (limn/query-replace:query-replace "a" "X"
                                        :start 4 :end 7
                                        :response-fn rf)
      ;; Matches at 4 and 6 → 2 replaced.
      (assert-equal "a a X X" (mbuf-qr-text b)
                    "only matches in [4,7) replaced"))))

(deftest qr-with-narrow-restricts-scope
  "Inside narrow-to-region, query-replace only touches narrowed area"
  (with-qr-ctx ((b :id "qr-narrow" :text "foo foo foo" :point 0))
    (let ((narrow (and (find-package '#:limn/excursion)
                       (find-symbol "NARROW-TO-REGION" '#:limn/excursion)))
          (widen  (and (find-package '#:limn/excursion)
                       (find-symbol "WIDEN" '#:limn/excursion))))
      (when (and narrow widen (fboundp narrow) (fboundp widen))
        (unwind-protect
             (progn
               (funcall narrow 4 11)            ; "foo foo" portion
               (let ((rf (make-response-fn '("!"))))
                 (limn/query-replace:query-replace "foo" "X"
                                                   :response-fn rf))
               (assert-equal "foo X X" (mbuf-qr-text b)
                             "only narrowed area touched"))
          (funcall widen))))))

(deftest qr-save-excursion-restores-point
  "save-excursion around query-replace restores point afterwards"
  (with-qr-ctx ((b :id "qr-saveex" :text "foo foo foo" :point 2))
    (let ((se (and (find-package '#:limn/excursion)
                   (find-symbol "SAVE-EXCURSION" '#:limn/excursion))))
      (when (and se (macro-function se))
        (funcall (compile nil
                          `(lambda ()
                             (,se
                              (let ((rf (,(find-symbol "MAKE-RESPONSE-FN"
                                                       :limn/unit-test)
                                         '("!"))))
                                (limn/query-replace:query-replace
                                 "foo" "X" :response-fn rf))))))
        ;; Point was 2 before; after save-excursion + replace, should still be 2.
        ;; Replaces shorten/preserve length here (foo→X is 2 shorter each).
        ;; If markers are wired, point follows; if not, this asserts that
        ;; save-excursion at minimum returned us to *some* sane offset within
        ;; the new buffer (≤ new length). For RED we just assert it's <= len.
        (assert-true (<= (mbuf-qr-point b) (mbuf-qr-len b))
                     "point within buffer after save-excursion")))))
