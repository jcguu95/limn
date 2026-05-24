;;;; v0.34 — Real regex engine (cl-ppcre) + Emacs-style API + Emacs→PCRE
;;;; syntax shim + limn-search.lisp upgrade. RED tests (~100 tests).
;;;;
;;;; 覆蓋（SPEC §v0.34 A–D）：
;;;;   §A vendor : cl-ppcre 已 load、package 跟 symbols 可解析
;;;;   §B API    : Emacs-style 函式（re-search-forward/backward、looking-at、
;;;;              looking-back、re-search-in-buffer、replace-match、
;;;;              string-match、replace-regexp-in-string、split-string、
;;;;              match-string、match-beginning、match-end、match-data、
;;;;              set-match-data）回傳值與 Emacs 對齊
;;;;   §C shim   : emacs-regex-to-pcre 把 Emacs syntax 翻成 PCRE
;;;;              （\\(...\\) / \\| / \\b / \\< / \\> / \\sw / \\s- / \\` / \\'）
;;;;   §D 升級   : limn/search:find-matches 在 :regex t 模式底層改用 cl-ppcre，
;;;;              支援 :emacs-syntax flag，舊介面 backward-compatible
;;;;
;;;; 依賴：v0.32 *current-buffer*（re-search-forward 吃當前 buffer）+
;;;;       v0.30 markers（match data 內部可用 marker 鎖 buffer，但 v0.34 先
;;;;       用 plain integer offset，marker 整合 v0.36 query-replace 再做）。
;;;;
;;;; 全部 RED — 在 limn-regex.lisp 實作前都會 fail。

;; ── package stub ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/regex)
    (make-package '#:limn/regex :use '(#:cl)))
  (dolist (sym '(;; §B Emacs-style API
                 "RE-SEARCH-FORWARD"
                 "RE-SEARCH-BACKWARD"
                 "RE-SEARCH-IN-BUFFER"
                 "LOOKING-AT"
                 "LOOKING-BACK"
                 "REPLACE-MATCH"
                 "STRING-MATCH"
                 "REPLACE-REGEXP-IN-STRING"
                 "SPLIT-STRING"
                 "MATCH-STRING"
                 "MATCH-BEGINNING"
                 "MATCH-END"
                 "MATCH-DATA"
                 "SET-MATCH-DATA"
                 "SEARCH-FAILED"
                 ;; §C syntax shim
                 "EMACS-REGEX-TO-PCRE"
                 ;; vtable hooks (mock wires here for dependency injection)
                 "*BUFFER-TEXT-FN*"
                 "*BUFFER-SET-TEXT-FN*"
                 "*POINT-FN*"
                 "*SET-POINT-FN*"
                 "*BUFFER-TEXT-LEN-FN*"
                 ;; test helpers
                 "RESET-MATCH-DATA"))
    (export (intern sym '#:limn/regex) '#:limn/regex)))

(in-package #:limn/unit-test)

;;; ── mock buffer infrastructure ────────────────────────────────────────────
;;;
;;; v0.34 needs: full buffer text retrieval, point r/w, length.
;;; We keep this independent of v0.32 mmbuf32 to avoid cross-test coupling.

(defstruct (mbuf34
             (:conc-name mbuf34-)
             (:constructor make-mbuf34 (&key (id "rb") (text "") (point 0))))
  id
  (text "" :type string)
  (point 0 :type integer))

(defun mbuf34-len (b) (length (mbuf34-text b)))

(defvar *r34-buffers* (make-hash-table :test 'equal))

(defun mbuf34-get (bid) (gethash bid *r34-buffers*))

;;; Vtable adapters.
(defun r34-text-fn (bid)
  (let ((b (mbuf34-get bid))) (if b (mbuf34-text b) "")))

(defun r34-set-text-fn (bid text)
  (let ((b (mbuf34-get bid)))
    (when b (setf (mbuf34-text b) text))))

(defun r34-point-fn (bid)
  (let ((b (mbuf34-get bid))) (if b (mbuf34-point b) 0)))

(defun r34-set-point-fn (bid off)
  (let ((b (mbuf34-get bid)))
    (when b (setf (mbuf34-point b) off))))

(defun r34-text-len-fn (bid)
  (let ((b (mbuf34-get bid))) (if b (mbuf34-len b) 0)))

;;; with-r34-ctx — register one or more mock buffers, wire vtable, bind
;;; *current-buffer* (v0.32 dyn var) to first buffer's id (if v0.32 loaded).

(defmacro with-r34-ctx ((&rest buf-specs) &body body)
  "Each BUF-SPEC: (VAR &key id text point).
   Inside BODY, limn/regex vtable is wired to mock; first buf is
   *current-buffer*."
  (let* ((first-spec (car buf-specs))
         (first-var (car first-spec))
         (vars  (mapcar #'car buf-specs))
         (kwargs (mapcar #'cdr buf-specs))
         (ids   (gensym "IDS"))
         (rpkg  (gensym "RPKG"))
         (xpkg  (gensym "XPKG"))
         (pairs (gensym "PAIRS"))
         (live  (gensym "LIVE")))
    (declare (ignorable first-var))
    `(let* (,@(loop for v in vars
                    for kw in kwargs
                    collect `(,v (make-mbuf34 ,@kw)))
            (,ids (list ,@(loop for v in vars collect `(mbuf34-id ,v))))
            (,rpkg (find-package '#:limn/regex))
            (,xpkg (find-package '#:limn/excursion)))
       (dolist (b (list ,@vars))
         (setf (gethash (mbuf34-id b) *r34-buffers*) b))
       (unwind-protect
            (let* ((,pairs
                     (when ,rpkg
                       (list
                        (cons (find-symbol "*BUFFER-TEXT-FN*"     ,rpkg)
                              #'r34-text-fn)
                        (cons (find-symbol "*BUFFER-SET-TEXT-FN*" ,rpkg)
                              #'r34-set-text-fn)
                        (cons (find-symbol "*POINT-FN*"           ,rpkg)
                              #'r34-point-fn)
                        (cons (find-symbol "*SET-POINT-FN*"       ,rpkg)
                              #'r34-set-point-fn)
                        (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,rpkg)
                              #'r34-text-len-fn))))
                   (xpairs
                     (when ,xpkg
                       (list
                        (cons (find-symbol "*CURRENT-BUFFER*" ,xpkg)
                              (mbuf34-id ,first-var)))))
                   (,live (remove-if (lambda (p) (null (car p)))
                                     (append ,pairs xpairs))))
              ;; reset match-data so each test starts clean
              (when ,rpkg
                (let ((r (find-symbol "RESET-MATCH-DATA" ,rpkg)))
                  (when r (funcall r))))
              (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
                ,@body))
         (dolist (id ,ids) (remhash id *r34-buffers*))))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §A. Vendor cl-ppcre (5 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest regex-a-vendor-cl-ppcre-package-loaded
  "cl-ppcre package must be loaded by run-unit.lisp before tests run."
  (assert-true (find-package '#:cl-ppcre)
               "package :cl-ppcre exists"))

(deftest regex-a-vendor-scan-symbol-fbound
  "CL-PPCRE:SCAN is a callable function symbol."
  (let ((sym (and (find-package '#:cl-ppcre)
                  (find-symbol "SCAN" '#:cl-ppcre))))
    (assert-true (and sym (fboundp sym))
                 "cl-ppcre:scan is fbound")))

(deftest regex-a-vendor-all-matches-symbol-fbound
  "CL-PPCRE:ALL-MATCHES is callable."
  (let ((sym (and (find-package '#:cl-ppcre)
                  (find-symbol "ALL-MATCHES" '#:cl-ppcre))))
    (assert-true (and sym (fboundp sym))
                 "cl-ppcre:all-matches is fbound")))

(deftest regex-a-vendor-scan-finds-literal
  "Smoke: cl-ppcre:scan finds a literal substring."
  (let ((scan (and (find-package '#:cl-ppcre)
                   (find-symbol "SCAN" '#:cl-ppcre))))
    (when (and scan (fboundp scan))
      (multiple-value-bind (s e) (funcall scan "bcd" "abcdef")
        (assert-eql 1 s "scan finds 'bcd' at offset 1")
        (assert-eql 4 e "scan end offset = 4")))))

(deftest regex-a-vendor-scan-character-class
  "Smoke: cl-ppcre:scan with PCRE character class."
  (let ((scan (and (find-package '#:cl-ppcre)
                   (find-symbol "SCAN" '#:cl-ppcre))))
    (when (and scan (fboundp scan))
      (let ((s (funcall scan "[aeiou]" "xyz aiu")))
        (assert-true (integerp s) "scan returns integer start")))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §B. Emacs-style API
;;; ─────────────────────────────────────────────────────────────────────────

;;; ── §B.1 string-match (8 tests) ───────────────────────────────────────────

(deftest regex-b-string-match-literal
  "string-match on literal pattern returns starting position."
  (assert-eql 2 (limn/regex:string-match "cd" "abcdef")
              "literal 'cd' at offset 2"))

(deftest regex-b-string-match-no-match
  "string-match returns nil when no match."
  (assert-eq nil (limn/regex:string-match "zz" "abcdef")
             "no 'zz' → nil"))

(deftest regex-b-string-match-at-start
  "string-match at position 0 returns 0 (not nil)."
  (assert-eql 0 (limn/regex:string-match "abc" "abcdef")
              "match at start = 0"))

(deftest regex-b-string-match-with-start
  "string-match with START parameter starts the search at START."
  (assert-eql 4 (limn/regex:string-match "ab" "abxxabxx" 2)
              "second 'ab' at offset 4"))

(deftest regex-b-string-match-case-sensitive-default
  "string-match is case-sensitive by default (mirrors Emacs default)."
  (assert-eq nil (limn/regex:string-match "ABC" "abcdef")
             "uppercase ABC doesn't match lowercase"))

(deftest regex-b-string-match-character-class
  "string-match with PCRE character class."
  (assert-true (integerp (limn/regex:string-match "[aeiou]" "xyz aiu"))
               "vowel class matches"))

(deftest regex-b-string-match-anchors
  "string-match respects ^ and $."
  (assert-eql 0 (limn/regex:string-match "^abc" "abcdef")
              "^abc at line start = 0")
  (assert-eq nil (limn/regex:string-match "^abc" "xabcdef")
             "^abc on non-anchored line → nil"))

(deftest regex-b-string-match-sets-match-data
  "string-match sets match-data such that match-string 0 returns the match."
  (limn/regex:string-match "b.d" "abcdef")
  (assert-equal "bcd" (limn/regex:match-string 0)
                "match-string 0 after string-match"))

;;; ── §B.2 match-string (6 tests) ───────────────────────────────────────────

(deftest regex-b-match-string-group-0-whole-match
  "match-string 0 returns the whole match."
  (limn/regex:string-match "b\\(c.\\)e" "abcdef")
  (assert-equal "bcde" (limn/regex:match-string 0)
                "whole match"))

(deftest regex-b-match-string-group-1-first-capture
  "match-string 1 returns the first capture group."
  (limn/regex:string-match "b\\(c.\\)e" "abcdef")
  (assert-equal "cd" (limn/regex:match-string 1)
                "group 1"))

(deftest regex-b-match-string-group-2-nested
  "match-string 2 returns the second (sibling) capture."
  (limn/regex:string-match "\\(a\\)\\(b\\)\\(c\\)" "abcdef")
  (assert-equal "b" (limn/regex:match-string 2)
                "group 2"))

(deftest regex-b-match-string-nonexistent-group-nil
  "match-string N for N > group count returns nil."
  (limn/regex:string-match "\\(a\\)" "abc")
  (assert-eq nil (limn/regex:match-string 99)
             "group 99 → nil"))

(deftest regex-b-match-string-with-string-argument
  "match-string accepts explicit STRING to slice from."
  (let ((s "abcdef"))
    (limn/regex:string-match "cd" s)
    (assert-equal "cd" (limn/regex:match-string 0 s)
                  "explicit string arg")))

(deftest regex-b-match-string-before-any-match-nil
  "match-string before any match has been performed returns nil."
  (let ((data (limn/regex:match-data)))
    (limn/regex:set-match-data nil)
    (unwind-protect
         (assert-eq nil (limn/regex:match-string 0)
                    "no match-data → nil")
      (limn/regex:set-match-data data))))

;;; ── §B.3 match-beginning / match-end (6 tests) ────────────────────────────

(deftest regex-b-match-beginning-group-0
  "match-beginning 0 returns the start of the whole match."
  (limn/regex:string-match "cd" "abcdef")
  (assert-eql 2 (limn/regex:match-beginning 0) "starts at 2"))

(deftest regex-b-match-end-group-0
  "match-end 0 returns the end (exclusive) of the whole match."
  (limn/regex:string-match "cd" "abcdef")
  (assert-eql 4 (limn/regex:match-end 0) "ends at 4"))

(deftest regex-b-match-beginning-group-1
  "match-beginning 1 returns the start of capture group 1."
  (limn/regex:string-match "b\\(c.\\)e" "abcdef")
  (assert-eql 2 (limn/regex:match-beginning 1) "group 1 starts at 2"))

(deftest regex-b-match-end-group-1
  "match-end 1 returns the end of capture group 1."
  (limn/regex:string-match "b\\(c.\\)e" "abcdef")
  (assert-eql 4 (limn/regex:match-end 1) "group 1 ends at 4"))

(deftest regex-b-match-beginning-nonexistent-nil
  "match-beginning for non-matching/missing group returns nil."
  (limn/regex:string-match "\\(a\\)" "abc")
  (assert-eq nil (limn/regex:match-beginning 99) "missing group → nil"))

(deftest regex-b-match-end-ge-beginning
  "match-end is always >= match-beginning."
  (limn/regex:string-match "b.d" "abcdef")
  (assert-true (>= (limn/regex:match-end 0)
                   (limn/regex:match-beginning 0))
               "end >= beginning"))

;;; ── §B.4 match-data / set-match-data (4 tests) ────────────────────────────

(deftest regex-b-match-data-returns-list
  "match-data returns a list (positions as integers, alternating start/end)."
  (limn/regex:string-match "cd" "abcdef")
  (let ((d (limn/regex:match-data)))
    (assert-true (listp d) "match-data is list")
    (assert-true (every #'(lambda (x) (or (null x) (integerp x))) d)
                 "positions are integers (or nil for missing groups)")))

(deftest regex-b-match-data-roundtrip
  "set-match-data round-trips via match-data."
  (limn/regex:string-match "cd" "abcdef")
  (let ((saved (limn/regex:match-data)))
    (limn/regex:string-match "ef" "abcdef")
    (limn/regex:set-match-data saved)
    (assert-equal 2 (limn/regex:match-beginning 0)
                  "after restore: beginning = 2 (the 'cd' match)")))

(deftest regex-b-match-data-integers-form
  "match-data with INTEGERS arg returns plain integers (no markers)."
  (limn/regex:string-match "cd" "abcdef")
  (let ((d (limn/regex:match-data t)))
    (assert-true (every #'(lambda (x) (or (null x) (integerp x))) d)
                 "integers form")))

(deftest regex-b-match-data-after-no-match
  "match-data after a failed string-match: positions are nil or empty."
  (limn/regex:string-match "cd" "abcdef")
  (limn/regex:string-match "zzzz" "abcdef")
  (let ((b (limn/regex:match-beginning 0)))
    (assert-true (or (null b) (not (numberp b)))
                 "no-match leaves match-beginning nil/invalid")))

;;; ── §B.5 re-search-forward (12 tests) ─────────────────────────────────────

(deftest regex-b-re-search-forward-returns-point
  "re-search-forward returns the position of match end."
  (with-r34-ctx ((b :id "rf1" :text "hello world" :point 0))
    (assert-eql 5 (limn/regex:re-search-forward "hello")
                "after matching 'hello' returns position 5")))

(deftest regex-b-re-search-forward-moves-point
  "re-search-forward moves *current-buffer* point to match end."
  (with-r34-ctx ((b :id "rf2" :text "hello world" :point 0))
    (limn/regex:re-search-forward "hello")
    (assert-eql 5 (mbuf34-point b) "point moved to 5")))

(deftest regex-b-re-search-forward-not-found-signals
  "re-search-forward with NOERROR=nil signals search-failed when not found."
  (with-r34-ctx ((b :id "rf3" :text "abc" :point 0))
    (assert-error error (limn/regex:re-search-forward "zzz")
                  "search-failed signalled")))

(deftest regex-b-re-search-forward-noerror-t-returns-nil
  "re-search-forward with NOERROR=t returns nil instead of signaling."
  (with-r34-ctx ((b :id "rf4" :text "abc" :point 0))
    (assert-eq nil (limn/regex:re-search-forward "zzz" nil t)
               "NOERROR=t → nil")))

(deftest regex-b-re-search-forward-noerror-t-point-unchanged
  "re-search-forward with NOERROR=t leaves point unchanged on miss."
  (with-r34-ctx ((b :id "rf5" :text "abc" :point 1))
    (limn/regex:re-search-forward "zzz" nil t)
    (assert-eql 1 (mbuf34-point b) "point still at 1")))

(deftest regex-b-re-search-forward-noerror-limit-returns-nil
  "re-search-forward with NOERROR='limit (other) returns nil, point unchanged."
  (with-r34-ctx ((b :id "rf6" :text "abc" :point 1))
    (let ((rv (limn/regex:re-search-forward "zzz" nil 'limit)))
      (assert-eq nil rv "returns nil")
      (assert-eql 1 (mbuf34-point b) "point unchanged"))))

(deftest regex-b-re-search-forward-bound-limits-range
  "BOUND limits how far re-search-forward will scan."
  (with-r34-ctx ((b :id "rf7" :text "abc def ghi" :point 0))
    (assert-eq nil (limn/regex:re-search-forward "ghi" 5 t)
               "BOUND=5 → 'ghi' (at 8) not found")))

(deftest regex-b-re-search-forward-bound-inclusive
  "BOUND set to match-end allows that match."
  (with-r34-ctx ((b :id "rf8" :text "abc def ghi" :point 0))
    (assert-eql 3 (limn/regex:re-search-forward "abc" 3 t)
                "BOUND=3 allows match ending at 3")))

(deftest regex-b-re-search-forward-count-multiple
  "COUNT > 1 advances past multiple matches."
  (with-r34-ctx ((b :id "rf9" :text "aa aa aa" :point 0))
    (let ((rv (limn/regex:re-search-forward "aa" nil t 2)))
      (assert-true (and (integerp rv) (>= rv 5))
                   "after 2 matches point past second 'aa'"))))

(deftest regex-b-re-search-forward-emacs-syntax-default
  "re-search-forward uses Emacs syntax by default: \\(group\\)."
  (with-r34-ctx ((b :id "rfa" :text "abc123" :point 0))
    (limn/regex:re-search-forward "\\([0-9]+\\)")
    (assert-equal "123" (limn/regex:match-string 1)
                  "Emacs \\(...\\) captures '123'")))

(deftest regex-b-re-search-forward-word-boundary
  "\\b word boundary works."
  (with-r34-ctx ((b :id "rfb" :text "foo barbaz qux" :point 0))
    (let ((rv (limn/regex:re-search-forward "\\bbar\\b" nil t)))
      ;; "barbaz" has 'bar' at start of word but not end → shouldn't match
      ;; "bar" as a whole word; depending on Emacs semantics, this should miss.
      (assert-eq nil rv "\\bbar\\b doesn't match inside 'barbaz'"))))

(deftest regex-b-re-search-forward-starts-from-point
  "re-search-forward starts from current point, skipping earlier matches."
  (with-r34-ctx ((b :id "rfc" :text "aa bb aa" :point 3))
    (let ((rv (limn/regex:re-search-forward "aa")))
      (assert-eql 8 rv "skips first 'aa' (before point), matches second"))))

(deftest regex-b-re-search-forward-sets-match-data
  "re-search-forward sets match-data on success."
  (with-r34-ctx ((b :id "rfd" :text "hello" :point 0))
    (limn/regex:re-search-forward "ll")
    (assert-eql 2 (limn/regex:match-beginning 0)
                "match-beginning after re-search-forward")))

;;; ── §B.6 re-search-backward (6 tests) ─────────────────────────────────────

(deftest regex-b-re-search-backward-moves-to-match-start
  "re-search-backward moves point to start of match."
  (with-r34-ctx ((b :id "rb1" :text "hello world" :point 11))
    (limn/regex:re-search-backward "world")
    (assert-eql 6 (mbuf34-point b) "point moved to start of 'world'")))

(deftest regex-b-re-search-backward-not-found-signals
  "re-search-backward with NOERROR=nil signals search-failed."
  (with-r34-ctx ((b :id "rb2" :text "abc" :point 3))
    (assert-error error (limn/regex:re-search-backward "zzz")
                  "search-failed")))

(deftest regex-b-re-search-backward-noerror-t-returns-nil
  "NOERROR=t returns nil instead of signaling."
  (with-r34-ctx ((b :id "rb3" :text "abc" :point 3))
    (assert-eq nil (limn/regex:re-search-backward "zzz" nil t)
               "NOERROR=t → nil")))

(deftest regex-b-re-search-backward-from-point
  "Backward search starts from current point, finds match before it."
  (with-r34-ctx ((b :id "rb4" :text "aa bb aa" :point 5))
    (limn/regex:re-search-backward "aa")
    (assert-eql 0 (mbuf34-point b)
                "found first 'aa' (the one before point)")))

(deftest regex-b-re-search-backward-bound-lower-limit
  "BOUND on backward search is the lower scan limit; matches starting
   before BOUND are rejected."
  (with-r34-ctx ((b :id "rb5" :text "aa bb cc" :point 8))
    (assert-eq nil (limn/regex:re-search-backward "aa" 4 t)
               "with BOUND=4, 'aa' at offset 0 unreachable")))

(deftest regex-b-re-search-backward-emacs-syntax
  "Backward search honors Emacs syntax \\(group\\)."
  (with-r34-ctx ((b :id "rb6" :text "x123 y456" :point 9))
    (limn/regex:re-search-backward "\\([0-9]+\\)")
    (assert-equal "456" (limn/regex:match-string 1)
                  "last group of digits before point")))

;;; ── §B.7 looking-at (4 tests) ─────────────────────────────────────────────

(deftest regex-b-looking-at-true-at-point
  "looking-at returns t when REGEX matches starting at point."
  (with-r34-ctx ((b :id "la1" :text "hello world" :point 6))
    (assert-true (limn/regex:looking-at "world")
                 "looking-at 'world' at point 6")))

(deftest regex-b-looking-at-false-when-no-match
  "looking-at returns nil when REGEX doesn't match at point."
  (with-r34-ctx ((b :id "la2" :text "hello world" :point 6))
    (assert-eq nil (limn/regex:looking-at "hello")
               "looking-at 'hello' at point 6 (not 'world')")))

(deftest regex-b-looking-at-does-not-move-point
  "looking-at must not move point."
  (with-r34-ctx ((b :id "la3" :text "hello world" :point 6))
    (limn/regex:looking-at "world")
    (assert-eql 6 (mbuf34-point b) "point unchanged")))

(deftest regex-b-looking-at-sets-match-data
  "looking-at sets match-data on success."
  (with-r34-ctx ((b :id "la4" :text "hello world" :point 6))
    (limn/regex:looking-at "wor\\(ld\\)")
    (assert-equal "ld" (limn/regex:match-string 1)
                  "looking-at captures group")))

;;; ── §B.8 looking-back (4 tests) ───────────────────────────────────────────

(deftest regex-b-looking-back-true-when-match
  "looking-back returns t when REGEX matches text ending at point."
  (with-r34-ctx ((b :id "lb1" :text "hello world" :point 5))
    (assert-true (limn/regex:looking-back "hello")
                 "looking-back 'hello' at point 5")))

(deftest regex-b-looking-back-false-when-no-match
  "looking-back returns nil when REGEX doesn't end at point."
  (with-r34-ctx ((b :id "lb2" :text "hello world" :point 5))
    (assert-eq nil (limn/regex:looking-back "world")
               "looking-back 'world' at point 5 (no 'world' before)")))

(deftest regex-b-looking-back-respects-limit
  "looking-back with LIMIT does not scan before LIMIT."
  (with-r34-ctx ((b :id "lb3" :text "hello world" :point 5))
    (assert-eq nil (limn/regex:looking-back "hello" 3)
               "limit=3 prevents matching 'hello' starting at 0")))

(deftest regex-b-looking-back-does-not-move-point
  "looking-back must not move point."
  (with-r34-ctx ((b :id "lb4" :text "hello world" :point 5))
    (limn/regex:looking-back "hello")
    (assert-eql 5 (mbuf34-point b) "point unchanged")))

;;; ── §B.9 re-search-in-buffer (3 tests) ────────────────────────────────────

(deftest regex-b-re-search-in-buffer-explicit
  "re-search-in-buffer takes explicit BUF-ID."
  (with-r34-ctx ((b1 :id "rib1-A" :text "alpha")
                 (b2 :id "rib1-B" :text "beta gamma" :point 0))
    (let ((rv (limn/regex:re-search-in-buffer "gamma" "rib1-B")))
      (assert-true (and (integerp rv) (>= rv 10))
                   "found 'gamma' in explicit buffer rib1-B"))))

(deftest regex-b-re-search-in-buffer-keeps-current
  "re-search-in-buffer doesn't change *current-buffer*."
  (with-r34-ctx ((b1 :id "rib2-A" :text "alpha")
                 (b2 :id "rib2-B" :text "beta"))
    (limn/regex:re-search-in-buffer "beta" "rib2-B")
    (when (find-package '#:limn/excursion)
      (let ((cid (funcall (find-symbol "CURRENT-BUFFER-ID" '#:limn/excursion))))
        (assert-equal "rib2-A" cid
                      "current-buffer-id unchanged after re-search-in-buffer")))))

(deftest regex-b-re-search-in-buffer-non-current
  "re-search-in-buffer can find in a non-current buffer without switching."
  (with-r34-ctx ((b1 :id "rib3-A" :text "x")
                 (b2 :id "rib3-B" :text "needle in haystack"))
    (let ((rv (limn/regex:re-search-in-buffer "needle" "rib3-B")))
      (assert-true (integerp rv) "found in non-current"))))

;;; ── §B.10 replace-match (4 tests) ─────────────────────────────────────────

(deftest regex-b-replace-match-basic
  "replace-match replaces the most recent match in *current-buffer*."
  (with-r34-ctx ((b :id "rm1" :text "hello world" :point 0))
    (limn/regex:re-search-forward "hello")
    (limn/regex:replace-match "HI")
    (assert-equal "HI world" (mbuf34-text b)
                  "match replaced in-place")))

(deftest regex-b-replace-match-group-reference
  "replace-match with \\1 substitutes the first capture group."
  (with-r34-ctx ((b :id "rm2" :text "name=Alice" :point 0))
    (limn/regex:re-search-forward "name=\\(\\w+\\)")
    (limn/regex:replace-match "user(\\1)")
    (assert-equal "user(Alice)" (mbuf34-text b)
                  "\\1 substituted")))

(deftest regex-b-replace-match-fixedcase
  "FIXEDCASE=t prevents case folding of the replacement."
  (with-r34-ctx ((b :id "rm3" :text "FOO" :point 0))
    (limn/regex:re-search-forward "FOO")
    (limn/regex:replace-match "bar" t)
    (assert-equal "bar" (mbuf34-text b)
                  "FIXEDCASE=t: replacement used verbatim")))

(deftest regex-b-replace-match-literal
  "LITERAL=t treats replacement string literally — no \\N interpretation."
  (with-r34-ctx ((b :id "rm4" :text "name=Alice" :point 0))
    (limn/regex:re-search-forward "name=\\(\\w+\\)")
    (limn/regex:replace-match "\\1 raw" nil t)
    (assert-equal "\\1 raw" (mbuf34-text b)
                  "LITERAL=t: \\1 kept literal")))

;;; ── §B.11 replace-regexp-in-string (3 tests) ──────────────────────────────

(deftest regex-b-replace-regexp-in-string-all
  "Replaces all non-overlapping matches."
  (assert-equal "X_X_X"
                (limn/regex:replace-regexp-in-string "[0-9]+" "X" "1_22_333")
                "all numeric runs → X"))

(deftest regex-b-replace-regexp-in-string-group-ref
  "\\1 in replacement refers to first capture."
  (assert-equal "[Alice] [Bob]"
                (limn/regex:replace-regexp-in-string
                 "\\(\\w+\\)" "[\\1]" "Alice Bob")
                "\\1 in replacement substitutes the captured word"))

(deftest regex-b-replace-regexp-in-string-no-match
  "When pattern doesn't match, returns original string unchanged."
  (assert-equal "abcdef"
                (limn/regex:replace-regexp-in-string "zz+" "X" "abcdef")
                "no match: unchanged"))

;;; ── §B.12 split-string (4 tests) ──────────────────────────────────────────

(deftest regex-b-split-string-default-whitespace
  "Default split on whitespace, OMIT-NULLS defaults to nil but Emacs trims."
  (let ((parts (limn/regex:split-string "  foo bar  baz")))
    (assert-true (member "foo" parts :test #'string=)
                 "contains 'foo'")
    (assert-true (member "bar" parts :test #'string=)
                 "contains 'bar'")
    (assert-true (member "baz" parts :test #'string=)
                 "contains 'baz'")))

(deftest regex-b-split-string-custom-separator
  "Custom SEPARATOR-REGEX."
  (let ((parts (limn/regex:split-string "a,b,c" ",")))
    (assert-equal '("a" "b" "c") parts
                  "comma-split")))

(deftest regex-b-split-string-omit-nulls-t
  "OMIT-NULLS t drops empty strings between adjacent separators."
  (let ((parts (limn/regex:split-string "a,,b" "," t)))
    (assert-equal '("a" "b") parts
                  "empty middle dropped")))

(deftest regex-b-split-string-omit-nulls-nil
  "OMIT-NULLS nil preserves empty strings."
  (let ((parts (limn/regex:split-string "a,,b" "," nil)))
    (assert-true (member "" parts :test #'string=)
                 "empty middle preserved")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §C. Emacs regex syntax shim (emacs-regex-to-pcre)
;;; ─────────────────────────────────────────────────────────────────────────

;;; ── §C.1 group syntax (5 tests) ───────────────────────────────────────────

(deftest regex-c-group-paren
  "\\(...\\) → (...)"
  (assert-equal "(abc)"
                (limn/regex:emacs-regex-to-pcre "\\(abc\\)")
                "capturing group"))

(deftest regex-c-group-non-capturing
  "\\(?:...\\) → (?:...)"
  (assert-equal "(?:abc)"
                (limn/regex:emacs-regex-to-pcre "\\(?:abc\\)")
                "non-capturing group"))

(deftest regex-c-group-nested
  "Nested \\(\\(...\\)\\) → ((...))"
  (assert-equal "((ab))"
                (limn/regex:emacs-regex-to-pcre "\\(\\(ab\\)\\)")
                "nested groups"))

(deftest regex-c-alternation
  "\\| → |"
  (assert-equal "a|b"
                (limn/regex:emacs-regex-to-pcre "a\\|b")
                "alternation"))

(deftest regex-c-literal-parens-preserved
  "Literal ( and ) in Emacs become escaped \\( \\) in PCRE."
  (let ((out (limn/regex:emacs-regex-to-pcre "(a)")))
    ;; In Emacs, bare ( and ) are literal; in PCRE they're metacharacters.
    ;; The shim must escape them.
    (assert-true (or (search "\\(" out) (search "\\(" out))
                 "literal ( preserved (escaped in PCRE)")))

;;; ── §C.2 word boundary (5 tests) ──────────────────────────────────────────

(deftest regex-c-word-boundary
  "\\b → \\b (lowercase b means word boundary in both)"
  (let ((out (limn/regex:emacs-regex-to-pcre "\\bfoo\\b")))
    (assert-true (and (search "\\b" out)
                      (search "foo" out))
                 "translated \\b preserved")))

(deftest regex-c-non-word-boundary
  "\\B → \\B"
  (let ((out (limn/regex:emacs-regex-to-pcre "\\Bfoo\\B")))
    (assert-true (search "\\B" out)
                 "translated \\B preserved")))

(deftest regex-c-word-start
  "\\< → word-start anchor (PCRE: \\b plus left-context check; shim may use \\b)"
  (let ((out (limn/regex:emacs-regex-to-pcre "\\<foo")))
    (assert-true (or (search "\\b" out) (search "(?<![A-Za-z0-9_])" out))
                 "\\< translated to word-start equivalent")))

(deftest regex-c-word-end
  "\\> → word-end anchor"
  (let ((out (limn/regex:emacs-regex-to-pcre "foo\\>")))
    (assert-true (or (search "\\b" out) (search "(?![A-Za-z0-9_])" out))
                 "\\> translated to word-end equivalent")))

(deftest regex-c-multiple-boundaries
  "Multiple word boundary markers in same pattern."
  (let ((out (limn/regex:emacs-regex-to-pcre "\\<foo\\>\\|\\<bar\\>")))
    (assert-true (search "|" out)
                 "alternation between two word-bounded patterns")))

;;; ── §C.3 character classes (6 tests) ──────────────────────────────────────

(deftest regex-c-word-class
  "\\w → \\w"
  (assert-equal "\\w+"
                (limn/regex:emacs-regex-to-pcre "\\w+")
                "word constituent class"))

(deftest regex-c-non-word-class
  "\\W → \\W"
  (assert-equal "\\W+"
                (limn/regex:emacs-regex-to-pcre "\\W+")
                "non-word class"))

(deftest regex-c-syntax-whitespace
  "\\s- → whitespace (Emacs syntax-class 'whitespace')."
  (let ((out (limn/regex:emacs-regex-to-pcre "\\s-+")))
    (assert-true (or (search "\\s" out) (search "[ \\t\\n]" out))
                 "\\s- → whitespace class")))

(deftest regex-c-syntax-word
  "\\sw → word constituent (Emacs syntax-class 'word')."
  (let ((out (limn/regex:emacs-regex-to-pcre "\\sw+")))
    (assert-true (or (search "\\w" out) (search "[A-Za-z0-9_]" out))
                 "\\sw → word class")))

(deftest regex-c-syntax-punctuation
  "\\s. → punctuation (Emacs syntax-class 'punct'); may map to PCRE \\p{P} or [[:punct:]]."
  (let ((out (limn/regex:emacs-regex-to-pcre "\\s.")))
    (assert-true (stringp out)
                 "\\s. translates to something (impl decides exact mapping)")))

(deftest regex-c-digit-class-emacs-extension
  "[0-9] preserved verbatim through shim."
  (assert-equal "[0-9]+"
                (limn/regex:emacs-regex-to-pcre "[0-9]+")
                "char class unchanged"))

;;; ── §C.4 buffer anchors (3 tests) ─────────────────────────────────────────

(deftest regex-c-buffer-start-anchor
  "\\` → \\A (buffer/string start in PCRE)"
  (let ((out (limn/regex:emacs-regex-to-pcre "\\`foo")))
    (assert-true (or (search "\\A" out) (search "^" out))
                 "\\` → \\A or ^")))

(deftest regex-c-buffer-end-anchor
  "\\' → \\z (buffer/string end in PCRE)"
  (let ((out (limn/regex:emacs-regex-to-pcre "foo\\'")))
    (assert-true (or (search "\\z" out) (search "\\Z" out) (search "$" out))
                 "\\' → \\z or \\Z or $")))

(deftest regex-c-line-anchors-unchanged
  "^ and $ pass through unchanged (Emacs and PCRE agree on these)."
  (assert-equal "^foo$"
                (limn/regex:emacs-regex-to-pcre "^foo$")
                "^/$ passthrough"))

;;; ── §C.5 edge cases (11 tests) ────────────────────────────────────────────

(deftest regex-c-empty-pattern
  "Empty pattern → empty PCRE."
  (assert-equal ""
                (limn/regex:emacs-regex-to-pcre "")
                "empty in / empty out"))

(deftest regex-c-pure-literal
  "Pure literal (no escapes, no metachars) passes through."
  (assert-equal "hello"
                (limn/regex:emacs-regex-to-pcre "hello")
                "literal text"))

(deftest regex-c-double-backslash
  "\\\\ in Emacs regex → literal backslash → \\\\ in PCRE."
  (let ((out (limn/regex:emacs-regex-to-pcre "\\\\")))
    (assert-equal "\\\\" out
                  "literal backslash preserved")))

(deftest regex-c-literal-dot-escape
  "Escaped dot \\. stays escaped → \\."
  (assert-equal "\\."
                (limn/regex:emacs-regex-to-pcre "\\.")
                "\\. preserved"))

(deftest regex-c-literal-question
  "\\? → \\? (literal question mark in both)."
  (assert-equal "\\?"
                (limn/regex:emacs-regex-to-pcre "\\?")
                "\\? preserved"))

(deftest regex-c-literal-star
  "\\* → \\* (literal star)."
  (assert-equal "\\*"
                (limn/regex:emacs-regex-to-pcre "\\*")
                "\\* preserved"))

(deftest regex-c-mixed-pattern
  "Mixed: \\(\\w+\\)\\b → (\\w+)\\b"
  (let ((out (limn/regex:emacs-regex-to-pcre "\\(\\w+\\)\\b")))
    (assert-true (and (search "(" out) (search ")" out)
                      (search "\\w" out) (search "\\b" out))
                 "all parts present")))

(deftest regex-c-unicode-literal
  "Unicode literal characters preserved."
  (let ((out (limn/regex:emacs-regex-to-pcre "你好")))
    (assert-equal "你好" out
                  "CJK passthrough")))

(deftest regex-c-posix-class-preserved
  "POSIX class [[:alpha:]] (cl-ppcre supports it) passes through."
  (assert-equal "[[:alpha:]]+"
                (limn/regex:emacs-regex-to-pcre "[[:alpha:]]+")
                "POSIX class preserved"))

(deftest regex-c-repetition-passthrough
  "* + ? unchanged."
  (assert-equal "a*b+c?"
                (limn/regex:emacs-regex-to-pcre "a*b+c?")
                "repetition operators passthrough"))

(deftest regex-c-no-double-translation
  "Already-PCRE patterns shouldn't be re-translated into garbage."
  ;; Idempotency on already-translated common forms.
  (let ((once  (limn/regex:emacs-regex-to-pcre "\\(foo\\)"))
        (twice (limn/regex:emacs-regex-to-pcre
                (limn/regex:emacs-regex-to-pcre "\\(foo\\)"))))
    ;; After 1 translation: "(foo)". After 2: "(foo)" still or harmless escape.
    (assert-true (and (search "foo" once) (search "foo" twice))
                 "'foo' survives second translation")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §D. limn-search.lisp upgrade (5 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(defvar *r34-source-words*
  '((:|text| "defun"     :|rect| (0 0 50 10))
    (:|text| "foo"       :|rect| (55 0 80 10))
    (:|text| "x"         :|rect| (85 0 95 10))
    (:|text| "defun"     :|rect| (100 0 150 10))
    (:|text| "bar-baz"   :|rect| (155 0 200 10))
    (:|text| "123abc"    :|rect| (205 0 250 10))))

(deftest regex-d-find-matches-regex-emacs-syntax
  ":regex t with Emacs syntax \\b\\w+\\b finds word tokens."
  (let ((hits (limn/search:find-matches *r34-source-words*
                                        "\\b\\w+\\b" :regex t)))
    (assert-true (>= (length hits) 5)
                 "finds multiple word tokens")))

(deftest regex-d-find-matches-regex-pcre-explicit
  ":regex t :emacs-syntax nil bypasses shim, uses raw PCRE."
  (let ((hits (limn/search:find-matches *r34-source-words*
                                        "\\b\\w+\\b"
                                        :regex t :emacs-syntax nil)))
    (assert-true (>= (length hits) 5)
                 "raw PCRE \\b\\w+\\b also matches words")))

(deftest regex-d-find-matches-regex-case-sensitive
  ":case-sensitive t in regex mode still honored."
  (let ((hits-ci (limn/search:find-matches *r34-source-words*
                                           "DEFUN" :regex t))
        (hits-cs (limn/search:find-matches *r34-source-words*
                                           "DEFUN" :regex t
                                           :case-sensitive t)))
    (assert-true (> (length hits-ci) (length hits-cs))
                 "case-insensitive returns more than case-sensitive")))

(deftest regex-d-find-matches-exact-mode-unchanged
  "Old exact mode (no :regex) unchanged after upgrade."
  (let ((hits (limn/search:find-matches *r34-source-words* "defun")))
    (assert-eql 2 (length hits)
                "still finds 2 'defun' tokens")))

(deftest regex-d-find-matches-regex-result-shape
  "Regex hits keep same plist shape (word-index + text + rect)."
  (let ((hits (limn/search:find-matches *r34-source-words*
                                        "defun" :regex t)))
    (when hits
      (let ((h (first hits)))
        (assert-true (integerp (getf h :|word-index|))
                     "has :word-index")
        (assert-true (stringp (getf h :|text|))
                     "has :text")))))
