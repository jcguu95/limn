;;;; v0.14 — paint-level overlay rendering tests.
;;;;
;;;; Where suites/overlays.lisp validates the wire protocol contract,
;;;; this suite validates that paintGL ACTUALLY draws the overlays —
;;;; i.e. the pixels in the grabbed framebuffer actually change in
;;;; ways consistent with the layers requested.
;;;;
;;;; Mechanism:
;;;;   - test/grab-window returns { png, width, height, avg-luminance,
;;;;     opaque-pixels } against MainWidget via QWidget::grab() on the
;;;;     QT_QPA_PLATFORM=offscreen backing store. Real Qt paint pipeline,
;;;;     fully deterministic.
;;;;   - We use avg-luminance changes as the signal: paint-level effect
;;;;     of overlays MUST show up as a luminance delta from a no-overlay
;;;;     baseline. Sign + magnitude tell us whether overlays are actually
;;;;     hitting the framebuffer.
;;;;
;;;; A subset of tests requires test/grab-region (a v0.14 helper, NOT yet
;;;; implemented) which returns avg-luminance over an arbitrary [x0,y0,
;;;; x1,y1] sub-rectangle of the grab. This lets us check that the
;;;; OVERLAY AREA SPECIFICALLY changed colour, not just "something
;;;; somewhere changed". Tests marked "needs test/grab-region" are RED
;;;; until v0.14 ships that helper.
;;;;
;;;; Threshold note: the no-overlay grab is the empty MainWidget; with
;;;; no PDF loaded its avg-luminance is in a narrow band. We assert
;;;; |delta| >= 1.0 luminance unit (out of 0..255) which is a very
;;;; conservative "definitely not noise" threshold.

(in-package #:limn/test)

;;; ── helpers ──────────────────────────────────────────────────────────────

(defun grab-luminance ()
  "Force a fresh paint, grab, return avg-luminance scalar."
  (send! "bridge/ping")                  ; let any pending paint flush
  (let ((r (send! "test/grab-window")))
    (json-get* r :|data| :|avg-luminance|)))

(defun overlay-baseline ()
  "Clear overlays, take a luminance baseline. Returns the scalar."
  (send! "view/overlays" :|win-id| "w1" :|layers| nil)
  (grab-luminance))

(defun lum-diff (a b)
  "Absolute difference between two luminance scalars."
  (abs (- (or a 0) (or b 0))))

;;; ── Test: setting an overlay changes pixels ──────────────────────────────

(deftest test-paint-rect-overlay-changes-pixels
  "v0.14: setting a rect overlay produces a measurable pixel change.

   Without paintGL drawing overlays this test fails — the overlay-count
   goes up but the framebuffer is identical. With v0.14 paintGL the
   framebuffer's avg-luminance shifts."
  (with-buffer (buf)
    (let* ((baseline (overlay-baseline))
           (_ (send! "view/overlays" :|win-id| "w1"
                     :|layers| (list '(:|type| "rect" :|page| 0
                                        :|rect| (0.1 0.1 0.9 0.9)
                                        :|color| "#FF0000"
                                        :|opacity| 1.0))))
           (after (grab-luminance)))
      (declare (ignore _))
      (assert-true (>= (lum-diff baseline after) 1.0)
                   (format nil "luminance changed: baseline=~a after=~a"
                           baseline after)))))

(deftest test-paint-overlay-clear-restores-baseline
  "v0.14: after set-then-clear, luminance returns close to the baseline."
  (with-buffer (buf)
    (let ((baseline (overlay-baseline)))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 0
                                :|rect| (0.0 0.0 1.0 1.0)
                                :|color| "#00FF00"
                                :|opacity| 1.0)))
      (let ((with-overlay (grab-luminance)))
        (assert-true (>= (lum-diff baseline with-overlay) 1.0)
                     "set causes diff"))
      ;; Now clear
      (send! "view/overlays" :|win-id| "w1" :|layers| nil)
      (let ((after-clear (grab-luminance)))
        (assert-true (< (lum-diff baseline after-clear) 1.0)
                     (format nil "after clear lum returns to baseline: ~a vs ~a"
                             baseline after-clear))))))

;;; ── Test: page filter ────────────────────────────────────────────────────

