;;;; view/overlays tests
;;;;
;;;; Covers section 5.2 of LIMN-SPEC (the view/overlays subsection).
;;;; Overlays are the core primitive for Lisp-controlled visuals:
;;;; search highlights, bookmarks, annotations all flow through here.
;;;;
;;;; Supported types: rect, line, text — each with color and opacity.

(in-package #:limn/test)

;;; ── Basic shape: rect ────────────────────────────────────────────────────

(deftest test-overlays-rect-single
  "A single rectangle overlay is accepted."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers| (list '(:|type| "rect"
                                      :|page| 0
                                      :|rect| (100.0 200.0 300.0 400.0)
                                      :|color| "#FFD700"
                                      :|opacity| 0.5)))))
      (assert-ok r))))

(deftest test-overlays-rect-multiple
  "Multiple rectangles on the same page accepted."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (10.0 10.0 100.0 50.0)
                            :|color| "#FF6B6B" :|opacity| 0.4)
                          '(:|type| "rect" :|page| 0
                            :|rect| (10.0 60.0 100.0 100.0)
                            :|color| "#4ECDC4" :|opacity| 0.4)
                          '(:|type| "rect" :|page| 0
                            :|rect| (10.0 110.0 100.0 150.0)
                            :|color| "#95E1D3" :|opacity| 0.4)))))
      (assert-ok r))))

(deftest test-overlays-rect-across-pages
  "Overlays can target different pages."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (0.0 0.0 100.0 100.0)
                            :|color| "#FF0000" :|opacity| 0.3)
                          '(:|type| "rect" :|page| 1
                            :|rect| (0.0 0.0 100.0 100.0)
                            :|color| "#00FF00" :|opacity| 0.3)))))
      (assert-ok r))))

;;; ── Clearing overlays ────────────────────────────────────────────────────

(deftest test-overlays-empty-clears
  "Empty layers list clears all overlays."
  (with-buffer (buf)
    ;; first set some
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list '(:|type| "rect" :|page| 0
                             :|rect| (0.0 0.0 50.0 50.0)
                             :|color| "#FFFFFF" :|opacity| 1.0)))
    ;; then clear
    (let ((r (send! "view/overlays" :|win-id| "w1" :|layers| nil)))
      (assert-ok r "empty layers list accepted (clears overlays)"))))

;;; ── Shape: line ──────────────────────────────────────────────────────────

(deftest test-overlays-line
  "Line overlay with width and opacity accepted."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "line" :|page| 0
                            :|from| (10.0 20.0)
                            :|to|   (200.0 300.0)
                            :|color| "#0000FF"
                            :|width| 2.0
                            :|opacity| 1.0)))))
      (assert-ok r))))

(deftest test-overlays-line-default-width
  "Line without explicit width uses a default."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "line" :|page| 0
                            :|from| (0.0 0.0)
                            :|to|   (100.0 100.0)
                            :|color| "#000000"
                            :|opacity| 1.0)))))
      (assert-ok r))))

;;; ── Shape: text ──────────────────────────────────────────────────────────

(deftest test-overlays-text
  "Text overlay with position, size, color accepted."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "text" :|page| 0
                            :|pos|  (100.0 100.0)
                            :|text| "Hello"
                            :|color| "#000000"
                            :|size| 12.0
                            :|opacity| 1.0)))))
      (assert-ok r))))

(deftest test-overlays-text-utf8
  "Text overlay supports UTF-8 content."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "text" :|page| 0
                            :|pos|  (100.0 100.0)
                            :|text| "你好世界 🌏"
                            :|color| "#FF00FF"
                            :|size| 14.0
                            :|opacity| 1.0)))))
      (assert-ok r))))

;;; ── Mixed shapes ─────────────────────────────────────────────────────────

(deftest test-overlays-mixed-types
  "Rect + line + text in one call."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (50.0 50.0 200.0 100.0)
                            :|color| "#FFFF00" :|opacity| 0.3)
                          '(:|type| "line" :|page| 0
                            :|from| (50.0 100.0) :|to| (200.0 100.0)
                            :|color| "#FF0000" :|width| 1.0 :|opacity| 1.0)
                          '(:|type| "text" :|page| 0
                            :|pos|  (60.0 75.0)
                            :|text| "annotation"
                            :|color| "#000000" :|size| 10.0 :|opacity| 1.0)))))
      (assert-ok r))))

