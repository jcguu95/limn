;;;; v0.40 §1.2 — limn/mark narrow-aware tests.
;;;;
;;;; When the current buffer is narrowed, set-mark / push-mark must
;;;; clamp their saved position into [point-min, point-max), and
;;;; exchange-point-and-mark must not push the cursor (or the new
;;;; mark) outside the accessible region even if the narrowing has
;;;; shrunk since the mark was first set.

(in-package #:limn/unit-test)

;;; ── fixture: with-narrow-mark ────────────────────────────────────────
;;;
;;; Sits on top of with-excursion-ctx so narrow markers, buffer-local
;;; vars and marker fixup are all wired correctly.  Additionally
;;; binds limn/mark's vtable to read/write the same mmbuf32 mock and
;;; resets per-buffer mark state.

(defmacro with-narrow-mark ((var &key (id "mn") (text "") (point 0)) &body body)
  (let ((mark-pkg (gensym "MP"))
        (pairs    (gensym "PAIRS"))
        (live     (gensym "LIVE")))
    `(with-excursion-ctx ((,var :id ,id :text ,text :point ,point))
       (let* ((,mark-pkg (find-package '#:limn/mark))
              (,pairs
                (when ,mark-pkg
                  (list
                   (cons (find-symbol "*BUFFER-CURSOR-FN*"     ,mark-pkg)
                         (let ((b ,var))
                           (lambda (bid)
                             (declare (ignore bid))
                             (mmbuf32-point b))))
                   (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" ,mark-pkg)
                         (let ((b ,var))
                           (lambda (bid off)
                             (declare (ignore bid))
                             (setf (mmbuf32-point b) off)))))))
              (,live (remove-if (lambda (p) (null (car p))) ,pairs)))
         (when ,mark-pkg
           (let ((reset (find-symbol "RESET-MARKS" ,mark-pkg)))
             (when reset (funcall reset (mmbuf32-id ,var)))))
         (unwind-protect
              (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
                ,@body)
           (when ,mark-pkg
             (let ((reset (find-symbol "RESET-MARKS" ,mark-pkg)))
               (when reset (funcall reset (mmbuf32-id ,var))))))))))

;;; ─────────────────────────────────────────────────────────────────────
;;; set-mark clamping
;;; ─────────────────────────────────────────────────────────────────────

(deftest mark-narrow-set-mark-clamps-below-point-min
  "set-mark POS<point-min → 存到 point-min。"
  (with-narrow-mark (b :id "mn1" :text "0123456789ABCDEF" :point 7)
    (%narrow 5 12)
    (limn/mark:set-mark 2 "mn1")
    (assert-eql 5 (limn/mark:mark "mn1")
                "mark clamped up to point-min 5")))

(deftest mark-narrow-set-mark-clamps-above-point-max
  "set-mark POS>point-max → 存到 point-max。"
  (with-narrow-mark (b :id "mn2" :text "0123456789ABCDEF" :point 7)
    (%narrow 5 12)
    (limn/mark:set-mark 15 "mn2")
    (assert-eql 12 (limn/mark:mark "mn2")
                "mark clamped down to point-max 12")))

(deftest mark-narrow-set-mark-keeps-pos-inside-narrow
  "set-mark POS 在 narrow 內 → 不變。"
  (with-narrow-mark (b :id "mn3" :text "0123456789ABCDEF" :point 7)
    (%narrow 5 12)
    (limn/mark:set-mark 8 "mn3")
    (assert-eql 8 (limn/mark:mark "mn3") "mark unchanged at 8")))

(deftest mark-narrow-set-mark-no-narrow-passthrough
  "沒 narrow 時 set-mark 任意 POS 都不 clamp。"
  (with-narrow-mark (b :id "mn4" :text "0123456789ABCDEF" :point 7)
    (limn/mark:set-mark 14 "mn4")
    (assert-eql 14 (limn/mark:mark "mn4") "no narrow: mark = 14 unchanged")))

;;; ─────────────────────────────────────────────────────────────────────
;;; push-mark clamping (defaulted pos = cursor, explicit :pos)
;;; ─────────────────────────────────────────────────────────────────────

(deftest mark-narrow-push-mark-explicit-pos-clamps
  "push-mark :pos 在 narrow 外 → clamp。"
  (with-narrow-mark (b :id "mn5" :text "0123456789ABCDEF" :point 7)
    (%narrow 5 12)
    (limn/mark:push-mark "mn5" :pos 2)
    (assert-eql 5 (limn/mark:mark "mn5") "push-mark clamped to 5")))

(deftest mark-narrow-push-mark-default-uses-cursor
  "push-mark 不傳 :pos → push 當前 cursor (本身就在 narrow 內)。"
  (with-narrow-mark (b :id "mn6" :text "0123456789ABCDEF" :point 7)
    (%narrow 5 12)
    (limn/mark:push-mark "mn6")
    (assert-eql 7 (limn/mark:mark "mn6") "push-mark: cursor pos 7")))

;;; ─────────────────────────────────────────────────────────────────────
;;; exchange-point-and-mark defensive clamp
;;; ─────────────────────────────────────────────────────────────────────

(deftest mark-narrow-xchg-clamps-when-narrow-shrinks
  "set-mark @ 10 → narrow 後縮到 [5, 8) → C-x C-x 不會把 cursor 推到 10。"
  (with-narrow-mark (b :id "mn7" :text "0123456789ABCDEF" :point 6)
    (limn/mark:set-mark 10 "mn7")           ; no narrow yet → mark = 10
    (%narrow 5 8)                            ; narrow tightens
    (limn/mark:exchange-point-and-mark "mn7")
    (assert-eql 8 (mmbuf32-point b)
                "cursor clamped to point-max 8 (not raw mark 10)")))

(deftest mark-narrow-xchg-clamps-new-mark
  "C-x C-x 把 cursor 存進 mark 時也 clamp（防舊 cursor 在 narrow 外）。"
  (with-narrow-mark (b :id "mn8" :text "0123456789ABCDEF" :point 14)
    (limn/mark:set-mark 6 "mn8")             ; mark = 6 (in future narrow)
    (%narrow 5 10)                            ; cursor 14 now outside narrow
    (limn/mark:exchange-point-and-mark "mn8")
    (assert-eql 6 (mmbuf32-point b) "cursor → mark 6")
    (assert-eql 10 (limn/mark:mark "mn8")
                "new mark = clamped old cursor = point-max 10")))

(deftest mark-narrow-xchg-roundtrip-inside-narrow
  "narrow 內正常 C-x C-x 交換來去。"
  (with-narrow-mark (b :id "mn9" :text "0123456789ABCDEF" :point 6)
    (%narrow 5 12)
    (limn/mark:set-mark 9 "mn9")
    (limn/mark:exchange-point-and-mark "mn9")
    (assert-eql 9 (mmbuf32-point b) "cursor = 9")
    (assert-eql 6 (limn/mark:mark "mn9") "mark = 6")
    (limn/mark:exchange-point-and-mark "mn9")
    (assert-eql 6 (mmbuf32-point b) "cursor back to 6")
    (assert-eql 9 (limn/mark:mark "mn9") "mark back to 9")))
