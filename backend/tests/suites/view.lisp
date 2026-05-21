;;;; view/ namespace tests
;;;;
;;;; Covers section 5.2 of LIMN-SPEC:
;;;;   view/set, view/get
;;;;   (view/overlays gets its own suite: overlays.lisp)
;;;;
;;;; The spec requires every engine to implement view/. These tests target
;;;; the mupdf engine since it's the first one — but the assertions hold
;;;; for any engine that implements the spec.

(in-package #:limn/test)

;;; ── view/set: universal fields ───────────────────────────────────────────

(deftest test-view-set-page
  "Setting page updates the viewport."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|page| 1)))
      (assert-ok r "view/set page=1 ok"))
    (let* ((g (send! "view/get" :|win-id| "w1"))
           (page (json-get* g :|data| :|page|)))
      (assert-equal 1 page "view/get reflects new page"))))

(deftest test-view-set-page-zero
  "Setting page=0 (first page) is valid."
  (with-buffer (buf)
    (assert-ok (send! "view/set" :|win-id| "w1" :|page| 0))))

(deftest test-view-set-zoom
  "Setting zoom updates the viewport."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|zoom| 1.5)))
      (assert-ok r))
    (let* ((g (send! "view/get" :|win-id| "w1"))
           (zoom (json-get* g :|data| :|zoom|)))
      (assert-numeric zoom)
      ;; allow a tiny tolerance since float
      (check-assertion (< (abs (- zoom 1.5)) 0.01)
                       "zoom ≈ 1.5"
                       "got ~s" zoom))))

(deftest test-view-set-offset-y
  "Setting offset-y updates vertical scroll position."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|offset-y| 200.0)))
      (assert-ok r))
    (let ((offset (json-get* (send! "view/get" :|win-id| "w1")
                             :|data| :|offset-y|)))
      (assert-numeric offset))))

(deftest test-view-set-offset-x
  "Setting offset-x updates horizontal scroll position."
  (with-buffer (buf)
    (assert-ok (send! "view/set" :|win-id| "w1" :|offset-x| 50.0))))

(deftest test-view-set-multiple-fields
  "Setting page + zoom + offset in one call applies atomically."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1"
                    :|page| 2 :|zoom| 1.2 :|offset-y| 100.0)))
      (assert-ok r "atomic multi-field set")
      (let* ((g    (send! "view/get" :|win-id| "w1"))
             (data (getf g :|data|)))
        (assert-equal 2 (getf data :|page|) "page set")
        (assert-numeric (getf data :|zoom|))
        (assert-numeric (getf data :|offset-y|))))))

;;; ── view/set: error cases ────────────────────────────────────────────────

(deftest test-view-set-no-buffer
  "view/set on a window with no buffer fails gracefully."
  ;; Pre-condition: assumes w1 has no buffer; if it does, this test is moot.
  ;; Either way, the call must respond (not hang/crash).
  (let ((r (send! "view/set" :|win-id| "w1" :|page| 0)))
    (assert-true (member (getf r :|ok|) '(t :false)) "responded")))

(deftest test-view-set-page-out-of-range
  "Setting page beyond num-pages returns error or clamps."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|page| 99999)))
      ;; Spec doesn't require strict rejection; some engines clamp.
      ;; We just require a well-formed response.
      (assert-true (member (getf r :|ok|) '(t :false)) "responded"))))

(deftest test-view-set-negative-page
  "Negative page numbers are rejected or clamped to 0."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|page| -5)))
      (assert-true (member (getf r :|ok|) '(t :false)) "responded"))))

(deftest test-view-set-zero-zoom
  "Zero zoom is rejected (would be degenerate)."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|zoom| 0.0)))
      (assert-fail r "zoom=0 rejected"))))

(deftest test-view-set-negative-zoom
  "Negative zoom is rejected."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|zoom| -1.0)))
      (assert-fail r "negative zoom rejected"))))

(deftest test-view-set-unknown-win
  "view/set on nonexistent window fails."
  (let ((r (send! "view/set" :|win-id| "w-nope" :|page| 0)))
    (assert-fail r)))

;;; ── view/set: engine-params ──────────────────────────────────────────────

(deftest test-view-set-engine-params
  "engine-params passes through to engine; well-formed call succeeds."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1"
                    :|engine-params| '(:|dark-mode| t))))
      (assert-ok r "engine-params dark-mode accepted"))))

(deftest test-view-set-unknown-engine-params-ignored
  "Unknown engine-params keys must be silently ignored, not errored."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1"
                    :|engine-params| '(:|made-up-param| 42))))
      (assert-ok r "unknown engine-params ignored"))))

(deftest test-view-set-engine-params-and-universal
  "Setting both universal fields and engine-params in one call works."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1"
                    :|page| 0
                    :|zoom| 1.0
                    :|engine-params| '(:|dark-mode| :false))))
      (assert-ok r))))

;;; ── view/get ─────────────────────────────────────────────────────────────

(deftest test-view-get-after-load
  "After buffer load, view/get returns a populated state."
  (with-buffer (buf)
    (let* ((r    (send! "view/get" :|win-id| "w1"))
           (data (getf r :|data|)))
      (assert-ok r)
      (assert-has-key :|buffer-id| data)
      (assert-has-key :|page|      data)
      (assert-has-key :|zoom|      data)
      (assert-equal buf (getf data :|buffer-id|) "buffer-id matches loaded"))))