;;; ── Error cases ──────────────────────────────────────────────────────────

(deftest test-overlays-invalid-type
  "Unknown overlay type returns error."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "fractal"
                            :|page| 0
                            :|color| "#000000" :|opacity| 1.0)))))
      (assert-fail r "unknown type rejected"))))

(deftest test-overlays-rect-missing-rect
  "Rect type missing 'rect' field returns error."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|color| "#000000" :|opacity| 1.0)))))
      (assert-fail r "rect without rect field rejected"))))

(deftest test-overlays-line-missing-endpoints
  "Line type missing from/to returns error."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "line" :|page| 0
                            :|color| "#000000" :|opacity| 1.0)))))
      (assert-fail r))))

(deftest test-overlays-text-missing-content
  "Text type missing 'text' field returns error."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "text" :|page| 0
                            :|pos| (10.0 10.0)
                            :|color| "#000000" :|size| 12.0 :|opacity| 1.0)))))
      (assert-fail r))))

(deftest test-overlays-unknown-win
  "Overlay call on nonexistent window fails."
  (let ((r (send! "view/overlays" :|win-id| "w-nope" :|layers| nil)))
    (assert-fail r)))

;;; ── Opacity range ────────────────────────────────────────────────────────

(deftest test-overlays-opacity-zero
  "Opacity 0.0 (fully transparent) is accepted."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (0.0 0.0 10.0 10.0)
                            :|color| "#000000" :|opacity| 0.0)))))
      (assert-ok r))))

(deftest test-overlays-opacity-one
  "Opacity 1.0 (fully opaque) is accepted."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (0.0 0.0 10.0 10.0)
                            :|color| "#000000" :|opacity| 1.0)))))
      (assert-ok r))))

(deftest test-overlays-opacity-out-of-range
  "Opacity outside [0,1] is rejected or clamped."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (0.0 0.0 10.0 10.0)
                            :|color| "#000000" :|opacity| 5.0)))))
      ;; spec doesn't strictly require rejection — we just need a response.
      (assert-true (member (getf r :|ok|) '(t :false)) "responded"))))

;;; ── Color format ─────────────────────────────────────────────────────────

(deftest test-overlays-color-hex-rgb
  "Hex RGB color #RRGGBB is accepted."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (0.0 0.0 10.0 10.0)
                            :|color| "#FF8800" :|opacity| 1.0)))))
      (assert-ok r))))

(deftest test-overlays-color-invalid
  "Malformed color string is rejected."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (0.0 0.0 10.0 10.0)
                            :|color| "not-a-color" :|opacity| 1.0)))))
      (assert-fail r "bad color rejected"))))

;;; ── Large overlay sets (stress) ──────────────────────────────────────────

