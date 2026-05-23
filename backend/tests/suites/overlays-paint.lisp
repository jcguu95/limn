;;;; v0.14 — paint-level overlay rendering tests, strict & deterministic.
;;;;
;;;; Design principles (settled 2026-05-23 with user):
;;;;
;;;;   1. PER-PIXEL, NOT AVERAGES.
;;;;      Average luminance hides "half the rect didn't render" bugs.
;;;;      We sample specific known coordinates and check exact channel
;;;;      values, or query bboxes / hashes server-side.
;;;;
;;;;   2. DETERMINISTIC, NOT STOCHASTIC.
;;;;      QT_QPA_PLATFORM=offscreen + software raster + nailed-down
;;;;      QFont knobs + locked-version fonts (DejaVu in nix container)
;;;;      give byte-exact output across runs. The Chromium / WebKit
;;;;      layout-test playbook.
;;;;
;;;;   3. FAST — TINY WIRE PAYLOADS.
;;;;      Never transport whole framebuffers as base64 PNG. C++ does
;;;;      the work; we move 4 bytes (a pixel), 16 bytes (a bbox),
;;;;      or 32 bytes (a hash) over the bridge.
;;;;
;;;;   4. THREE LAYERS FOR FONTS.
;;;;      (a) Qt-introspect — test/last-text-render returns the QFont
;;;;          Qt actually used + glyphs-substituted count. Catches
;;;;          "silent fallback to wrong font".
;;;;      (b) Structural sanity — "I" must be > 2× narrower than "M".
;;;;          Catches "fallback to box glyphs", "no glyph loaded",
;;;;          "all glyphs identical".
;;;;      (c) Golden hash — one anchor case ("A" DejaVu Sans 48pt) hashed
;;;;          & committed. Catches Qt/font rendering changes that
;;;;          (a) and (b) miss.
;;;;
;;;; Test wire primitives required (v0.14, NONE exist yet — RED):
;;;;
;;;;   test/sample-pixel   :x :y                           → {r g b a}
;;;;   test/region-bbox    :x0 :y0 :x1 :y1 :match-color   → {x y w h} | null
;;;;   test/region-hash    :x0 :y0 :x1 :y1                 → {sha256}
;;;;   test/page-pixel-rect :win-id :page                  → {x y w h} | null
;;;;   test/last-text-render                                → {font-family pixel-size weight italic glyphs-substituted bbox}
;;;;
;;;; All of these intentionally return errors today — the tests below
;;;; will RED until v0.14 ships them.

(in-package #:limn/test)

;;; ── helpers (v0.14 wire primitives) ───────────────────────────────────────

(defun sample-pixel (x y)
  "Returns {:r :g :b :a} at widget pixel coordinate (X, Y).
   RED until v0.14 ships test/sample-pixel."
  (json-get* (send! "test/sample-pixel" :|x| x :|y| y) :|data|))

(defun region-bbox (x0 y0 x1 y1 match-color)
  "Returns {:x :y :w :h} bbox of all pixels within (x0,y0)-(x1,y1)
   that match MATCH-COLOR (hex string like \"#FF0000\", with a small
   per-channel tolerance applied server-side). NIL if no match."
  (json-get* (send! "test/region-bbox"
                    :|x0| x0 :|y0| y0 :|x1| x1 :|y1| y1
                    :|match-color| match-color)
             :|data|))

(defun region-hash (x0 y0 x1 y1)
  "Returns sha256 hex string of the raw RGBA bytes in region."
  (json-get* (send! "test/region-hash"
                    :|x0| x0 :|y0| y0 :|x1| x1 :|y1| y1)
             :|data| :|sha256|))

(defun page-pixel-rect (&key (win-id "w1") (page 0))
  "Returns {:x :y :w :h} = where PAGE of WIN-ID is rendered on the
   widget right now. NIL if page not currently visible. Used by
   tests to translate page-norm coords [0,1]² to widget pixel coords."
  (json-get* (send! "test/page-pixel-rect" :|win-id| win-id :|page| page)
             :|data|))

(defun last-text-render ()
  "Returns {:font-family :pixel-size :weight :italic
            :glyphs-substituted :bbox} for the most recent text
   overlay rendered. NIL if no text overlay rendered yet."
  (json-get* (send! "test/last-text-render") :|data|))

;;; ── helpers (derived) ──────────────────────────────────────────────────