(deftest test-paint-overlay-on-different-page-not-rendered
  "v0.14: an overlay targeting page 5 while viewing page 0 must NOT
   show up in the framebuffer."
  (with-buffer (buf)
    (send! "view/set" :|win-id| "w1" :|page| 0)
    (let ((baseline (overlay-baseline)))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 5
                                :|rect| (0.0 0.0 1.0 1.0)
                                :|color| "#FF0000"
                                :|opacity| 1.0)))
      (let ((after (grab-luminance)))
        (assert-true (< (lum-diff baseline after) 1.0)
                     (format nil "page-5 overlay shouldn't affect page-0 view: ~a vs ~a"
                             baseline after))))))

;;; ── Test: opacity matters ────────────────────────────────────────────────

(deftest test-paint-opacity-affects-magnitude
  "v0.14: opacity 1.0 must produce a strictly larger luminance change
   than opacity 0.1 (over the same geometry and colour)."
  (with-buffer (buf)
    (let ((baseline (overlay-baseline)))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 0
                                :|rect| (0.0 0.0 1.0 1.0)
                                :|color| "#000000"
                                :|opacity| 0.1)))
      (let ((faint (grab-luminance)))
        (send! "view/overlays" :|win-id| "w1"
               :|layers| (list '(:|type| "rect" :|page| 0
                                  :|rect| (0.0 0.0 1.0 1.0)
                                  :|color| "#000000"
                                  :|opacity| 1.0)))
        (let ((opaque (grab-luminance)))
          (assert-true (> (lum-diff baseline opaque)
                          (lum-diff baseline faint))
                       (format nil "opaque must change more than faint: baseline=~a faint=~a opaque=~a"
                               baseline faint opaque)))))))

;;; ── Test: each overlay type renders ──────────────────────────────────────

(deftest test-paint-line-overlay-renders
  "v0.14: a line overlay produces a luminance change vs baseline."
  (with-buffer (buf)
    (let ((baseline (overlay-baseline)))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "line" :|page| 0
                                :|from| (0.0 0.0) :|to| (1.0 1.0)
                                :|color| "#FF00FF"
                                :|width| 8
                                :|opacity| 1.0)))
      (let ((after (grab-luminance)))
        (assert-true (>= (lum-diff baseline after) 1.0)
                     "line overlay produces visible delta")))))

(deftest test-paint-text-overlay-renders
  "v0.14: a text overlay produces a luminance change vs baseline."
  (with-buffer (buf)
    (let ((baseline (overlay-baseline)))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "text" :|page| 0
                                :|pos| (0.2 0.5) :|text| "HELLO"
                                :|color| "#000000"
                                :|size| 48.0 :|opacity| 1.0)))
      (let ((after (grab-luminance)))
        (assert-true (>= (lum-diff baseline after) 1.0)
                     "text overlay produces visible delta")))))

;;; ── Test: many overlays compound ─────────────────────────────────────────

