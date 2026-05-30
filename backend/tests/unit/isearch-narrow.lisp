;;;; v0.40 §1.3 — limn/isearch narrow-aware tests.
;;;;
;;;; isearch-update only returns matches whose [start, end) is fully
;;;; contained in [point-min, point-max).  Matches that straddle or
;;;; lie outside the accessible region are filtered out.

(in-package #:limn/unit-test)

(defmacro with-narrow-isearch ((var &key (id "in") (text "") (point 0)) &body body)
  "Wire limn/isearch's vtable on top of with-excursion-ctx + a mmbuf32 mock."
  (let ((is-pkg  (gensym "IS"))
        (pairs   (gensym "PAIRS"))
        (live    (gensym "LIVE")))
    `(with-excursion-ctx ((,var :id ,id :text ,text :point ,point))
       (let* ((,is-pkg (find-package '#:limn/isearch))
              (,pairs
                (when ,is-pkg
                  (list
                   (cons (find-symbol "*BUFFER-TEXT-FN*"       ,is-pkg)
                         (let ((b ,var))
                           (lambda (bid)
                             (declare (ignore bid))
                             (mmbuf32-text b))))
                   (cons (find-symbol "*BUFFER-CURSOR-FN*"     ,is-pkg)
                         (let ((b ,var))
                           (lambda (bid)
                             (declare (ignore bid))
                             (mmbuf32-point b))))
                   (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,is-pkg)
                         (let ((b ,var))
                           (lambda (bid off)
                             (declare (ignore bid))
                             (setf (mmbuf32-point b) off))))
                   ;; no-op highlight / history hooks
                   (cons (find-symbol "*HIGHLIGHT-FN*"         ,is-pkg)
                         (lambda (bid spans face)
                           (declare (ignore bid spans face))))
                   (cons (find-symbol "*CLEAR-HIGHLIGHTS-FN*"  ,is-pkg)
                         (lambda (bid) (declare (ignore bid))))
                   (cons (find-symbol "*HISTORY-PUSH-FN*"      ,is-pkg)
                         (lambda (q) (declare (ignore q))))
                   ;; force case-sensitive for predictable test output
                   (cons (find-symbol "*ISEARCH-CASE-FOLD*"    ,is-pkg) nil))))
              (,live (remove-if (lambda (p) (null (car p))) ,pairs)))
         (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
           ,@body)))))

(defun %match-starts (state)
  (mapcar #'car (limn/isearch:isearch-matches state)))

;;; ─────────────────────────────────────────────────────────────────────
;;; Match filtering at narrow boundaries
;;; ─────────────────────────────────────────────────────────────────────

(deftest isearch-narrow-only-matches-inside-narrow
  "narrow [5, 11) — only the 'aa' inside is found, not the ones outside."
  ;;            0         1
  ;;            0123456789012345
  (with-narrow-isearch (b :id "in1" :text "aa..aa..aa..aa.." :point 0)
    (%narrow 5 11)
    (let* ((s0 (limn/isearch:isearch-start "in1"))
           (s  (limn/isearch:isearch-update s0 "aa")))
      ;; matches at 0, 4, 8, 12 normally; with narrow [5, 11) only
      ;; "aa" at 8..10 is fully contained.
      (assert-equal '(8) (%match-starts s)
                    "only the [8,10) match survives"))))

(deftest isearch-narrow-excludes-straddling-match-at-lower-bound
  "match crossing point-min 邊界 ([3, 5)) 不算 hit。"
  (with-narrow-isearch (b :id "in2" :text "abcXXdef" :point 0)
    (%narrow 5 8)
    (let* ((s0 (limn/isearch:isearch-start "in2"))
           (s  (limn/isearch:isearch-update s0 "XX")))
      (assert-equal '() (%match-starts s)
                    "straddling match excluded"))))

(deftest isearch-narrow-excludes-straddling-match-at-upper-bound
  "match crossing point-max 邊界不算 hit。"
  (with-narrow-isearch (b :id "in3" :text "abcXXdef" :point 0)
    (%narrow 0 4)   ; XX at 3..5 — would straddle the boundary at 4
    (let* ((s0 (limn/isearch:isearch-start "in3"))
           (s  (limn/isearch:isearch-update s0 "XX")))
      (assert-equal '() (%match-starts s)
                    "straddling upper-bound match excluded"))))

(deftest isearch-narrow-match-exactly-at-lower-bound
  "match start = point-min 是 OK 的。"
  (with-narrow-isearch (b :id "in4" :text "abcXXdef" :point 0)
    (%narrow 3 6)
    (let* ((s0 (limn/isearch:isearch-start "in4"))
           (s  (limn/isearch:isearch-update s0 "XX")))
      (assert-equal '(3) (%match-starts s)
                    "match at exactly point-min: kept"))))

(deftest isearch-narrow-match-ends-exactly-at-upper-bound
  "match end = point-max 是 OK 的。"
  (with-narrow-isearch (b :id "in5" :text "abcXXdef" :point 0)
    (%narrow 0 5)
    (let* ((s0 (limn/isearch:isearch-start "in5"))
           (s  (limn/isearch:isearch-update s0 "XX")))
      (assert-equal '(3) (%match-starts s)
                    "match ending exactly at point-max: kept"))))

;;; ─────────────────────────────────────────────────────────────────────
;;; Baseline: no narrow → all matches
;;; ─────────────────────────────────────────────────────────────────────

(deftest isearch-narrow-no-narrow-finds-all
  "沒 narrow → 全 buffer 的 hits 都回。"
  (with-narrow-isearch (b :id "in6" :text "aa..aa..aa..aa.." :point 0)
    (let* ((s0 (limn/isearch:isearch-start "in6"))
           (s  (limn/isearch:isearch-update s0 "aa")))
      (assert-equal '(0 4 8 12) (%match-starts s)
                    "no narrow: all 4 hits"))))

;;; ─────────────────────────────────────────────────────────────────────
;;; After widen, hits previously hidden return
;;; ─────────────────────────────────────────────────────────────────────

(deftest isearch-narrow-widen-restores-hits
  "narrow → widen → 再 search → 全 hits 都回。"
  (with-narrow-isearch (b :id "in7" :text "aa..aa..aa..aa.." :point 0)
    (%narrow 5 11)
    (funcall (find-symbol "WIDEN" '#:limn/excursion))
    (let* ((s0 (limn/isearch:isearch-start "in7"))
           (s  (limn/isearch:isearch-update s0 "aa")))
      (assert-equal '(0 4 8 12) (%match-starts s)
                    "after widen: all 4 hits"))))
