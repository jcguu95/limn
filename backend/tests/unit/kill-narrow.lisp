;;;; v0.40 §1.5 — limn/kill narrow-aware tests.
;;;;
;;;; kill-region / copy-region-as-kill clip their [FROM, TO) range into
;;;; [point-min, point-max) before touching the buffer.  A stale mark
;;;; or an external caller can never kill text outside the narrowing.

(in-package #:limn/unit-test)

(defmacro with-narrow-kill ((var &key (id "kn") (text "") (point 0)) &body body)
  "Wire limn/kill's vtable on top of with-excursion-ctx."
  (let ((kpkg  (gensym "KP"))
        (pairs (gensym "PAIRS"))
        (live  (gensym "LIVE")))
    `(with-excursion-ctx ((,var :id ,id :text ,text :point ,point))
       (let* ((,kpkg (find-package '#:limn/kill))
              (,pairs
                (when ,kpkg
                  (list
                   (cons (find-symbol "*BUFFER-INSERT-FN*"     ,kpkg)
                         (let ((id (mmbuf32-id ,var)))
                           (lambda (bid off str)
                             (declare (ignore bid))
                             (mmbuf32-insert-fn id off str))))
                   ;; NOTE: kill-region's *buffer-delete-fn* contract is
                   ;; (bid from LEN), not (bid from to) like the rest of
                   ;; the codebase — adapter converts.
                   (cons (find-symbol "*BUFFER-DELETE-FN*"     ,kpkg)
                         (let ((id (mmbuf32-id ,var)))
                           (lambda (bid from len)
                             (declare (ignore bid))
                             (mmbuf32-delete-fn id from (+ from len)))))
                   (cons (find-symbol "*BUFFER-CURSOR-FN*"     ,kpkg)
                         (let ((b ,var))
                           (lambda (bid)
                             (declare (ignore bid))
                             (mmbuf32-point b))))
                   (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,kpkg)
                         (let ((b ,var))
                           (lambda (bid off)
                             (declare (ignore bid))
                             (setf (mmbuf32-point b) off))))
                   (cons (find-symbol "*BUFFER-TEXT-FN*"       ,kpkg)
                         (let ((b ,var))
                           (lambda (bid from to)
                             (declare (ignore bid))
                             (subseq (mmbuf32-text b) from to))))
                   ;; reset kill ring between tests
                   (cons (find-symbol "*KILL-RING*"            ,kpkg) nil)
                   (cons (find-symbol "*YANK-FROM*"            ,kpkg) nil)
                   (cons (find-symbol "*YANK-TO*"              ,kpkg) nil))))
              (,live (remove-if (lambda (p) (null (car p))) ,pairs)))
         (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
           ,@body)))))

(defun %kill-ring-head ()
  (let ((s (find-symbol "*KILL-RING*" '#:limn/kill)))
    (and s (boundp s) (car (symbol-value s)))))

;;; ─────────────────────────────────────────────────────────────────────
;;; kill-region clipping
;;; ─────────────────────────────────────────────────────────────────────

(deftest kill-narrow-region-clips-low-end
  "kill-region FROM<point-min → 從 point-min 開始 kill。"
  (with-narrow-kill (b :id "kn1" :text "0123456789ABCDEF" :point 0)
    (%narrow 5 12)
    (limn/kill:kill-region "kn1" 2 8)
    ;; only chars 5..8 = "567" should be killed
    (assert-equal "567" (%kill-ring-head) "killed only 5..8")
    (assert-equal "01234" (subseq (mmbuf32-text b) 0 5)
                  "chars before narrow untouched")))

(deftest kill-narrow-region-clips-high-end
  "kill-region TO>point-max → 到 point-max 為止。"
  (with-narrow-kill (b :id "kn2" :text "0123456789ABCDEF" :point 0)
    (%narrow 5 12)
    (limn/kill:kill-region "kn2" 8 15)
    (assert-equal "89AB" (%kill-ring-head) "killed only 8..12")
    (assert-equal "CDEF" (subseq (mmbuf32-text b) 8 12)
                  "chars after narrow untouched")))

(deftest kill-narrow-region-clips-both-ends
  "kill-region [FROM, TO) 完全包住 narrow → 只 kill narrow 整段。"
  (with-narrow-kill (b :id "kn3" :text "0123456789ABCDEF" :point 0)
    (%narrow 5 12)
    (limn/kill:kill-region "kn3" 0 16)
    (assert-equal "56789AB" (%kill-ring-head)
                  "killed exactly [5, 12)")))

(deftest kill-narrow-region-fully-outside-noop
  "kill-region 完全在 narrow 外 → clipped to empty → no-op。"
  (with-narrow-kill (b :id "kn4" :text "0123456789ABCDEF" :point 0)
    (%narrow 5 8)
    (limn/kill:kill-region "kn4" 10 14)
    (assert-equal "0123456789ABCDEF" (mmbuf32-text b)
                  "buffer unchanged")
    (assert-equal nil (%kill-ring-head) "kill ring untouched")))

(deftest kill-narrow-region-inside-narrow-normal
  "kill-region 範圍完全在 narrow 內 → 行為正常。"
  (with-narrow-kill (b :id "kn5" :text "0123456789ABCDEF" :point 0)
    (%narrow 5 12)
    (limn/kill:kill-region "kn5" 6 9)
    (assert-equal "678" (%kill-ring-head) "killed 6..9")
    (assert-equal "0123459ABCDEF" (mmbuf32-text b)
                  "678 removed")))

;;; ─────────────────────────────────────────────────────────────────────
;;; copy-region-as-kill clipping
;;; ─────────────────────────────────────────────────────────────────────

(deftest kill-narrow-copy-region-clips
  "copy-region-as-kill 也 clip [FROM, TO) 進 narrow。"
  (with-narrow-kill (b :id "kn6" :text "0123456789ABCDEF" :point 0)
    (%narrow 5 12)
    (limn/kill:copy-region-as-kill "kn6" 2 15)
    (assert-equal "56789AB" (%kill-ring-head) "copied [5, 12) only")
    (assert-equal "0123456789ABCDEF" (mmbuf32-text b)
                  "buffer unchanged (copy not kill)")))

;;; ─────────────────────────────────────────────────────────────────────
;;; baseline: no narrow → no clipping
;;; ─────────────────────────────────────────────────────────────────────

(deftest kill-narrow-no-narrow-passthrough
  "沒 narrow 時 kill-region [0, 16) → 整段 kill。"
  (with-narrow-kill (b :id "kn7" :text "0123456789ABCDEF" :point 0)
    (limn/kill:kill-region "kn7" 0 16)
    (assert-equal "0123456789ABCDEF" (%kill-ring-head) "full text killed")
    (assert-equal "" (mmbuf32-text b) "buffer emptied")))
