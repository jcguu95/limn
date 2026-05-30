;;;; v0.40 §1.4 — limn/regex narrow-aware tests.
;;;;
;;;; All buffer-aware regex commands now respect narrowing:
;;;;   re-search-forward    — implicit BOUND defaults to (point-max);
;;;;                          explicit BOUND clipped to point-max.
;;;;   re-search-backward   — implicit BOUND defaults to (point-min);
;;;;                          explicit BOUND clamped up to point-min.
;;;;   re-search-in-buffer  — scans only [point-min, point-max).
;;;;   looking-at           — match end must be <= point-max.
;;;;   looking-back         — implicit LIMIT defaults to (point-min).

(in-package #:limn/unit-test)

(defmacro with-narrow-regex ((var &key (id "rn") (text "") (point 0)) &body body)
  "Sit on with-excursion-ctx + wire limn/regex's vtable to the mmbuf32 mock."
  (let ((rpkg  (gensym "RP"))
        (pairs (gensym "PAIRS"))
        (live  (gensym "LIVE")))
    `(with-excursion-ctx ((,var :id ,id :text ,text :point ,point))
       (let* ((,rpkg (find-package '#:limn/regex))
              (,pairs
                (when ,rpkg
                  (list
                   (cons (find-symbol "*BUFFER-TEXT-FN*"     ,rpkg)
                         (let ((b ,var))
                           (lambda (bid)
                             (declare (ignore bid))
                             (mmbuf32-text b))))
                   (cons (find-symbol "*BUFFER-SET-TEXT-FN*" ,rpkg)
                         (let ((b ,var))
                           (lambda (bid txt)
                             (declare (ignore bid))
                             (setf (mmbuf32-text b) txt))))
                   (cons (find-symbol "*POINT-FN*"           ,rpkg)
                         (let ((b ,var))
                           (lambda (bid)
                             (declare (ignore bid))
                             (mmbuf32-point b))))
                   (cons (find-symbol "*SET-POINT-FN*"       ,rpkg)
                         (let ((b ,var))
                           (lambda (bid off)
                             (declare (ignore bid))
                             (setf (mmbuf32-point b) off))))
                   (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,rpkg)
                         (let ((b ,var))
                           (lambda (bid)
                             (declare (ignore bid))
                             (length (mmbuf32-text b))))))))
              (,live (remove-if (lambda (p) (null (car p))) ,pairs)))
         (when ,rpkg
           (let ((r (find-symbol "RESET-MATCH-DATA" ,rpkg)))
             (when r (funcall r))))
         (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
           ,@body)))))

;;; ─────────────────────────────────────────────────────────────────────
;;; re-search-forward
;;; ─────────────────────────────────────────────────────────────────────

(deftest regex-narrow-rsf-stops-at-point-max
  "re-search-forward 不會找到 narrow 外的 match。"
  ;; "....XX....XX...."  narrow [0, 6) — only the first XX (4..6) qualifies,
  ;; second XX is at 10..12 → outside narrow.
  (with-narrow-regex (b :id "rn1" :text "....XX....XX...." :point 0)
    (%narrow 0 6)
    (assert-eql 6 (limn/regex:re-search-forward "XX" nil t)
                "first match end = 6")
    ;; Next call from cursor=6: should fail (no further match in narrow).
    (assert-equal nil (limn/regex:re-search-forward "XX" nil t)
                  "no second match inside narrow")))

(deftest regex-narrow-rsf-explicit-bound-clipped-to-point-max
  "re-search-forward 明確 BOUND > point-max → 仍 clip 到 point-max。"
  ;; narrow [0, 6); the second "XX" at 10..12 is past point-max.  Even
  ;; with explicit BOUND=20 (which without narrowing would find it), the
  ;; clip should reject the second match.  Move cursor past first match.
  (with-narrow-regex (b :id "rn2" :text "....XX....XX...." :point 7)
    (%narrow 0 6)
    (assert-equal nil (limn/regex:re-search-forward "XX" 20 t)
                  "bound 20 still clipped to point-max 6 → no match found")))

(deftest regex-narrow-rsf-no-narrow-finds-second-match
  "沒 narrow 時 re-search-forward 找得到後面的 match。"
  (with-narrow-regex (b :id "rn3" :text "....XX....XX...." :point 7)
    (assert-eql 12 (limn/regex:re-search-forward "XX" nil t)
                "no narrow: second XX at 10..12")))

;;; ─────────────────────────────────────────────────────────────────────
;;; re-search-backward
;;; ─────────────────────────────────────────────────────────────────────

(deftest regex-narrow-rsb-stops-at-point-min
  "re-search-backward 不會找到 narrow 前的 match。"
  ;; cursor=15, narrow [8, 16) — the XX at 10..12 qualifies, the XX
  ;; at 4..6 is outside narrow → not found.
  (with-narrow-regex (b :id "rn4" :text "....XX....XX...." :point 15)
    (%narrow 8 16)
    (assert-eql 10 (limn/regex:re-search-backward "XX" nil t)
                "match start = 10")
    ;; Move cursor to 10 (just before match start), re-search-backward
    ;; → no match in narrow.
    (setf (mmbuf32-point b) 10)
    (assert-equal nil (limn/regex:re-search-backward "XX" nil t)
                  "no earlier match inside narrow")))

(deftest regex-narrow-rsb-no-narrow-finds-earlier-match
  "沒 narrow 時 re-search-backward 找得到前面的 match。"
  (with-narrow-regex (b :id "rn5" :text "....XX....XX...." :point 10)
    (assert-eql 4 (limn/regex:re-search-backward "XX" nil t)
                "no narrow: XX at 4..6")))

;;; ─────────────────────────────────────────────────────────────────────
;;; re-search-in-buffer
;;; ─────────────────────────────────────────────────────────────────────

(deftest regex-narrow-rsib-respects-narrow
  "re-search-in-buffer 只在 narrow 內找。"
  (with-narrow-regex (b :id "rn6" :text "....XX....XX...." :point 0)
    (%narrow 8 16)
    (assert-eql 12 (limn/regex:re-search-in-buffer "XX" "rn6")
                "match end = 12 (first match inside narrow)")))

;;; ─────────────────────────────────────────────────────────────────────
;;; looking-at
;;; ─────────────────────────────────────────────────────────────────────

(deftest regex-narrow-looking-at-rejects-match-past-point-max
  "looking-at 不會接受 end > point-max 的 match。"
  ;; "XXXX" at point 0, narrow [0, 2). \"XX\" matches (end=2 OK).
  ;; "XXXX" pattern requires end=4 → reject.
  (with-narrow-regex (b :id "rn7" :text "XXXXabcd" :point 0)
    (%narrow 0 2)
    (assert-equal nil (limn/regex:looking-at "XXXX")
                  "match would extend past point-max → reject")
    (assert-true (limn/regex:looking-at "XX")
                 "match exactly to point-max OK")))

;;; ─────────────────────────────────────────────────────────────────────
;;; looking-back
;;; ─────────────────────────────────────────────────────────────────────

(deftest regex-narrow-looking-back-respects-point-min
  "looking-back 的 implicit LIMIT 是 point-min。"
  ;; "XXXX" at point 4, narrow [2, 4). looking-back for "XXXX" (length 4)
  ;; would need to start at 0 < point-min → reject. "XX" (start 2) OK.
  (with-narrow-regex (b :id "rn8" :text "XXXXabcd" :point 4)
    (%narrow 2 8)
    (assert-equal nil (limn/regex:looking-back "XXXX")
                  "match would start before point-min → reject")
    (assert-true (limn/regex:looking-back "XX")
                 "match within narrow OK")))
