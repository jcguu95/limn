;;;; v0.40 §2.3 — dim overlay tests.
;;;;
;;;; install-dim-overlays / remove-dim-overlays manage 'shadow-faced
;;;; overlays that cover the non-accessible portion of a narrowed
;;;; buffer.  Used by the interactive narrow-to-region / widen commands
;;;; for visual feedback.

(in-package #:limn/unit-test)

(defun %dim-ovs (bid)
  (let* ((sym (find-symbol "*DIM-NARROW-OVERLAYS*" '#:limn/excursion))
         (tbl (and sym (boundp sym) (symbol-value sym))))
    (and tbl (gethash bid tbl))))

(defun %ov-faces (ovs)
  (mapcar (lambda (ov) (limn/overlays:overlay-get ov 'face)) ovs))

(defun %ov-ranges (ovs)
  (mapcar (lambda (ov)
            (list (limn/overlays:overlay-start ov)
                  (limn/overlays:overlay-end   ov)))
          ovs))

;;; ─────────────────────────────────────────────────────────────────────
;;; install-dim-overlays — narrow [5, 12) on a 16-char buffer creates
;;; both head [0, 5) and tail [12, 16).
;;; ─────────────────────────────────────────────────────────────────────

(deftest narrow-dim-install-creates-both-overlays
  "narrow 中間段 → head + tail 兩個 overlay。"
  (with-excursion-ctx ((b :id "nd1" :text "0123456789ABCDEF"))
    (%narrow 5 12)
    (limn/excursion:install-dim-overlays "nd1")
    (assert-eql 2 (limn/excursion:dim-overlay-count-for "nd1")
                "2 overlays installed")
    (let ((ranges (sort (copy-list (%ov-ranges (%dim-ovs "nd1")))
                        #'< :key #'first)))
      (assert-equal '((0 5) (12 16)) ranges
                    "ranges cover head + tail"))))

(deftest narrow-dim-install-uses-shadow-face
  "Dim overlays carry face 'shadow。"
  (with-excursion-ctx ((b :id "nd2" :text "0123456789ABCDEF"))
    (%narrow 5 12)
    (limn/excursion:install-dim-overlays "nd2")
    (let ((faces (%ov-faces (%dim-ovs "nd2"))))
      (assert-true (every (lambda (f) (eq f 'shadow)) faces)
                   "all dim overlays use face 'shadow"))))

(deftest narrow-dim-install-omits-empty-side-head
  "narrow [0, 12) — head 為空，只建 tail。"
  (with-excursion-ctx ((b :id "nd3" :text "0123456789ABCDEF"))
    (%narrow 0 12)
    (limn/excursion:install-dim-overlays "nd3")
    (assert-eql 1 (limn/excursion:dim-overlay-count-for "nd3")
                "only tail overlay")
    (assert-equal '((12 16)) (%ov-ranges (%dim-ovs "nd3"))
                  "tail covers [12, 16)")))

(deftest narrow-dim-install-omits-empty-side-tail
  "narrow [5, 16) — tail 為空，只建 head。"
  (with-excursion-ctx ((b :id "nd4" :text "0123456789ABCDEF"))
    (%narrow 5 16)
    (limn/excursion:install-dim-overlays "nd4")
    (assert-eql 1 (limn/excursion:dim-overlay-count-for "nd4")
                "only head overlay")
    (assert-equal '((0 5)) (%ov-ranges (%dim-ovs "nd4"))
                  "head covers [0, 5)")))

(deftest narrow-dim-install-no-narrow-noop
  "沒 narrow 時 install-dim-overlays 不建任何 overlay。"
  (with-excursion-ctx ((b :id "nd5" :text "abcdef"))
    (limn/excursion:install-dim-overlays "nd5")
    (assert-eql 0 (limn/excursion:dim-overlay-count-for "nd5")
                "no overlays when not narrowed")))

;;; ─────────────────────────────────────────────────────────────────────
;;; remove-dim-overlays
;;; ─────────────────────────────────────────────────────────────────────

(deftest narrow-dim-remove-deletes-all-overlays
  "remove-dim-overlays 清掉全部 dim overlay。"
  (with-excursion-ctx ((b :id "nd6" :text "0123456789ABCDEF"))
    (%narrow 5 12)
    (limn/excursion:install-dim-overlays "nd6")
    (limn/excursion:remove-dim-overlays "nd6")
    (assert-eql 0 (limn/excursion:dim-overlay-count-for "nd6")
                "all overlays removed")))

(deftest narrow-dim-remove-idempotent
  "remove-dim-overlays 沒裝過時也 OK。"
  (with-excursion-ctx ((b :id "nd7" :text "abcdef"))
    (assert-no-error (limn/excursion:remove-dim-overlays "nd7")
                     "remove-dim-overlays idempotent")))

;;; ─────────────────────────────────────────────────────────────────────
;;; install replaces (idempotent)
;;; ─────────────────────────────────────────────────────────────────────

(deftest narrow-dim-install-replaces-existing
  "install-dim-overlays 連續呼叫 → 取代不重複堆積。"
  (with-excursion-ctx ((b :id "nd8" :text "0123456789ABCDEF"))
    (%narrow 5 12)
    (limn/excursion:install-dim-overlays "nd8")
    (limn/excursion:install-dim-overlays "nd8")
    (assert-eql 2 (limn/excursion:dim-overlay-count-for "nd8")
                "still exactly 2 (not 4)")))
