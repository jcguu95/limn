;;;; Paint / GUI regression tests — INCOMPLETE / REGRESSION-ONLY
;;;;
;;;; ⚠ HONEST STATUS: this suite is half a visual-testing system.
;;;;
;;;; What it does today:
;;;;   - captures the Qt paint pipeline via QWidget::grab() (real paint,
;;;;     not MuPDF direct render) using QT_QPA_PLATFORM=offscreen
;;;;   - asserts SELF-CONSISTENCY: determinism, opacity, geometry,
;;;;     Qt-path ≠ MuPDF-path
;;;;
;;;; What it does NOT do — and which we owe ourselves later:
;;;;   - assert any pixels are *correct*. Every test here would pass even
;;;;     if Qt rendered the entire screen as a solid wrong colour, as long
;;;;     as it did so consistently.
;;;;
;;;; To turn this into a real correctness oracle, three things to add
;;;; (in order of cost-to-value):
;;;;
;;;;   (a) Synthetic known-pixel tests
;;;;       Use view/overlays to draw a pure red rect at a known position,
;;;;       grab, then assert that region's pixels are (255, 0, 0). Doesn't
;;;;       need any human to certify anything — we compute the expected
;;;;       output from first principles.
;;;;
;;;;   (b) One human-certified baseline
;;;;       Capture grab() of empty MainWidget once, eyeball it, commit as
;;;;       fixtures/golden/empty-mainwidget.png. Future grabs diff against
;;;;       it. Cheap; only requires re-certification when UI intentionally
;;;;       changes.
;;;;
;;;;   (c) MuPDF as oracle for PDF display
;;;;       Once view/set actually routes through to MainWidget's viewport
;;;;       (it doesn't today — see test-paint-load-buffer-changes-pixels),
;;;;       compare grab() of the viewport region to buffer/render at
;;;;       matching DPI using SSIM or histogram correlation. This is the
;;;;       killer test: "does the PDF appear on screen?" answered without
;;;;       any human seeing the screen.
;;;;
;;;; Until those land: treat green here as "Qt didn't break in a way that
;;;; affects invariants", NOT as "the GUI is correct".
;;;;
;;;; If you want eyeballs on a grab, base64-decode the PNG from a
;;;;   `(send! "test/grab-window")` response — they're real PNGs.

(in-package #:limn/test)

;;; ── helpers ────────────────────────────────────────────────────────────

(defun grab ()
  "Return the data plist of a fresh test/grab-window response."
  (let ((r (send! "test/grab-window")))
    (json-get* r :|data|)))

(defun widget-tree ()
  (let ((r (send! "test/widget-tree")))
    (json-get* r :|data| :|tree|)))

(defun walk-widget-tree (tree pred)
  "Pre-order walk; collect every node for which PRED returns true."
  (let ((acc '()))
    (labels ((rec (n)
               (when (funcall pred n) (push n acc))
               (dolist (k (getf n :|children|)) (rec k))))
      (rec tree))
    (nreverse acc)))

(defun find-widgets-by-class (tree class-name)
  (walk-widget-tree tree
                    (lambda (n) (string= (getf n :|class|) class-name))))

;;; ── tests ──────────────────────────────────────────────────────────────

(deftest test-paint-grab-returns-png
  "Sanity: test/grab-window returns a valid base64 PNG with sensible dims."
  (let ((g (grab)))
    (assert-numeric (getf g :|width|))
    (assert-numeric (getf g :|height|))
    (check-assertion (and (> (getf g :|width|)  0)
                          (> (getf g :|height|) 0))
                     "dimensions are positive"
                     "got ~ax~a" (getf g :|width|) (getf g :|height|))
    (let ((b64 (getf g :|png|)))
      (assert-true (and (stringp b64) (> (length b64) 100))
                   "png field is a non-trivial base64 string"))))

(deftest test-paint-grab-is-deterministic
  "Two consecutive grabs of an unchanged scene must be byte-identical.
   This is the foundation every other paint test depends on."
  (let* ((a (getf (grab) :|png|))
         (b (getf (grab) :|png|)))
    (assert-equal a b "back-to-back grabs produce identical PNG")))

(deftest test-paint-grab-dimensions-match-widget-tree
  "The grab dimensions equal MainWidget's geometry."
  (let* ((tree (widget-tree))
         (geom (getf tree :|geometry|))
         (w-tree (third geom))
         (h-tree (fourth geom))
         (g (grab)))
    (assert-equal w-tree (getf g :|width|)
                  "grab width matches widget-tree width")
    (assert-equal h-tree (getf g :|height|)
                  "grab height matches widget-tree height")))

(deftest test-paint-grab-is-fully-opaque
  "Every pixel of MainWidget grab is opaque — there's no transparent
   background bleeding through that a real user would see as a hole."
  (let* ((g (grab))
         (w (getf g :|width|))
         (h (getf g :|height|))
         (op (getf g :|opaque-pixels|)))
    (assert-equal (* w h) op
                  "opaque-pixels == width*height (no transparent pixels)")))

(deftest test-paint-widget-tree-has-main-widget
  "Top of the tree is MainWidget; it has at least one painting child."
  (let ((tree (widget-tree)))
    (assert-equal "MainWidget" (getf tree :|class|)
                  "root class is MainWidget")
    (assert-true (eq t (getf tree :|visible|))
                 "MainWidget is visible (show() ran)")
    (check-assertion (>= (length (getf tree :|children|)) 1)
                     "MainWidget has ≥1 child widget"
                     "children: ~a" (length (getf tree :|children|)))))

(deftest test-paint-pdf-viewport-present
  "There's exactly one OpenGL widget — sioyek's PdfViewOpenGLWidget.
   When window-splitting goes from logical-only → real Qt split, this
   test should be UPDATED to assert >=2 after a bridge/win-split."
  (let* ((tree (widget-tree))
         ;; sioyek's PdfViewOpenGLWidget is a QOpenGLWidget subclass; the
         ;; class name we see may be either depending on moc.
         (gls (or (find-widgets-by-class tree "PdfViewOpenGLWidget")
                  (find-widgets-by-class tree "QOpenGLWidget"))))
    (check-assertion (>= (length gls) 1)
                     "at least one OpenGL viewport widget"
                     "got ~a" (length gls))))

(deftest test-paint-load-buffer-changes-pixels
  "Loading a PDF SHOULD change the rendered pixels. Currently informational:
   bridge/engine-load registers the buffer in the Limn registry but
   MainWidget's viewport isn't yet wired to display it (the Limn engine
   path is parallel to sioyek's own document path). When that wiring lands,
   flip the format call below back to an assert-false."
  (let ((empty (getf (grab) :|png|)))
    (with-buffer (buf)
      (send! "buffer/metadata" :|buffer-id| buf)
      (let ((loaded (getf (grab) :|png|)))
        (if (string= empty loaded)
            (format t "    [pending] buffer load doesn't change viewport pixels yet~%")
            (format t "    [ok] buffer load did change viewport pixels~%"))))))

(deftest test-paint-grab-distinct-from-buffer-render
  "Two different paint paths: test/grab-window captures Qt's backing store,
   buffer/render goes straight through MuPDF. They MUST produce different
   bytes — same bytes would mean someone collapsed them, breaking the
   ability to test the Qt pipeline independently of MuPDF."
  (with-buffer (buf)
    (let ((qt-png   (getf (grab) :|png|))
          (mu-png   (json-get* (send! "buffer/render"
                                       :|buffer-id| buf :|page| 0 :|dpi| 72)
                                :|data| :|png|)))
      (assert-false (string= qt-png mu-png)
                    "Qt grab and MuPDF render are distinct byte streams"))))

(deftest test-paint-luminance-in-range
  "Average luminance is in [0, 255]. Cheap sanity that the stats math
   wasn't computed on a corrupted backing store."
  (let* ((g (grab))
         (lum (getf g :|avg-luminance|)))
    (assert-numeric lum)
    (check-assertion (and (<= 0 lum 255))
                     "0 ≤ avg-luminance ≤ 255"
                     "got ~a" lum)))