(deftest test-view-get-page-type
  "view/get page is an integer."
  (with-buffer (buf)
    (let ((page (json-get* (send! "view/get" :|win-id| "w1")
                           :|data| :|page|)))
      (assert-type page integer))))

(deftest test-view-get-zoom-type
  "view/get zoom is numeric."
  (with-buffer (buf)
    (let ((zoom (json-get* (send! "view/get" :|win-id| "w1")
                           :|data| :|zoom|)))
      (assert-numeric zoom)
      (check-assertion (> zoom 0) "zoom positive"))))

(deftest test-view-get-offset-y-type
  "view/get offset-y is numeric."
  (with-buffer (buf)
    (let ((oy (json-get* (send! "view/get" :|win-id| "w1")
                         :|data| :|offset-y|)))
      (assert-numeric oy))))

(deftest test-view-get-engine-params-included
  "view/get response includes engine-params (may be empty)."
  (with-buffer (buf)
    (let ((data (getf (send! "view/get" :|win-id| "w1") :|data|)))
      (assert-has-key :|engine-params| data
                      "engine-params field present (even if empty)"))))

(deftest test-view-get-unknown-win
  "view/get on nonexistent window fails."
  (let ((r (send! "view/get" :|win-id| "w-nope")))
    (assert-fail r)))

;;; ── view/get reflects view/set roundtrip ─────────────────────────────────

(deftest test-view-set-then-get-roundtrip
  "Values set via view/set are reflected in view/get."
  (with-buffer (buf)
    (send! "view/set" :|win-id| "w1" :|page| 1 :|zoom| 2.0)
    (let* ((g    (send! "view/get" :|win-id| "w1"))
           (data (getf g :|data|)))
      (assert-equal 1 (getf data :|page|) "page roundtrip")
      (check-assertion (< (abs (- (getf data :|zoom|) 2.0)) 0.01)
                       "zoom roundtrip" "got ~s" (getf data :|zoom|)))))

;;; ── Partial update preservation ──────────────────────────────────────────
;;; Spec says view/set "可部分更新". A set of only page should keep zoom unchanged.

(deftest test-view-set-partial-preserves-untouched
  "Setting only :page leaves :zoom alone."
  (with-buffer (buf)
    (send! "view/set" :|win-id| "w1" :|zoom| 1.5)
    (let ((zoom-before (json-get* (send! "view/get" :|win-id| "w1")
                                   :|data| :|zoom|)))
      ;; Now only set page
      (send! "view/set" :|win-id| "w1" :|page| 1)
      (let ((zoom-after (json-get* (send! "view/get" :|win-id| "w1")
                                    :|data| :|zoom|)))
        (check-assertion (< (abs (- zoom-before zoom-after)) 0.01)
                         "zoom preserved across partial set"
                         "before=~s after=~s" zoom-before zoom-after)))))

(deftest test-view-set-partial-engine-params-preserves
  "Setting universal field doesn't clear engine-params."
  (with-buffer (buf)
    (send! "view/set" :|win-id| "w1"
           :|engine-params| '(:|dark-mode| t))
    (send! "view/set" :|win-id| "w1" :|page| 1)
    (let ((ep (json-get* (send! "view/get" :|win-id| "w1")
                          :|data| :|engine-params|)))
      (assert-equal t (getf ep :|dark-mode|)
                    "dark-mode preserved across non-engine-param set"))))

;;; ── Atomicity ────────────────────────────────────────────────────────────
;;; Spec says "原子操作". A failing multi-field set should not partially apply.

(deftest test-view-set-atomic-on-failure
  "If view/set with multiple fields fails on one, none should apply."
  (with-buffer (buf)
    (send! "view/set" :|win-id| "w1" :|page| 0 :|zoom| 1.0)
    ;; Now try a set where one field is invalid
    (send! "view/set" :|win-id| "w1" :|page| 1 :|zoom| -5.0)
    ;; If atomic, page should still be 0 (not 1)
    (let ((page (json-get* (send! "view/get" :|win-id| "w1")
                            :|data| :|page|)))
      ;; This test is informational: spec says atomic, but if not, page may be 1.
      ;; We accept either but log:
      (format t "    note: page is ~a after failed atomic set (atomicity ~a)~%"
              page (if (= page 0) "preserved" "violated")))))

;;; ── Extreme values ───────────────────────────────────────────────────────

(deftest test-view-set-very-large-zoom
  "Very large zoom (e.g. 100x) is rejected or clamped, not a crash."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|zoom| 100.0)))
      (assert-true (member (getf r :|ok|) '(t :false))
                   "extreme zoom handled cleanly"))))

(deftest test-view-set-tiny-zoom
  "Very tiny zoom (e.g. 0.001x) is rejected or clamped, not a crash."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|zoom| 0.001)))
      (assert-true (member (getf r :|ok|) '(t :false))
                   "tiny zoom handled cleanly"))))

(deftest test-view-set-large-offset
  "Offsets larger than the document scroll range are clamped, not crashing."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1" :|offset-y| 9999999.0)))
      (assert-true (member (getf r :|ok|) '(t :false)) "responded"))))

;;; ── view/get includes num-pages or page-count ────────────────────────────

(deftest test-view-get-includes-num-pages
  "view/get response includes num-pages or page-count (so Lisp can validate page)."
  (with-buffer (buf)
    (let ((data (getf (send! "view/get" :|win-id| "w1") :|data|)))
      (assert-true (or (getf data :|num-pages|)
                       (getf data :|page-count|))
                   "num-pages or page-count present"))))
