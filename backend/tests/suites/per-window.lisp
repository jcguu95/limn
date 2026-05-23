;;;; v0.15 per-window independent DocumentView — Qt-tier protocol tests.
;;;;
;;;; Contract (SPEC v0.8 §12 v0.15):
;;;;   Each Limn window keeps its OWN page / zoom / offset / dark-mode /
;;;;   rotation / overlays / buffer binding. The single physical Qt
;;;;   PdfViewOpenGLWidget mirrors *only the focused window's* state.
;;;;
;;;;   - view/set on a non-focused window mutates THAT window only.
;;;;   - bridge/win-focus saves the live DV's drift back into the old
;;;;     focused LimnWindow, then makes the live DV reflect the new
;;;;     focused window's state.
;;;;   - view/get :|win-id| always reports the per-window state, never
;;;;     leaks the focused window's state into a non-focused query.
;;;;
;;;; These tests sit at the JSON-protocol tier — they don't touch
;;;; pixels. The OS-level pixel verification lives in
;;;; e2e/batch-os-per-window.lisp.

(in-package #:limn/test)

;;; ── helpers ───────────────────────────────────────────────────────────

(defun split! (&key (from "w1") (dir "h"))
  "bridge/win-split FROM in DIR; return the new win-b id (or nil on fail)."
  (let ((r (send! "bridge/win-split" :|win-id| from :|dir| dir)))
    (and (eq (getf r :|ok|) t)
         (json-get* r :|data| :|win-b|))))

(defun load-into! (win path)
  "engine-load PATH into WIN; return buffer-id."
  (let ((r (send! "bridge/engine-load" :|win-id| win
                  :|engine| "mupdf" :|path| path)))
    (and (eq (getf r :|ok|) t)
         (json-get* r :|data| :|buffer-id|))))

(defun view-of (win)
  "Return the :|data| plist from view/get on WIN."
  (let ((r (send! "view/get" :|win-id| win)))
    (and (eq (getf r :|ok|) t) (getf r :|data|))))

;;; ── A. per-window state isolation (every field) ──────────────────────
;;;
;;; For each settable field: split into w1+w2, set distinct values,
;;; verify view/get on each reports its OWN value. These are the
;;; primary RED markers — current code shares state across windows
;;; because there's only one live DV.

(deftest test-pw-isolation-page
  "page is independent per window."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        (assert-ok (send! "view/set" :|win-id| "w1" :|page| 2))
        (assert-ok (send! "view/set" :|win-id| w2   :|page| 5))
        (assert-equal 2 (getf (view-of "w1") :|page|) "w1 page=2")
        (assert-equal 5 (getf (view-of w2)   :|page|) "w2 page=5")
        (send! "bridge/win-close" :|win-id| w2)))))

(deftest test-pw-isolation-zoom
  "zoom is independent per window."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        (send! "view/set" :|win-id| "w1" :|zoom| 1.25)
        (send! "view/set" :|win-id| w2   :|zoom| 2.5)
        (let ((z1 (getf (view-of "w1") :|zoom|))
              (z2 (getf (view-of w2)   :|zoom|)))
          (assert-true (< (abs (- z1 1.25)) 0.01) "w1 zoom≈1.25")
          (assert-true (< (abs (- z2 2.5))  0.01) "w2 zoom≈2.5"))
        (send! "bridge/win-close" :|win-id| w2)))))

(deftest test-pw-isolation-offset-y
  "offset-y is independent per window."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        (send! "view/set" :|win-id| "w1" :|offset-y| 100.0)
        (send! "view/set" :|win-id| w2   :|offset-y| 400.0)
        (let ((o1 (getf (view-of "w1") :|offset-y|))
              (o2 (getf (view-of w2)   :|offset-y|)))
          (assert-true (< (abs (- o1 100.0)) 1.0) "w1 offset-y≈100")
          (assert-true (< (abs (- o2 400.0)) 1.0) "w2 offset-y≈400"))
        (send! "bridge/win-close" :|win-id| w2)))))

(deftest test-pw-isolation-offset-x
  "offset-x is independent per window."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        (send! "view/set" :|win-id| "w1" :|offset-x|  50.0)
        (send! "view/set" :|win-id| w2   :|offset-x| 200.0)
        (let ((x1 (getf (view-of "w1") :|offset-x|))
              (x2 (getf (view-of w2)   :|offset-x|)))
          (assert-true (< (abs (- x1  50.0)) 1.0) "w1 offset-x≈50")
          (assert-true (< (abs (- x2 200.0)) 1.0) "w2 offset-x≈200"))
        (send! "bridge/win-close" :|win-id| w2)))))