(deftest test-paint-many-overlays-compound
  "v0.14: 10 black opaque rects across the page produce a strictly
   larger luminance shift than 1 such rect."
  (with-buffer (buf)
    (let ((baseline (overlay-baseline)))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 0
                                :|rect| (0.0 0.0 0.1 0.1)
                                :|color| "#000000" :|opacity| 1.0)))
      (let ((one (grab-luminance))
            (many-layers
              (loop for i from 0 below 10
                    collect `(:|type| "rect" :|page| 0
                              :|rect| (,(* 0.1 i) 0.0 ,(* 0.1 (1+ i)) 1.0)
                              :|color| "#000000" :|opacity| 1.0))))
        (send! "view/overlays" :|win-id| "w1" :|layers| many-layers)
        (let ((many (grab-luminance)))
          (assert-true (> (lum-diff baseline many)
                          (lum-diff baseline one))
                       (format nil "10 rects affect more than 1: baseline=~a one=~a many=~a"
                               baseline one many)))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Tests below require test/grab-region — a v0.14 helper that grabs
;;; avg-luminance over an arbitrary [x0,y0,x1,y1] sub-rectangle (in
;;; widget-pixel coords). Without it we can only say "something changed";
;;; with it we can say "THIS area specifically changed colour, others
;;; didn't".
;;;
;;; These are explicitly RED until v0.14 ships test/grab-region.
;;; ════════════════════════════════════════════════════════════════════════

(defun grab-region (x0 y0 x1 y1)
  "Returns avg-luminance over a sub-rectangle of the widget grab.

   v0.14 to add test/grab-region wire command — until then this errors
   and the assertions below fail (RED, as intended)."
  (let ((r (send! "test/grab-region"
                  :|x0| x0 :|y0| y0 :|x1| x1 :|y1| y1)))
    (json-get* r :|data| :|avg-luminance|)))

(deftest test-paint-rect-only-its-region-changes
  "v0.14 + grab-region: a rect at norm coords (0.1, 0.1)-(0.3, 0.3)
   shifts luminance in that region; the region (0.7, 0.7)-(0.9, 0.9)
   stays at baseline."
  (with-buffer (buf)
    (send! "view/overlays" :|win-id| "w1" :|layers| nil)
    (let* ((g (json-get* (send! "test/grab-window") :|data|))
           (w (getf g :|width|))
           (h (getf g :|height|))
           (touched-base   (grab-region (round (* 0.1 w)) (round (* 0.1 h))
                                         (round (* 0.3 w)) (round (* 0.3 h))))
           (untouched-base (grab-region (round (* 0.7 w)) (round (* 0.7 h))
                                         (round (* 0.9 w)) (round (* 0.9 h)))))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 0
                                :|rect| (0.1 0.1 0.3 0.3)
                                :|color| "#000000" :|opacity| 1.0)))
      (let ((touched-after   (grab-region (round (* 0.1 w)) (round (* 0.1 h))
                                           (round (* 0.3 w)) (round (* 0.3 h))))
            (untouched-after (grab-region (round (* 0.7 w)) (round (* 0.7 h))
                                           (round (* 0.9 w)) (round (* 0.9 h)))))
        (assert-true (>= (lum-diff touched-base touched-after) 5.0)
                     "covered region's luminance moved")
        (assert-true (<  (lum-diff untouched-base untouched-after) 1.0)
                     "uncovered region stayed")))))

(deftest test-paint-z-order-later-wins
  "v0.14 + grab-region: two opaque rects overlap; the later-listed
   one's colour dominates the intersection."
  (with-buffer (buf)
    (let* ((g (json-get* (send! "test/grab-window") :|data|))
           (w (getf g :|width|))
           (h (getf g :|height|)))
      ;; First red, then white-ish (lighter) on top — the intersection
      ;; should be lighter (higher luminance) than pure red.
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 0
                                :|rect| (0.2 0.2 0.6 0.6)
                                :|color| "#FF0000" :|opacity| 1.0)
                             '(:|type| "rect" :|page| 0
                                :|rect| (0.4 0.4 0.8 0.8)
                                :|color| "#FFFFFF" :|opacity| 1.0)))
      ;; Sample only the intersection (0.4, 0.4)-(0.6, 0.6) — both rects
      ;; cover this. Pure red luminance ≈ 76; pure white ≈ 255. If z-order
      ;; respected (white on top), intersection should be near 255.
      (let ((intersection (grab-region (round (* 0.4 w)) (round (* 0.4 h))
                                        (round (* 0.6 w)) (round (* 0.6 h)))))
        (assert-true (> intersection 150.0)
                     (format nil "intersection should be near-white (~a)"
                             intersection))))))

(deftest test-paint-color-applied
  "v0.14 + grab-region: a pure-black opaque rect produces a region
   luminance near 0; a pure-white opaque rect produces near 255."
  (with-buffer (buf)
    (let* ((g (json-get* (send! "test/grab-window") :|data|))
           (w (getf g :|width|))
           (h (getf g :|height|)))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 0
                                :|rect| (0.2 0.2 0.8 0.8)
                                :|color| "#000000" :|opacity| 1.0)))
      (let ((black-lum (grab-region (round (* 0.3 w)) (round (* 0.3 h))
                                     (round (* 0.7 w)) (round (* 0.7 h)))))
        (assert-true (< black-lum 30.0)
                     (format nil "black rect → low luminance (~a)" black-lum)))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 0
                                :|rect| (0.2 0.2 0.8 0.8)
                                :|color| "#FFFFFF" :|opacity| 1.0)))
      (let ((white-lum (grab-region (round (* 0.3 w)) (round (* 0.3 h))
                                     (round (* 0.7 w)) (round (* 0.7 h)))))
        (assert-true (> white-lum 220.0)
                     (format nil "white rect → high luminance (~a)" white-lum))))))
