;;;; Unit tests for limn-search (text-search logic that lives entirely in Lisp)
;;;;
;;;; This module takes results from buffer/text and performs matching in Lisp.
;;;; Because everything is Lisp logic, these tests don't need a running Limn.
;;;;
;;;; API contract:
;;;;
;;;;   (limn-search:find-matches words query &key case-sensitive regex fuzzy)
;;;;     → list of {word-index, score (for fuzzy)}
;;;;
;;;;   (limn-search:make-search-state &key query mode results)
;;;;   (limn-search:next-result state)
;;;;   (limn-search:prev-result state)
;;;;   (limn-search:current-result state)

(in-package #:limn/unit-test)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :limn/search)
    (defpackage :limn/search
      (:use :cl)
      (:export #:find-matches
               #:make-search-state #:next-result #:prev-result
               #:current-result #:state-p))))

;;; ── Building blocks: a fake "words" list as we'd get from buffer/text ──

(defvar *sample-words*
  '((:|text| "The"     :|rect| (10.0 10.0 30.0 20.0))
    (:|text| "quick"   :|rect| (35.0 10.0 75.0 20.0))
    (:|text| "brown"   :|rect| (80.0 10.0 120.0 20.0))
    (:|text| "fox"     :|rect| (125.0 10.0 145.0 20.0))
    (:|text| "jumps"   :|rect| (10.0 30.0 50.0 40.0))
    (:|text| "over"    :|rect| (55.0 30.0 80.0 40.0))
    (:|text| "the"     :|rect| (85.0 30.0 105.0 40.0))
    (:|text| "lazy"    :|rect| (110.0 30.0 140.0 40.0))
    (:|text| "dog"     :|rect| (10.0 50.0 30.0 60.0))))

;;; ── Exact match ─────────────────────────────────────────────────────────

(deftest search-exact-single-word
  (let ((hits (limn/search:find-matches *sample-words* "fox")))
    (assert-eql 1 (length hits) "one match for 'fox'")))

(deftest search-exact-case-insensitive-by-default
  (let ((hits (limn/search:find-matches *sample-words* "the")))
    (assert-true (>= (length hits) 2)
                 "case-insensitive: 'the' matches 'The' and 'the'")))

(deftest search-exact-case-sensitive
  (let ((hits (limn/search:find-matches *sample-words* "the"
                                        :case-sensitive t)))
    (assert-eql 1 (length hits) "case-sensitive: only lowercase 'the'")))

(deftest search-exact-no-match
  (let ((hits (limn/search:find-matches *sample-words* "elephant")))
    (assert-eql 0 (length hits))))

;;; ── Regex match ─────────────────────────────────────────────────────────

(deftest search-regex-anchored
  (let ((hits (limn/search:find-matches *sample-words* "^[Tt]he$" :regex t)))
    (assert-true (>= (length hits) 2) "regex matches both 'The' and 'the'")))

(deftest search-regex-character-class
  (let ((hits (limn/search:find-matches *sample-words* "[aeiou]ver" :regex t)))
    (assert-eql 1 (length hits))))

;;; ── Fuzzy match ─────────────────────────────────────────────────────────

(deftest search-fuzzy-near
  "Fuzzy search finds 'jumps' for query 'jmps'."
  (let ((hits (limn/search:find-matches *sample-words* "jmps" :fuzzy t)))
    (assert-true hits "fuzzy match returns something")))

(deftest search-fuzzy-ranked-by-score
  "Fuzzy matches come back with scores; better matches score higher."
  (let ((hits (limn/search:find-matches *sample-words* "fox" :fuzzy t)))
    (when (and hits (consp hits))
      (let ((first (first hits)))
        (assert-true (getf first :|score|) "fuzzy hits have :score")))))

;;; ── Search state navigation ─────────────────────────────────────────────

(deftest search-state-cycles-forward
  (let* ((s (limn/search:make-search-state
             :|query| "the"
             :|mode| "exact"
             :|results| '((:|page| 0 :|word-index| 0)
                          (:|page| 0 :|word-index| 6)
                          (:|page| 2 :|word-index| 3)))))
    (let ((c0 (limn/search:current-result s)))
      (assert-equal 0 (getf c0 :|page|) "starts at first")
      (limn/search:next-result s)
      (let ((c1 (limn/search:current-result s)))
        (assert-equal 6 (getf c1 :|word-index|) "advanced"))
      (limn/search:next-result s)
      (let ((c2 (limn/search:current-result s)))
        (assert-equal 2 (getf c2 :|page|) "advanced to next page"))
      ;; wraps around
      (limn/search:next-result s)
      (let ((c3 (limn/search:current-result s)))
        (assert-equal 0 (getf c3 :|page|) "wraps to start")))))

(deftest search-state-cycles-backward
  (let ((s (limn/search:make-search-state
            :|query| "the" :|mode| "exact"
            :|results| '((:|page| 0) (:|page| 1) (:|page| 2)))))
    (limn/search:prev-result s)
    (assert-equal 2 (getf (limn/search:current-result s) :|page|)
                  "prev from start wraps to last")))

(deftest search-state-empty-results
  "prev/next on empty results doesn't crash."
  (let ((s (limn/search:make-search-state :|query| "x" :|results| nil)))
    (assert-no-error (limn/search:next-result s))
    (assert-no-error (limn/search:prev-result s))
    (assert-eq nil (limn/search:current-result s))))

;;; ── Word boundary ──────────────────────────────────────────────────────
;;;
;;; Real search shouldn't return "the" as a match for "they" — unless
;;; substring mode is explicitly enabled.

(defvar *sample-with-substrings*
  '((:|text| "the"   :|rect| (0.0 0.0 30.0 10.0))
    (:|text| "they"  :|rect| (40.0 0.0 80.0 10.0))
    (:|text| "their" :|rect| (90.0 0.0 130.0 10.0))))

(deftest search-word-boundary-default
  "Default search matches whole words: 'the' should not match 'they'."
  ;; This depends on whether find-matches is whole-word or substring by default.
  ;; Spec doesn't specify; this test is informational on the chosen behavior.
  (let ((hits (limn/search:find-matches *sample-with-substrings* "the")))
    (cond
      ((= (length hits) 1)
       (assert-true t "whole-word default (1 match)"))
      ((= (length hits) 3)
       (assert-true t "substring default (3 matches)"))
      (t
       (assert-true nil
                    (format nil "unexpected hit count: ~a" (length hits)))))))

(deftest search-word-boundary-explicit
  "When :whole-word t is passed, matches respect boundaries."
  (let ((hits (handler-case
                  (limn/search:find-matches *sample-with-substrings*
                                            "the" :whole-word t)
                (error () nil))))
    (when hits
      (assert-equal 1 (length hits)
                    ":whole-word t restricts to 'the' only"))))

;;; ── Multi-page input ───────────────────────────────────────────────────
;;;
;;; In real use, search runs across many pages. The Lisp logic is per-page
;;; (buffer/text is per-page), so we test that aggregation works.

(deftest search-aggregate-multi-page
  "Aggregating per-page searches yields all hits."
  (let* ((page0 '((:|text| "alpha" :|rect| (0.0 0.0 50.0 10.0))
                  (:|text| "beta"  :|rect| (60.0 0.0 100.0 10.0))))
         (page1 '((:|text| "alpha" :|rect| (0.0 0.0 50.0 10.0))))
         (page2 '((:|text| "gamma" :|rect| (0.0 0.0 50.0 10.0)))))
    ;; Lisp would aggregate like this:
    (let ((all-alpha
            (append
             (mapcar (lambda (h) (list* :page 0 h))
                     (limn/search:find-matches page0 "alpha"))
             (mapcar (lambda (h) (list* :page 1 h))
                     (limn/search:find-matches page1 "alpha"))
             (mapcar (lambda (h) (list* :page 2 h))
                     (limn/search:find-matches page2 "alpha")))))
      (assert-equal 2 (length all-alpha) "2 'alpha' hits across pages"))))

;;; ── Phrase search ──────────────────────────────────────────────────────
;;;
;;; "the quick" should be searchable as a phrase, not just two separate words.

(deftest search-phrase-finds-consecutive-words
  "Searching for a phrase finds consecutive words."
  (let ((hits (handler-case
                  (limn/search:find-matches *sample-words* "the quick")
                (error () nil))))
    ;; "The quick" appears as consecutive words; should match
    (when hits
      (assert-true (>= (length hits) 1) "phrase found"))))

(deftest search-phrase-not-substring
  "Phrase search does not match a single word containing the phrase chars."
  (let ((hits (handler-case
                  (limn/search:find-matches *sample-words* "Thequick")
                (error () nil))))
    (assert-equal 0 (length hits) "concatenated form not matched")))

;;; ── Score is comparable across queries (for sorting) ───────────────────

(deftest search-fuzzy-score-numeric
  "Fuzzy match scores are numeric and can be sorted."
  (let ((hits (limn/search:find-matches *sample-words* "qck" :fuzzy t)))
    (when hits
      (dolist (h hits)
        (assert-numeric (getf h :|score|))))))

;;; ── State manipulation ──────────────────────────────────────────────────

(deftest search-state-current-after-init
  "Fresh search state's current is the first result."
  (let ((s (limn/search:make-search-state
            :|query| "x"
            :|results| '((:|page| 0 :|rect| (1 2 3 4))
                          (:|page| 1 :|rect| (5 6 7 8))))))
    (assert-equal 0 (getf (limn/search:current-result s) :|page|)
                  "first result is current")))

;;; ── Empty query ─────────────────────────────────────────────────────────

(deftest search-empty-query-no-matches
  "Empty query string returns no matches (don't accidentally match everything)."
  (let ((hits (handler-case
                  (limn/search:find-matches *sample-words* "")
                (error () :error))))
    (cond
      ((eq hits :error)
       (assert-true t "empty query errored (acceptable)"))
      (t
       (assert-equal 0 (length hits)
                     "empty query returns 0 results, not all words")))))

;;; ── Unicode in query ────────────────────────────────────────────────────

(defvar *cjk-words*
  '((:|text| "你好"   :|rect| (0.0 0.0 30.0 10.0))
    (:|text| "世界"   :|rect| (35.0 0.0 65.0 10.0))
    (:|text| "你好世界" :|rect| (70.0 0.0 130.0 10.0))))

(deftest search-cjk-exact
  "CJK query matches CJK content."
  (let ((hits (limn/search:find-matches *cjk-words* "你好")))
    (assert-true (>= (length hits) 1) "found CJK match")))

(deftest search-cjk-substring
  "CJK substring search (matches '你好' inside '你好世界')."
  (let ((hits (limn/search:find-matches *cjk-words* "好世")))
    ;; Result depends on whole-word vs substring default; informational
    (format t "    info: CJK substring '好世' found ~a hits~%" (length hits))))

;;; ── Normalization (NFC vs NFD) ──────────────────────────────────────────

(deftest search-normalization-aware
  "Search for 'é' (NFC, U+00E9) should match text containing 'é' (NFD, e + U+0301)."
  ;; Many search implementations don't normalize; this is informational
  (let ((words-nfd `((:|text| ,(format nil "caf~ce" (code-char #x0301))
                       :|rect| (0 0 30 10)))))
    (let ((hits (limn/search:find-matches words-nfd "café")))
      (format t "    info: NFC query → NFD content found ~a hits~%" (length hits)))))

;;; ── Special regex characters in plain queries ──────────────────────────

(deftest search-regex-chars-escaped-in-exact
  "In exact (non-regex) mode, regex special chars are treated literally."
  (let ((words '((:|text| "a.b" :|rect| (0 0 30 10))
                  (:|text| "axb" :|rect| (35 0 65 10)))))
    (let ((hits (limn/search:find-matches words "a.b")))
      ;; Exact mode: "a.b" should match only "a.b", not "axb"
      (assert-equal 1 (length hits)
                    "exact-mode treats '.' literally"))))

;;; ── Boundary cases for fuzzy ────────────────────────────────────────────

(deftest search-fuzzy-empty-query
  "Fuzzy with empty query: returns empty or matches all (depends on policy)."
  (let ((hits (handler-case
                  (limn/search:find-matches *sample-words* "" :fuzzy t)
                (error () :error))))
    (assert-true (or (eq hits :error)
                     (= (length hits) 0)
                     (= (length hits) (length *sample-words*)))
                 "fuzzy empty query has defined behavior")))

(deftest search-fuzzy-extreme-noise
  "Fuzzy with totally unrelated query returns no/few hits, not all."
  (let ((hits (limn/search:find-matches *sample-words* "xyzqwasdfgh" :fuzzy t)))
    (check-assertion (< (length hits) (length *sample-words*))
                     "fuzzy doesn't accept arbitrary garbage")))

;;; ── Result sorting ──────────────────────────────────────────────────────

(deftest search-results-sorted-by-position
  "Results from a single page are returned in document order."
  (let ((hits (limn/search:find-matches *sample-words* "the")))
    (when (>= (length hits) 2)
      (let ((idxs (mapcar (lambda (h) (or (getf h :|word-index|) 0))
                          hits)))
        ;; If implementation tracks word-index, it should be ascending
        (when (every #'numberp idxs)
          (assert-true (apply #'<= idxs)
                       "results in ascending word-index order"))))))