(defun norm-to-px (norm-x norm-y page-rect)
  "Translate page-relative (NORM-X, NORM-Y) in [0,1]² to widget pixels
   using a PAGE-RECT plist from page-pixel-rect."
  (let ((px (+ (getf page-rect :|x|)
               (round (* norm-x (getf page-rect :|w|)))))
        (py (+ (getf page-rect :|y|)
               (round (* norm-y (getf page-rect :|h|))))))
    (values px py)))

(defun pixels-near (a b &optional (tol 5))
  "True if two pixel plists agree in R/G/B within tolerance (default 5)."
  (and a b
       (<= (abs (- (getf a :|r|) (getf b :|r|))) tol)
       (<= (abs (- (getf a :|g|) (getf b :|g|))) tol)
       (<= (abs (- (getf a :|b|) (getf b :|b|))) tol)))

(defun pixel-equals (px r g b &optional (tol 5))
  "True if PX (plist) ≈ (R, G, B) within TOL per channel."
  (and (<= (abs (- (getf px :|r|) r)) tol)
       (<= (abs (- (getf px :|g|) g)) tol)
       (<= (abs (- (getf px :|b|) b)) tol)))

(defun load-golden-hash (name)
  "Read tests/fixtures/golden/NAME.sha256 (one line). Returns NIL if
   file doesn't exist — used to RED tests that haven't been baselined."
  (let ((path (rel (format nil "fixtures/golden/~a.sha256" name))))
    (when (probe-file path)
      (with-open-file (s path)
        (string-trim '(#\Space #\Newline #\Tab) (read-line s nil ""))))))

(defun clear-overlays (&optional (win-id "w1"))
  (send! "view/overlays" :|win-id| win-id :|layers| nil))

;;; ════════════════════════════════════════════════════════════════════════
;;; A. Color — per-channel verification at known sample points.
;;;
;;; A pure-red opaque rect must paint exactly RGB(255, 0, 0) inside its
;;; rect. Sample 9 points (3×3 grid inside the rect), all must match.
;;; This catches partial-rendering, wrong-color, and channel-bleed bugs
;;; that averages would silently pass.
;;; ════════════════════════════════════════════════════════════════════════

(defun paint-color-test (color-hex r g b)
  "Helper: set a rect filling page-norm (0.2,0.2)-(0.8,0.8) with the
   given color, opacity 1.0, and verify 9 sample points inside are
   (R,G,B) ± tol."
  (clear-overlays)
  (send! "view/overlays" :|win-id| "w1"
         :|layers| (list `(:|type| "rect" :|page| 0
                            :|rect| (0.2 0.2 0.8 0.8)
                            :|color| ,color-hex :|opacity| 1.0)))
  (let ((pr (page-pixel-rect)))
    (unless pr (error "page-pixel-rect returned nil — RED"))
    ;; 3×3 grid inside the rect, well inside to avoid anti-alias edges
    (dolist (nxy '((0.3 0.3) (0.5 0.3) (0.7 0.3)
                   (0.3 0.5) (0.5 0.5) (0.7 0.5)
                   (0.3 0.7) (0.5 0.7) (0.7 0.7)))
      (multiple-value-bind (px py)
          (norm-to-px (car nxy) (cadr nxy) pr)
        (let ((p (sample-pixel px py)))
          (assert-true (pixel-equals p r g b)
                       (format nil "~a at norm ~a → expect (~a,~a,~a) got ~a"
                               color-hex nxy r g b p)))))))

(deftest test-paint-color-red
  "v0.14: pure red rect → 9 sampled points inside are RGB(255, 0, 0) ±5."
  (with-buffer (buf)
    (paint-color-test "#FF0000" 255 0 0)))

(deftest test-paint-color-green
  "v0.14: pure green rect → 9 sampled points are RGB(0, 255, 0) ±5."
  (with-buffer (buf)
    (paint-color-test "#00FF00" 0 255 0)))

(deftest test-paint-color-blue
  "v0.14: pure blue rect → 9 sampled points are RGB(0, 0, 255) ±5."
  (with-buffer (buf)
    (paint-color-test "#0000FF" 0 0 255)))

(deftest test-paint-color-yellow
  "v0.14: pure yellow rect → 9 sampled points are RGB(255, 255, 0) ±5.
   Two-channel-dominant case catches single-channel-only render bugs."
  (with-buffer (buf)
    (paint-color-test "#FFFF00" 255 255 0)))

(deftest test-paint-color-black
  "v0.14: black opaque rect → all sampled pixels RGB(0,0,0) ±5."
  (with-buffer (buf)
    (paint-color-test "#000000" 0 0 0)))

(deftest test-paint-color-white
  "v0.14: white opaque rect → all sampled pixels RGB(255,255,255) ±5."
  (with-buffer (buf)
    (paint-color-test "#FFFFFF" 255 255 255)))

;;; ════════════════════════════════════════════════════════════════════════
;;; B. Geometry — bbox of painted pixels matches requested coords.
;;;
;;; region-bbox does a server-side scan and tells us where the painted
;;; (matching color) pixels actually are. We compare against the expected
;;; pixel rect (derived from page-norm coords + page-pixel-rect).
;;; ════════════════════════════════════════════════════════════════════════

(deftest test-paint-rect-bbox-matches-request
  "v0.14: a red rect at norm (0.25, 0.25, 0.75, 0.75) → region-bbox
   for #FF0000 must equal the expected pixel rect within ±2px on
   each side (allows for anti-alias edge inclusion)."
  (with-buffer (buf)
    (clear-overlays)
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list '(:|type| "rect" :|page| 0
                              :|rect| (0.25 0.25 0.75 0.75)
                              :|color| "#FF0000" :|opacity| 1.0)))
    (let ((pr (page-pixel-rect)))
      (unless pr (error "page-pixel-rect nil"))
      (let* ((expect-x (+ (getf pr :|x|) (round (* 0.25 (getf pr :|w|)))))
             (expect-y (+ (getf pr :|y|) (round (* 0.25 (getf pr :|h|)))))
             (expect-w (round (* 0.5 (getf pr :|w|))))
             (expect-h (round (* 0.5 (getf pr :|h|))))
             (bb (region-bbox (getf pr :|x|) (getf pr :|y|)
                              (+ (getf pr :|x|) (getf pr :|w|))
                              (+ (getf pr :|y|) (getf pr :|h|))
                              "#FF0000")))
        (assert-true bb "region-bbox found red pixels")
        (assert-true (<= (abs (- (getf bb :|x|) expect-x)) 2)
                     (format nil "bbox x ~a ≈ expect ~a ±2"
                             (getf bb :|x|) expect-x))
        (assert-true (<= (abs (- (getf bb :|y|) expect-y)) 2)
                     (format nil "bbox y ~a ≈ expect ~a ±2"
                             (getf bb :|y|) expect-y))
        (assert-true (<= (abs (- (getf bb :|w|) expect-w)) 2)
                     (format nil "bbox w ~a ≈ expect ~a ±2"
                             (getf bb :|w|) expect-w))
        (assert-true (<= (abs (- (getf bb :|h|) expect-h)) 2)
                     (format nil "bbox h ~a ≈ expect ~a ±2"
                             (getf bb :|h|) expect-h))))))

(deftest test-paint-rect-doesnt-bleed-outside
  "v0.14: a rect at norm (0.3, 0.3, 0.5, 0.5) → sample points OUTSIDE
   (at norm 0.1, 0.1 and 0.8, 0.8) must equal the baseline (no overlay)
   colour. Catches 'rect drew bigger than asked'."
  (with-buffer (buf)
    (clear-overlays)
    (let ((pr (page-pixel-rect)))
      (unless pr (error "page-pixel-rect nil"))
      ;; Baseline pixels at the corners
      (multiple-value-bind (bx by) (norm-to-px 0.1 0.1 pr)
        (multiple-value-bind (cx cy) (norm-to-px 0.8 0.8 pr)
          (let ((bb (sample-pixel bx by))
                (cc (sample-pixel cx cy)))
            (send! "view/overlays" :|win-id| "w1"
                   :|layers| (list '(:|type| "rect" :|page| 0
                                      :|rect| (0.3 0.3 0.5 0.5)
                                      :|color| "#FF0000" :|opacity| 1.0)))
            (let ((bb2 (sample-pixel bx by))
                  (cc2 (sample-pixel cx cy)))
              (assert-true (pixels-near bb bb2)
                           (format nil "corner (0.1,0.1) unchanged: ~a → ~a"
                                   bb bb2))
              (assert-true (pixels-near cc cc2)
                           (format nil "corner (0.8,0.8) unchanged: ~a → ~a"
                                   cc cc2)))))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; C. Opacity — per-pixel computed expectation.
;;;
;;; For a fully opaque black rect over a known background color B,
;;; expected pixel = (0,0,0). For opacity α, expected = (1-α)*B.
;;; We sample the center pixel and check |actual - expected| ≤ 5 per
;;; channel — catches "opacity ignored" (would show as full 0,0,0
;;; regardless of α) and "wrong blend mode".
;;; ════════════════════════════════════════════════════════════════════════

(defun opacity-blend-test (alpha)
  "Set a black rect with given alpha, sample center, return the
   sampled pixel + baseline center pixel for the caller to compare."
  (clear-overlays)
  (let* ((pr (page-pixel-rect))
         (cx (+ (getf pr :|x|) (round (* 0.5 (getf pr :|w|)))))
         (cy (+ (getf pr :|y|) (round (* 0.5 (getf pr :|h|)))))
         (baseline (sample-pixel cx cy)))
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list `(:|type| "rect" :|page| 0
                              :|rect| (0.2 0.2 0.8 0.8)
                              :|color| "#000000" :|opacity| ,alpha)))
    (values (sample-pixel cx cy) baseline)))

(deftest test-paint-opacity-1-fully-opaque
  "v0.14: opacity 1.0 black → center pixel exactly (0,0,0) ±5."
  (with-buffer (buf)
    (multiple-value-bind (after _baseline) (opacity-blend-test 1.0)
      (declare (ignore _baseline))
      (assert-true (pixel-equals after 0 0 0)
                   (format nil "opaque black → ~a" after)))))

(deftest test-paint-opacity-0-fully-transparent
  "v0.14: opacity 0.0 → center pixel must match baseline (no change)."
  (with-buffer (buf)
    (multiple-value-bind (after baseline) (opacity-blend-test 0.0)
      (assert-true (pixels-near baseline after)
                   (format nil "α=0 unchanged: baseline=~a after=~a"
                           baseline after)))))

(deftest test-paint-opacity-half-blends
  "v0.14: opacity 0.5 black → each channel ≈ baseline/2 ±5.
   This catches 'opacity got ignored entirely' (would be 0,0,0)
   and 'wrong blend formula' (would be off by more than ±5)."
  (with-buffer (buf)
    (multiple-value-bind (after baseline) (opacity-blend-test 0.5)
      (let ((expect-r (round (/ (getf baseline :|r|) 2)))
            (expect-g (round (/ (getf baseline :|g|) 2)))
            (expect-b (round (/ (getf baseline :|b|) 2))))
        (assert-true (pixel-equals after expect-r expect-g expect-b)
                     (format nil "α=0.5 black over bg ~a → expect ~a got ~a"
                             baseline
                             (list expect-r expect-g expect-b)
                             after))))))

(deftest test-paint-opacity-monotonic
  "v0.14: as alpha increases, each channel of the blend moves
   monotonically toward 0 (because we're blending toward black).
   Catches 'opacity scale flipped' or 'opacity quantized incorrectly'."
  (with-buffer (buf)
    (let ((r-at-0.0 (getf (multiple-value-list (opacity-blend-test 0.0)) 0))
          (r-at-0.5 (getf (multiple-value-list (opacity-blend-test 0.5)) 0))
          (r-at-1.0 (getf (multiple-value-list (opacity-blend-test 1.0)) 0)))
      ;; r-at-X is :r of the sample-pixel returned. Pull out :r field:
      ;; (correction below — see note in next assertion)
      (declare (ignore r-at-0.0 r-at-0.5 r-at-1.0))
      ;; Rewritten with explicit pulls:
      (let* ((p0 (multiple-value-bind (a _) (opacity-blend-test 0.0)
                   (declare (ignore _)) a))
             (p5 (multiple-value-bind (a _) (opacity-blend-test 0.5)
                   (declare (ignore _)) a))
             (p1 (multiple-value-bind (a _) (opacity-blend-test 1.0)
                   (declare (ignore _)) a)))
        (assert-true (>= (getf p0 :|r|) (getf p5 :|r|))
                     (format nil "p0.r=~a >= p5.r=~a"
                             (getf p0 :|r|) (getf p5 :|r|)))
        (assert-true (>= (getf p5 :|r|) (getf p1 :|r|))
                     (format nil "p5.r=~a >= p1.r=~a"
                             (getf p5 :|r|) (getf p1 :|r|)))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; D. Page filter — overlay's :page field actually filters.
;;;
;;; Sample a known-noise-free interior pixel before and after setting an
;;; overlay targeting a DIFFERENT page than the one currently shown;
;;; pixel must NOT change.
;;; ════════════════════════════════════════════════════════════════════════

(deftest test-paint-overlay-on-other-page-not-rendered
  "v0.14: viewing page 0, set rect on page 5 → center pixel unchanged."
  (with-buffer (buf)
    (send! "view/set" :|win-id| "w1" :|page| 0)
    (clear-overlays)
    (let* ((pr (page-pixel-rect))
           (cx (+ (getf pr :|x|) (round (* 0.5 (getf pr :|w|)))))
           (cy (+ (getf pr :|y|) (round (* 0.5 (getf pr :|h|)))))
           (baseline (sample-pixel cx cy)))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 5
                                :|rect| (0.0 0.0 1.0 1.0)
                                :|color| "#FF0000" :|opacity| 1.0)))
      (let ((after (sample-pixel cx cy)))
        (assert-true (pixels-near baseline after)
                     (format nil "page-5 overlay must not touch page-0: ~a → ~a"
                             baseline after))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; E. Z-order — later layer wins at intersection.
;;;
;;; Two opaque rects overlapping. Sample the intersection — must be the
;;; LATER rect's color. Sample non-overlap of each — must be each rect's
;;; color. Catches "z-order reversed" and "only first layer rendered".
;;; ════════════════════════════════════════════════════════════════════════

(deftest test-paint-z-order-intersection-shows-later
  "v0.14: red rect on bottom, blue rect on top, intersection pixel
   must be blue (255 in :b, ~0 in :r and :g)."
  (with-buffer (buf)
    (clear-overlays)
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list '(:|type| "rect" :|page| 0
                              :|rect| (0.2 0.2 0.6 0.6)
                              :|color| "#FF0000" :|opacity| 1.0)
                           '(:|type| "rect" :|page| 0
                              :|rect| (0.4 0.4 0.8 0.8)
                              :|color| "#0000FF" :|opacity| 1.0)))
    (let* ((pr (page-pixel-rect))
           ;; Intersection: (0.4,0.4)-(0.6,0.6) — sample at (0.5, 0.5)
           (cx (+ (getf pr :|x|) (round (* 0.5 (getf pr :|w|)))))
           (cy (+ (getf pr :|y|) (round (* 0.5 (getf pr :|h|))))))
      (let ((p (sample-pixel cx cy)))
        (assert-true (pixel-equals p 0 0 255)
                     (format nil "intersection is blue: ~a" p))))))

(deftest test-paint-z-order-non-overlap-keeps-own-color
  "v0.14: same setup, but sample (0.3, 0.3) — only red rect there,
   pixel must be red. Sample (0.7, 0.7) — only blue rect, pixel blue."
  (with-buffer (buf)
    (clear-overlays)
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list '(:|type| "rect" :|page| 0
                              :|rect| (0.2 0.2 0.6 0.6)
                              :|color| "#FF0000" :|opacity| 1.0)
                           '(:|type| "rect" :|page| 0
                              :|rect| (0.4 0.4 0.8 0.8)
                              :|color| "#0000FF" :|opacity| 1.0)))
    (let ((pr (page-pixel-rect)))
      (multiple-value-bind (rx ry) (norm-to-px 0.3 0.3 pr)
        (let ((p (sample-pixel rx ry)))
          (assert-true (pixel-equals p 255 0 0)
                       (format nil "red-only zone: ~a" p))))
      (multiple-value-bind (bx by) (norm-to-px 0.7 0.7 pr)
        (let ((p (sample-pixel bx by)))
          (assert-true (pixel-equals p 0 0 255)
                       (format nil "blue-only zone: ~a" p)))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; F. Line — endpoints + bbox geometry.
;;;
;;; A line from (norm 0.2, 0.2) to (0.8, 0.8) — sample both endpoints
;;; (close to them, allowing for anti-alias), they should be the line
;;; color. And region-bbox of line color should span the diagonal.
;;; ════════════════════════════════════════════════════════════════════════

(deftest test-paint-line-renders-along-path
  "v0.14: a thick magenta line from (0.2,0.2) to (0.8,0.8).
   Sample both endpoints — pixel near each end should be magenta."
  (with-buffer (buf)
    (clear-overlays)
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list '(:|type| "line" :|page| 0
                              :|from| (0.2 0.2) :|to| (0.8 0.8)
                              :|color| "#FF00FF" :|width| 8
                              :|opacity| 1.0)))
    (let ((pr (page-pixel-rect)))
      (multiple-value-bind (x1 y1) (norm-to-px 0.21 0.21 pr)
        (let ((p (sample-pixel x1 y1)))
          (assert-true (pixel-equals p 255 0 255 30)
                       (format nil "near start (0.21,0.21): ~a" p))))
      (multiple-value-bind (x2 y2) (norm-to-px 0.79 0.79 pr)
        (let ((p (sample-pixel x2 y2)))
          (assert-true (pixel-equals p 255 0 255 30)
                       (format nil "near end (0.79,0.79): ~a" p)))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; G. Text rendering — three-layer font verification.
;;;
;;; (a) Qt introspect: test/last-text-render must echo the requested font
;;;     and report glyphs-substituted == 0 (no silent fallback).
;;; (b) Structural: "I" must be much narrower than "M" — proves a real
;;;     proportional font is in use, not box glyphs.
;;; (c) Golden hash: a single anchor case ("A" DejaVu Sans 48pt) hashed
;;;     and committed. Catches any change in rasterization.
;;; ════════════════════════════════════════════════════════════════════════

;;; ── G.a Qt introspect ────────────────────────────────────────────────

(deftest test-paint-text-introspect-font-matches-request
  "v0.14 + test/last-text-render: requesting font 'DejaVu Sans' must
   make Qt actually use 'DejaVu Sans'."
  (with-buffer (buf)
    (clear-overlays)
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list '(:|type| "text" :|page| 0
                              :|pos| (0.3 0.5) :|text| "Hello"
                              :|font| "DejaVu Sans"
                              :|color| "#000000" :|size| 48.0
                              :|opacity| 1.0)))
    (let ((info (last-text-render)))
      (assert-true info "test/last-text-render returns data")
      (assert-equal "DejaVu Sans" (getf info :|font-family|)
                    "Qt used the requested font family")
      (assert-equal 48 (getf info :|pixel-size|)
                    "pixel-size matches request"))))

(deftest test-paint-text-introspect-no-silent-fallback
  "v0.14: glyphs-substituted MUST be 0 for an available font.
   If > 0, Qt is silently falling back glyphs and the test font
   isn't actually being used."
  (with-buffer (buf)
    (clear-overlays)
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list '(:|type| "text" :|page| 0
                              :|pos| (0.3 0.5) :|text| "ABCDEFG"
                              :|font| "DejaVu Sans"
                              :|color| "#000000" :|size| 48.0
                              :|opacity| 1.0)))
    (let ((info (last-text-render)))
      (assert-equal 0 (getf info :|glyphs-substituted|)
                    "no glyph substitution for ASCII in DejaVu Sans"))))

(deftest test-paint-text-introspect-missing-font-explicit
  "v0.14: requesting a clearly nonexistent font must NOT silently
   succeed with a default. Either:
   (a) view/overlays returns ok=false with explicit 'unknown font',
   (b) ok=true but glyphs-substituted > 0 (fallback was needed).
   Silent fallback (ok=true, substituted=0) is a contract violation."
  (with-buffer (buf)
    (clear-overlays)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "text" :|page| 0
                            :|pos| (0.3 0.5) :|text| "X"
                            :|font| "ThisFontDoesNotExist-XYZ-12345"
                            :|color| "#000000" :|size| 48.0
                            :|opacity| 1.0)))))
      (if (eq (getf r :|ok|) :false)
          (assert-true t "view/overlays explicitly rejected missing font")
          (let ((info (last-text-render)))
            (assert-true (> (getf info :|glyphs-substituted|) 0)
                         "if ok=true, glyphs-substituted must be > 0"))))))