(deftest test-pw-isolation-dark-mode
  "engine-params :dark-mode is independent per window."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        (send! "view/set" :|win-id| "w1"
               :|engine-params| (list :|dark-mode| t))
        (send! "view/set" :|win-id| w2
               :|engine-params| (list :|dark-mode| nil))
        (let ((d1 (json-get* (view-of "w1") :|engine-params| :|dark-mode|))
              (d2 (json-get* (view-of w2)   :|engine-params| :|dark-mode|)))
          (assert-true  (eq d1 t)     "w1 dark-mode=true")
          (assert-true  (or (eq d2 nil) (eq d2 :false))
                        "w2 dark-mode=false"))
        (send! "bridge/win-close" :|win-id| w2)))))

(deftest test-pw-isolation-rotation
  "engine-params :rotation is independent per window."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        (send! "view/set" :|win-id| "w1"
               :|engine-params| (list :|rotation| 90))
        (send! "view/set" :|win-id| w2
               :|engine-params| (list :|rotation| 270))
        (let ((r1 (json-get* (view-of "w1") :|engine-params| :|rotation|))
              (r2 (json-get* (view-of w2)   :|engine-params| :|rotation|)))
          (assert-equal 90  r1 "w1 rotation=90")
          (assert-equal 270 r2 "w2 rotation=270"))
        (send! "bridge/win-close" :|win-id| w2)))))

(deftest test-pw-isolation-overlays
  "v0.14 overlays must remain per-window after v0.15 refactor (regression guard)."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        (send! "view/overlays" :|win-id| "w1"
               :|layers| (list '(:|type| "rect" :|page| 0
                                  :|rect| (0.0 0.0 1.0 1.0)
                                  :|color| "#FF0000" :|opacity| 1.0)))
        (send! "view/overlays" :|win-id| w2 :|layers| nil)
        (assert-equal 1 (getf (view-of "w1") :|overlay-count|) "w1 has 1")
        (assert-equal 0 (getf (view-of w2)   :|overlay-count|) "w2 has 0")
        (send! "bridge/win-close" :|win-id| w2)))))

(deftest test-pw-isolation-buffer-id
  "Each window can hold a DIFFERENT buffer-id."
  (with-buffer (bA)
    (let ((w2 (split!)))
      (when w2
        (let ((bB (load-into! w2 *fixture-pdf*)))
          (assert-true (and bA bB) "both buffers loaded")
          (assert-true (not (string= bA bB))
                       "buffer-ids differ (independent loads)")
          (assert-equal bA (getf (view-of "w1") :|buffer-id|) "w1 → bA")
          (assert-equal bB (getf (view-of w2)   :|buffer-id|) "w2 → bB")
          (send! "buffer/close" :|buffer-id| bB))
        (send! "bridge/win-close" :|win-id| w2)))))

;;; ── B. non-focused mutation must not touch live widget ───────────────

(deftest test-pw-set-non-focused-doesnt-touch-focused
  "view/set on a non-focused window must not perturb the focused window's state."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        (send! "view/set" :|win-id| "w1" :|page| 1)
        (send! "bridge/win-focus" :|win-id| "w1")
        (let ((before (getf (view-of "w1") :|page|)))
          (send! "view/set" :|win-id| w2 :|page| 4)
          (assert-equal before (getf (view-of "w1") :|page|)
                        "w1 page unchanged after view/set on w2"))
        (send! "bridge/win-close" :|win-id| w2)))))

;;; ── C. focus switch saves / restores per-window state ────────────────

(deftest test-pw-focus-switch-preserves-source
  "After focusing away and back, the original window's state is intact."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        (send! "bridge/win-focus" :|win-id| "w1")
        (send! "view/set" :|win-id| "w1" :|page| 3)
        (send! "view/set" :|win-id| "w1" :|zoom| 1.75)
        (send! "view/set" :|win-id| "w1" :|offset-y| 222.0)
        (send! "bridge/win-focus" :|win-id| w2)
        (send! "view/set" :|win-id| w2 :|page| 5)
        (send! "bridge/win-focus" :|win-id| "w1")
        (let ((d (view-of "w1")))
          (assert-equal 3 (getf d :|page|) "page preserved")
          (assert-true (< (abs (- (getf d :|zoom|) 1.75)) 0.01)
                       "zoom preserved")
          (assert-true (< (abs (- (getf d :|offset-y|) 222.0)) 1.0)
                       "offset-y preserved"))
        (send! "bridge/win-close" :|win-id| w2)))))

(deftest test-pw-focus-switch-restores-target
  "Focusing a window makes its (previously-set) state live in the widget."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        ;; Pre-arrange both windows distinctly while neither switch has happened.
        (send! "view/set" :|win-id| "w1" :|page| 0)
        (send! "view/set" :|win-id| w2   :|page| 4)
        (send! "view/set" :|win-id| w2   :|zoom| 2.0)
        ;; Now focus w2 — the live DV must adopt w2's snapshot.
        (assert-ok (send! "bridge/win-focus" :|win-id| w2))
        (let ((d (view-of w2)))
          (assert-equal 4 (getf d :|page|) "live page == w2.page")
          (assert-true (< (abs (- (getf d :|zoom|) 2.0)) 0.01)
                       "live zoom == w2.zoom"))
        (send! "bridge/win-close" :|win-id| w2)))))