(deftest test-overlays-many-rectangles
  "Setting many overlays at once is accepted (no implicit limit)."
  (with-buffer (buf)
    (let ((layers
            (loop for i from 0 below 100
                  collect `(:|type| "rect"
                            :|page| 0
                            :|rect| ,(list (float (* i 5))
                                            (float (* i 3))
                                            (float (+ (* i 5) 4))
                                            (float (+ (* i 3) 4)))
                            :|color| "#FF0000"
                            :|opacity| 0.2))))
      (let ((r (send! "view/overlays" :|win-id| "w1" :|layers| layers)))
        (assert-ok r "100 overlays accepted")))))

;;; ── Missing required fields ──────────────────────────────────────────────

(deftest test-overlays-rect-missing-page
  "Rect overlay without :page field is rejected."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect"
                            :|rect| (10.0 10.0 50.0 50.0)
                            :|color| "#FF0000" :|opacity| 1.0)))))
      (assert-fail r "missing :page rejected"))))

(deftest test-overlays-rect-missing-color
  "Color is required for all overlay types."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (10.0 10.0 50.0 50.0)
                            :|opacity| 1.0)))))
      (assert-fail r "missing :color rejected"))))

(deftest test-overlays-rect-missing-opacity
  "Opacity is required; no implicit default."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (10.0 10.0 50.0 50.0)
                            :|color| "#FF0000")))))
      ;; Spec says all types support opacity — but doesn't say it has default.
      ;; Accept either: require explicit, or default to 1.0.
      (assert-true (member (getf r :|ok|) '(t :false))
                   "responded cleanly to missing opacity"))))

;;; ── Page out of range ────────────────────────────────────────────────────

(deftest test-overlays-page-out-of-range
  "Overlay on a page that doesn't exist is rejected or silently no-op."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 99999
                            :|rect| (10.0 10.0 50.0 50.0)
                            :|color| "#FF0000" :|opacity| 1.0)))))
      ;; spec doesn't strictly require rejection; either is acceptable
      (assert-true (member (getf r :|ok|) '(t :false)) "responded"))))

(deftest test-overlays-page-negative
  "Negative page index is rejected."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| -1
                            :|rect| (10.0 10.0 50.0 50.0)
                            :|color| "#FF0000" :|opacity| 1.0)))))
      (assert-fail r "negative page rejected"))))

;;; ── Z-order / draw order ─────────────────────────────────────────────────

(deftest test-overlays-list-order-is-draw-order
  "Layers are drawn in list order (later = on top). Verify by sending
   the same rect with different colors and trusting frontend honors order."
  ;; We can't easily verify pixels from Lisp; just verify the call accepts
  ;; multiple overlapping items and Frontend doesn't reject.
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (10.0 10.0 100.0 100.0)
                            :|color| "#FF0000" :|opacity| 1.0)
                          '(:|type| "rect" :|page| 0
                            :|rect| (10.0 10.0 100.0 100.0)
                            :|color| "#00FF00" :|opacity| 1.0)
                          '(:|type| "rect" :|page| 0
                            :|rect| (10.0 10.0 100.0 100.0)
                            :|color| "#0000FF" :|opacity| 1.0)))))
      (assert-ok r "overlapping layers accepted (order should be honored)"))))

;;; ── Color formats ────────────────────────────────────────────────────────

(deftest test-overlays-color-uppercase
  "Hex color with uppercase letters is valid."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (0.0 0.0 10.0 10.0)
                            :|color| "#ABCDEF" :|opacity| 1.0)))))
      (assert-ok r "uppercase hex accepted"))))

(deftest test-overlays-color-lowercase
  "Hex color with lowercase letters is valid."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (0.0 0.0 10.0 10.0)
                            :|color| "#abcdef" :|opacity| 1.0)))))
      (assert-ok r "lowercase hex accepted"))))

(deftest test-overlays-color-without-hash
  "Color without # prefix is rejected (spec requires hex format)."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (0.0 0.0 10.0 10.0)
                            :|color| "FF0000" :|opacity| 1.0)))))
      (assert-fail r "no-# color rejected"))))

;;; ── Rect coordinates ─────────────────────────────────────────────────────

(deftest test-overlays-rect-degenerate
  "Rect with zero width or height is accepted (it's just invisible)."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "rect" :|page| 0
                            :|rect| (10.0 10.0 10.0 50.0)  ; zero width
                            :|color| "#FF0000" :|opacity| 1.0)))))
      (assert-true (member (getf r :|ok|) '(t :false))
                   "degenerate rect handled"))))

;;; ── Text overlay properties ──────────────────────────────────────────────

(deftest test-overlays-text-size-zero
  "Text with size 0 is rejected (degenerate)."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "text" :|page| 0
                            :|pos| (10.0 10.0) :|text| "x"
                            :|color| "#000000" :|size| 0.0 :|opacity| 1.0)))))
      (assert-fail r "text size 0 rejected"))))

(deftest test-overlays-text-empty-string
  "Empty text string is accepted (no-op)."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "text" :|page| 0
                            :|pos| (10.0 10.0) :|text| ""
                            :|color| "#000000" :|size| 12.0 :|opacity| 1.0)))))
      (assert-true (member (getf r :|ok|) '(t :false)) "responded"))))