;;; ── G.b Structural ──────────────────────────────────────────────────

(deftest test-paint-text-bbox-i-narrower-than-m
  "v0.14: 'I' must have < 0.5 × the bbox width of 'M' at same font/size.
   Catches box-glyph fallback, fixed-width fonts (where I and M would be
   equal width — which is wrong for DejaVu Sans, our requested font)."
  (with-buffer (buf)
    (clear-overlays)
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list '(:|type| "text" :|page| 0
                              :|pos| (0.3 0.5) :|text| "I"
                              :|font| "DejaVu Sans"
                              :|color| "#000000" :|size| 96.0
                              :|opacity| 1.0)))
    (let ((i-bbox (getf (last-text-render) :|bbox|)))
      (clear-overlays)
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "text" :|page| 0
                                :|pos| (0.3 0.5) :|text| "M"
                                :|font| "DejaVu Sans"
                                :|color| "#000000" :|size| 96.0
                                :|opacity| 1.0)))
      (let ((m-bbox (getf (last-text-render) :|bbox|)))
        (let ((i-w (getf i-bbox :|w|))
              (m-w (getf m-bbox :|w|)))
          (assert-true (< (* 2 i-w) m-w)
                       (format nil "M (~a) more than 2× wider than I (~a)"
                               m-w i-w)))))))

