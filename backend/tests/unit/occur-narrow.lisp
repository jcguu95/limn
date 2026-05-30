;;;; v0.40 §1.6 — limn/occur narrow-aware tests.
;;;;
;;;; When the source buffer is narrowed, OCCUR reports only matches
;;;; whose absolute [match-start, match-end) falls fully inside
;;;; [point-min, point-max).  Line numbers stay absolute.

(in-package #:limn/unit-test)

(defmacro with-narrow-occur ((var &key (id "on") (text "") (point 0)) &body body)
  "Wire limn/occur's vtable on top of with-excursion-ctx.  Captures
   writes to the *occur* buffer in *occur-narrow-content*."
  (let ((opkg  (gensym "OP"))
        (pairs (gensym "PAIRS"))
        (live  (gensym "LIVE")))
    `(with-excursion-ctx ((,var :id ,id :text (%nl ,text) :point ,point))
       (setf *occur-narrow-content* nil)
       (let* ((,opkg (find-package '#:limn/occur))
              (,pairs
                (when ,opkg
                  (list
                   (cons (find-symbol "*BUFFER-TEXT-FN*"       ,opkg)
                         (let ((b ,var))
                           (lambda (bid)
                             (declare (ignore bid))
                             (mmbuf32-text b))))
                   (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,opkg)
                         (let ((b ,var))
                           (lambda (bid off)
                             (declare (ignore bid))
                             (setf (mmbuf32-point b) off))))
                   (cons (find-symbol "*OCCUR-WRITE-FN*"       ,opkg)
                         (lambda (obid content)
                           (declare (ignore obid))
                           (setf *occur-narrow-content* content))))))
              (,live (remove-if (lambda (p) (null (car p))) ,pairs)))
         (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
           ,@body)))))

(defvar *occur-narrow-content* nil)

(defun %occur-line-nums (state)
  (mapcar (lambda (m) (limn/occur:occur-match-line-num m))
          (limn/occur:occur-results state)))

(defun %occur-offsets (state)
  (mapcar (lambda (m) (limn/occur:occur-match-offset m))
          (limn/occur:occur-results state)))

;;; ─────────────────────────────────────────────────────────────────────
;;; Narrow filters matches by absolute offset
;;; ─────────────────────────────────────────────────────────────────────

(deftest occur-narrow-filters-matches-outside-narrow
  "narrow [8, 16) — only line 3 (\"foo\" at offset 8..11) survives."
  ;; "foo\nbar\nfoo\nbaz\nfoo\nqux"
  ;;  0   4   8   12  16  20
  (with-narrow-occur (b :id "on1" :text "foo\\\nbar\\\nfoo\\\nbaz\\\nfoo\\\nqux" :point 0)
    (%narrow 8 16)
    (let ((state (limn/occur:occur "on1" "foo")))
      (assert-equal '(3) (%occur-line-nums state)
                    "only line 3's foo is fully in narrow")
      (assert-equal '(8) (%occur-offsets state)
                    "offset 8"))))

(deftest occur-narrow-keeps-matches-fully-inside
  "narrow 內所有 hits 都回。"
  (with-narrow-occur (b :id "on2" :text "foo\\\nbar\\\nfoo\\\nbaz\\\nfoo\\\nqux" :point 0)
    (%narrow 0 16)
    (let ((state (limn/occur:occur "on2" "foo")))
      ;; matches at 0, 8 are fully inside; foo at 16 ends at 19 → outside hi=16.
      (assert-equal '(1 3) (%occur-line-nums state)
                    "lines 1 and 3 survive"))))

(deftest occur-narrow-excludes-straddling-match
  "match 跨 point-max → 排除（match-end > hi）。"
  (with-narrow-occur (b :id "on3" :text "..foo.." :point 0)
    ;; foo at 2..5; narrow [0, 4) → match-end 5 > 4 → exclude.
    (%narrow 0 4)
    (let ((state (limn/occur:occur "on3" "foo")))
      (assert-equal '() (%occur-line-nums state)
                    "straddling match excluded"))))

;;; ─────────────────────────────────────────────────────────────────────
;;; Line numbers stay absolute, not relative to narrow
;;; ─────────────────────────────────────────────────────────────────────

(deftest occur-narrow-line-numbers-stay-absolute
  "narrow 只影響哪些 match 回，line-num 仍是 buffer 絕對行號。"
  (with-narrow-occur (b :id "on4" :text "foo\\\nbar\\\nfoo\\\nbaz\\\nfoo" :point 0)
    (%narrow 8 16)
    (let ((state (limn/occur:occur "on4" "foo")))
      ;; only line 3's foo survives, line-num must be 3 (not 1).
      (assert-equal '(3) (%occur-line-nums state)
                    "line-num = absolute buffer line 3"))))

;;; ─────────────────────────────────────────────────────────────────────
;;; Baseline: no narrow → all matches
;;; ─────────────────────────────────────────────────────────────────────

(deftest occur-narrow-no-narrow-all-matches
  "沒 narrow → 全 buffer 的 foo 都回。"
  (with-narrow-occur (b :id "on5" :text "foo\\\nbar\\\nfoo\\\nbaz\\\nfoo" :point 0)
    (let ((state (limn/occur:occur "on5" "foo")))
      (assert-equal '(1 3 5) (%occur-line-nums state)
                    "no narrow: 3 hits"))))
