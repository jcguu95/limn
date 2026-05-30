;;;; v0.40 §2.2 — modeline narrow indicator tests.
;;;;
;;;; Verifies that limn/excursion:format-narrow-indicator returns the
;;;; right string based on the active narrow state, and that
;;;; limn/pdf-mode:pdf-format-modeline appends it.

(in-package #:limn/unit-test)

;;; ── format-narrow-indicator behaviour ────────────────────────────────

(deftest narrow-modeline-indicator-empty-when-not-narrowed
  "format-narrow-indicator returns \"\" when BID isn't narrowed."
  (with-excursion-ctx ((b :id "nm1" :text "abcdef"))
    (assert-equal ""
                  (limn/excursion:format-narrow-indicator "nm1")
                  "no narrow → empty string")))

(deftest narrow-modeline-indicator-narrow-when-narrowed
  "format-narrow-indicator returns \"Narrow\" when BID is narrowed."
  (with-excursion-ctx ((b :id "nm2" :text "abcdef"))
    (%narrow 1 4)
    (assert-equal "Narrow"
                  (limn/excursion:format-narrow-indicator "nm2")
                  "narrow → \"Narrow\"")))

(deftest narrow-modeline-indicator-clears-on-widen
  "widen 後 format-narrow-indicator 又回到 \"\"。"
  (with-excursion-ctx ((b :id "nm3" :text "abcdef"))
    (%narrow 1 4)
    (funcall (find-symbol "WIDEN" '#:limn/excursion))
    (assert-equal ""
                  (limn/excursion:format-narrow-indicator "nm3")
                  "widen → empty again")))

(deftest narrow-modeline-indicator-buffer-local
  "narrow buffer A → indicator on A is \"Narrow\", on B is \"\"。"
  (with-excursion-ctx ((b1 :id "nm4-A" :text "abcdef")
                       (b2 :id "nm4-B" :text "ghijkl"))
    (%narrow 1 3)
    (assert-equal "Narrow"
                  (limn/excursion:format-narrow-indicator "nm4-A")
                  "A narrowed")
    (assert-equal ""
                  (limn/excursion:format-narrow-indicator "nm4-B")
                  "B not narrowed")))

;;; ── pdf-format-modeline integration ──────────────────────────────────

(deftest narrow-modeline-pdf-format-includes-narrow
  "pdf-format-modeline 加上 NARROW 參數時尾部出現 \"Narrow\"。"
  (let ((label (limn/pdf-mode:pdf-format-modeline
                "/tmp/doc.pdf" 0 5 1.0 nil "Narrow")))
    (check (search "Narrow" label)
           "label contains \"Narrow\""
           "got: ~a" label)))

(deftest narrow-modeline-pdf-format-omits-when-empty
  "pdf-format-modeline NARROW=\"\" → 不出現 \"Narrow\"。"
  (let ((label (limn/pdf-mode:pdf-format-modeline
                "/tmp/doc.pdf" 0 5 1.0 nil "")))
    (check (null (search "Narrow" label))
           "label doesn't contain \"Narrow\""
           "got: ~a" label)))

(deftest narrow-modeline-pdf-format-back-compat-no-narrow-arg
  "pdf-format-modeline 不傳 NARROW (舊 caller) → behaves as before."
  (let ((label (limn/pdf-mode:pdf-format-modeline
                "/tmp/doc.pdf" 0 5 1.0)))
    (check (null (search "Narrow" label))
           "no narrow arg → no Narrow suffix"
           "got: ~a" label)
    (check (search "PDF: doc.pdf" label)
           "still has the PDF header"
           "got: ~a" label)))