(deftest test-paint-text-bbox-nonzero
  "v0.14: text overlay must produce a bbox with nonzero width AND
   height. Catches 'no glyph rendered' (bbox would be 0×0)."
  (with-buffer (buf)
    (clear-overlays)
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list '(:|type| "text" :|page| 0
                              :|pos| (0.3 0.5) :|text| "Hello"
                              :|font| "DejaVu Sans"
                              :|color| "#000000" :|size| 48.0
                              :|opacity| 1.0)))
    (let ((bbox (getf (last-text-render) :|bbox|)))
      (assert-true (> (getf bbox :|w|) 0) "text width > 0")
      (assert-true (> (getf bbox :|h|) 0) "text height > 0"))))

;;; ── G.c Golden hash ─────────────────────────────────────────────────

(deftest test-paint-text-golden-hash-A-dejavu48
  "v0.14: rendering 'A' in DejaVu Sans 48pt at (norm 0.3, 0.5),
   opaque black, with locked Qt knobs — region hash must equal the
   golden committed in fixtures/golden/text-A-dejavu48.sha256.

   On first ship: golden file absent → test RED → human captures hash
   once → commit → test green & stable across runs."
  (with-buffer (buf)
    (clear-overlays)
    (send! "view/overlays" :|win-id| "w1"
           :|layers| (list '(:|type| "text" :|page| 0
                              :|pos| (0.3 0.5) :|text| "A"
                              :|font| "DejaVu Sans"
                              :|color| "#000000" :|size| 48.0
                              :|opacity| 1.0)))
    (let* ((pr (page-pixel-rect))
           ;; Sample a 200×200 box around the text position
           (cx (+ (getf pr :|x|) (round (* 0.3 (getf pr :|w|)))))
           (cy (+ (getf pr :|y|) (round (* 0.5 (getf pr :|h|)))))
           (hash (region-hash (- cx 100) (- cy 100)
                              (+ cx 100) (+ cy 100)))
           (golden (load-golden-hash "text-A-dejavu48")))
      (assert-true golden
                   "fixtures/golden/text-A-dejavu48.sha256 exists (RED until baselined)")
      (assert-equal golden hash
                    "rendered text hash matches golden"))))

