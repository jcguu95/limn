;;;; v0.25 §A — defface / display/sync-faces Qt-tier tests  (3 tests)
;;;;
;;;; Tests verify that face definitions propagate from Lisp to C++ and
;;;; that overlay layers with :face field render in the face's foreground
;;;; colour.
;;;;
;;;; Requires a running Limn instance with --test-mode.

(in-package #:limn/test)

;;; ── helpers ──────────────────────────────────────────────────────────────

(defun sync-faces-direct (faces-plist-list)
  "Call display/sync-faces with FACES-PLIST-LIST directly (bypasses Lisp face module).
   Each element: (:name \"name\" :foreground \"#rrggbb\" ...)."
  (send! "display/sync-faces" :|faces| faces-plist-list))

(defun set-face-overlay (win-id page face-name
                         &key (x0 0.2) (y0 0.2) (x1 0.8) (y1 0.8)
                              (opacity 1.0))
  "Set a single rect overlay on WIN-ID using :face FACE-NAME."
  (send! "view/overlays"
         :|win-id| win-id
         :|layers| (list (list :|type| "rect"
                               :|page| page
                               :|face| face-name
                               :|x0| x0 :|y0| y0
                               :|x1| x1 :|y1| y1
                               :|opacity| opacity))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test A1: sync-faces then overlay uses face colour
;;;
;;; Procedure:
;;;   1. Push a face "limn-test-face-red" with foreground "#ff0000"
;;;      via display/sync-faces.
;;;   2. Set a full-page rect overlay using :face "limn-test-face-red".
;;;   3. Sample the centre pixel of the overlay — should be red.

(define-test defface-a1-overlay-uses-face-foreground
  (let* ((doc     (setup-doc-1page))
         (win-id  (getf doc :|win-id|))
         (page    (getf doc :|page|))
         (r       (sync-faces-direct
                   (list (list :|name| "limn-test-face-red"
                               :|foreground| "#ff0000")))))
    (assert-ok r "display/sync-faces should succeed")
    (set-face-overlay win-id page "limn-test-face-red"
                      :x0 0.1 :y0 0.1 :x1 0.9 :y1 0.9)
    (let* ((prect (page-pixel-rect :win-id win-id :page page))
           (cx    (+ (getf prect :|x|) (round (/ (getf prect :|w|) 2))))
           (cy    (+ (getf prect :|y|) (round (/ (getf prect :|h|) 2))))
           (px    (sample-pixel cx cy)))
      (assert-true (pixel-equals px 255 0 0 10)
                   (format nil "centre pixel should be red, got ~s" px)))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test A2: change face → overlay updates on next sync
;;;
;;; Procedure:
;;;   1. Push face "limn-test-face-mutable" with foreground "#0000ff" (blue).
;;;   2. Set overlay with that face — verify blue.
;;;   3. Re-push same face with foreground "#00ff00" (green).
;;;   4. Re-set overlays — verify green.

(define-test defface-a2-face-change-updates-overlay
  (let* ((doc     (setup-doc-1page))
         (win-id  (getf doc :|win-id|))
         (page    (getf doc :|page|)))
    ;; Step 1: blue
    (sync-faces-direct (list (list :|name| "limn-test-face-mutable"
                                   :|foreground| "#0000ff")))
    (set-face-overlay win-id page "limn-test-face-mutable"
                      :x0 0.1 :y0 0.1 :x1 0.9 :y1 0.9)
    (let* ((prect (page-pixel-rect :win-id win-id :page page))
           (cx    (+ (getf prect :|x|) (round (/ (getf prect :|w|) 2))))
           (cy    (+ (getf prect :|y|) (round (/ (getf prect :|h|) 2))))
           (px    (sample-pixel cx cy)))
      (assert-true (pixel-equals px 0 0 255 10)
                   (format nil "step1: expected blue, got ~s" px)))
    ;; Step 2: green
    (sync-faces-direct (list (list :|name| "limn-test-face-mutable"
                                   :|foreground| "#00ff00")))
    (set-face-overlay win-id page "limn-test-face-mutable"
                      :x0 0.1 :y0 0.1 :x1 0.9 :y1 0.9)
    (let* ((prect (page-pixel-rect :win-id win-id :page page))
           (cx    (+ (getf prect :|x|) (round (/ (getf prect :|w|) 2))))
           (cy    (+ (getf prect :|y|) (round (/ (getf prect :|h|) 2))))
           (px    (sample-pixel cx cy)))
      (assert-true (pixel-equals px 0 255 0 10)
                   (format nil "step2: expected green, got ~s" px)))))

;;; ════════════════════════════════════════════════════════════════════════
;;; Test A3: :face overrides :color in the same overlay layer
;;;
;;; Procedure:
;;;   1. Push face "limn-test-face-override" with foreground "#ff0000" (red).
;;;   2. Set overlay with BOTH :color "#0000ff" AND :face "limn-test-face-override".
;;;   3. :face wins → pixel should be red, not blue.

(define-test defface-a3-face-overrides-color
  (let* ((doc     (setup-doc-1page))
         (win-id  (getf doc :|win-id|))
         (page    (getf doc :|page|)))
    (sync-faces-direct (list (list :|name| "limn-test-face-override"
                                   :|foreground| "#ff0000")))
    ;; Layer has both :color (blue) and :face (red) — face wins
    (send! "view/overlays"
           :|win-id| win-id
           :|layers| (list (list :|type| "rect"
                                 :|page| page
                                 :|color| "#0000ff"
                                 :|face|  "limn-test-face-override"
                                 :|x0| 0.1 :|y0| 0.1
                                 :|x1| 0.9 :|y1| 0.9
                                 :|opacity| 1.0)))
    (let* ((prect (page-pixel-rect :win-id win-id :page page))
           (cx    (+ (getf prect :|x|) (round (/ (getf prect :|w|) 2))))
           (cy    (+ (getf prect :|y|) (round (/ (getf prect :|h|) 2))))
           (px    (sample-pixel cx cy)))
      (assert-true (pixel-equals px 255 0 0 10)
                   (format nil "face should override color; got ~s" px)))))