(deftest test-pw-focus-switches-active-buffer
  "Focusing a window with a different buffer makes that buffer the live one."
  (with-buffer (bA)
    (let ((w2 (split!)))
      (when w2
        (let ((bB (load-into! w2 *fixture-pdf*)))
          (send! "bridge/win-focus" :|win-id| "w1")
          (assert-equal bA (getf (view-of "w1") :|buffer-id|)
                        "w1 focused → live = bA")
          (send! "bridge/win-focus" :|win-id| w2)
          (assert-equal bB (getf (view-of w2)   :|buffer-id|)
                        "w2 focused → live = bB")
          (when bB (send! "buffer/close" :|buffer-id| bB)))
        (send! "bridge/win-close" :|win-id| w2)))))

;;; ── D. lifecycle — closing a sibling, splitting deeper ───────────────

(deftest test-pw-close-sibling-leaves-state
  "Closing w2 must not perturb w1's page/zoom/offset/overlays."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (send! "view/set" :|win-id| "w1" :|page| 4)
        (send! "view/set" :|win-id| "w1" :|zoom| 1.5)
        (send! "view/overlays" :|win-id| "w1"
               :|layers| (list '(:|type| "rect" :|page| 0
                                  :|rect| (0.0 0.0 0.5 0.5)
                                  :|color| "#00FF00" :|opacity| 1.0)))
        (send! "bridge/win-close" :|win-id| w2)
        (let ((d (view-of "w1")))
          (assert-equal 4 (getf d :|page|) "page survives sibling close")
          (assert-true (< (abs (- (getf d :|zoom|) 1.5)) 0.01)
                       "zoom survives sibling close")
          (assert-equal 1 (getf d :|overlay-count|)
                        "overlays survive sibling close"))))))

(deftest test-pw-three-windows-all-independent
  "Three windows: page/zoom values stay distinct on each."
  (with-buffer (b)
    (let* ((w2 (split!))
           (w3 (and w2 (split! :from w2))))
      (when (and w2 w3)
        (load-into! w2 *fixture-pdf*)
        (load-into! w3 *fixture-pdf*)
        (send! "view/set" :|win-id| "w1" :|page| 1)
        (send! "view/set" :|win-id| w2   :|page| 2)
        (send! "view/set" :|win-id| w3   :|page| 3)
        (assert-equal 1 (getf (view-of "w1") :|page|))
        (assert-equal 2 (getf (view-of w2)   :|page|))
        (assert-equal 3 (getf (view-of w3)   :|page|))
        (send! "bridge/win-close" :|win-id| w3)
        (send! "bridge/win-close" :|win-id| w2)))))

;;; ── E. floating windows behave the same way ──────────────────────────

(deftest test-pw-float-has-independent-state
  "A floating window's view/set is independent of the tiled w1."
  (with-buffer (b)
    (let* ((cr (send! "bridge/win-float-create"
                      :|buffer-id| b :|x| 0 :|y| 0
                      :|width| 300 :|height| 200))
           (fw (and (eq (getf cr :|ok|) t)
                    (json-get* cr :|data| :|win-id|))))
      (when fw
        (send! "view/set" :|win-id| "w1" :|page| 1)
        (send! "view/set" :|win-id| fw   :|page| 4)
        (assert-equal 1 (getf (view-of "w1") :|page|) "tiled w1 page=1")
        (assert-equal 4 (getf (view-of fw)   :|page|) "float page=4")
        (send! "bridge/win-close" :|win-id| fw)))))

;;; ── F. bridge/win-list reflects focus correctly ──────────────────────

(deftest test-pw-win-list-focus-tracks-switches
  "bridge/win-list reports exactly one :|focused| true entry, and it
   follows bridge/win-focus."
  (with-buffer (b)
    (let ((w2 (split!)))
      (when w2
        (load-into! w2 *fixture-pdf*)
        (send! "bridge/win-focus" :|win-id| w2)
        (let* ((l   (send! "bridge/win-list"))
               (es  (getf l :|data|))
               (foc (remove-if-not (lambda (e) (getf e :|focused|)) es)))
          (assert-equal 1 (length foc) "exactly one focused entry after switch")
          (assert-equal w2 (getf (first foc) :|win-id|)
                        "focused entry is w2"))
        (send! "bridge/win-focus" :|win-id| "w1")
        (let* ((l   (send! "bridge/win-list"))
               (es  (getf l :|data|))
               (foc (remove-if-not (lambda (e) (getf e :|focused|)) es)))
          (assert-equal "w1" (getf (first foc) :|win-id|)
                        "focused entry returns to w1"))
        (send! "bridge/win-close" :|win-id| w2)))))