;;; ════════════════════════════════════════════════════════════════════════
;;; H. State + paint cross-check.
;;;
;;; After set→clear, both state (view/get :overlays) AND pixels must
;;; return to baseline. Catches "paint state updated but framebuffer
;;; not invalidated" and vice versa.
;;; ════════════════════════════════════════════════════════════════════════

(deftest test-paint-clear-restores-both-state-and-pixels
  "v0.14: set red rect → clear → both view/get :overlays empty AND
   center pixel matches the pre-set baseline."
  (with-buffer (buf)
    (clear-overlays)
    (let* ((pr (page-pixel-rect))
           (cx (+ (getf pr :|x|) (round (* 0.5 (getf pr :|w|)))))
           (cy (+ (getf pr :|y|) (round (* 0.5 (getf pr :|h|)))))
           (baseline (sample-pixel cx cy)))
      (send! "view/overlays" :|win-id| "w1"
             :|layers| (list '(:|type| "rect" :|page| 0
                                :|rect| (0.2 0.2 0.8 0.8)
                                :|color| "#FF0000" :|opacity| 1.0)))
      (let ((mid (sample-pixel cx cy)))
        (assert-true (pixel-equals mid 255 0 0)
                     "after set: pixel is red"))
      (clear-overlays)
      (let ((after (sample-pixel cx cy))
            (state-count (json-get* (send! "view/get" :|win-id| "w1")
                                     :|data| :|overlay-count|)))
        (assert-equal 0 state-count "state cleared")
        (assert-true (pixels-near baseline after)
                     (format nil "pixel restored: baseline=~a after=~a"
                             baseline after))))))
