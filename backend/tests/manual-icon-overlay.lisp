;;;; v0.40 manual smoke test for the new "icon" overlay type.
;;;;
;;;; Pre-req: Limn running headless on $LIMN_SOCKET with a fixture PDF.
;;;; Sends:
;;;;   buffer/open  fixture.pdf
;;;;   view/overlays icon at page-norm (0.5, 0.5), size=20, shape=note,
;;;;                 color=#FFAA00
;;;; Verifies:
;;;;   - test/sample-pixel at the icon center is ~orange (R≈255, G≈170)
;;;;   - test/sample-pixel well outside (e.g. (10,10)) is transparent
;;;;   - all four shapes ("note", "circle", "square", "bookmark") at
;;;;     least produce non-transparent pixels at the requested center

(in-package #:cl-user)
(require :sb-bsd-sockets)

(defparameter *here*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil))
(load (namestring (merge-pathnames "framework.lisp" *here*)))
(in-package #:limn/test)

(let ((sock (sb-ext:posix-getenv "LIMN_SOCKET"))
      (fixture (sb-ext:posix-getenv "LIMN_FIXTURE")))
  (when sock (setf *socket-path* sock))
  (when fixture (setf *fixture-pdf* fixture)))

(connect!)

(defun open-fixture ()
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)))
    (unless (eq (getf r :|ok|) t)
      (error "engine-load failed: ~S" r))
    ;; Force a resize so the overlay raster has non-zero size.
    (send! "test/inject-resize" :|win-id| "w1" :|width| 800 :|height| 600)
    r))

(defun clear-overlays () (send! "view/overlays" :|win-id| "w1" :|layers| nil))

(defun sample-pixel (x y)
  (json-get* (send! "test/sample-pixel" :|x| x :|y| y) :|data|))

(defun pixel-print (label p)
  (format t "  ~a: r=~a g=~a b=~a a=~a~%"
          label
          (getf p :|r|) (getf p :|g|) (getf p :|b|) (getf p :|a|)))

(defun assert-orange (px)
  ;; #FFAA00 with alpha 0.85 on transparent substrate ≈ same RGB at full opaque
  ;; pixels in the icon center.  Allow tolerance for any AA on edges.
  (and (>= (getf px :|r|) 200)
       (>= (getf px :|g|) 130) (<= (getf px :|g|) 200)
       (<= (getf px :|b|) 50)
       (> (getf px :|a|) 100)))

(defun assert-transparent (px)
  (= (getf px :|a|) 0))

(format t "→ Opening fixture~%")
(open-fixture)

;;; Get raster dimensions: page-pixel-rect for page 0
(defun page-rect ()
  (json-get* (send! "test/page-pixel-rect" :|win-id| "w1" :|page| 0) :|data|))

;; Trigger one view/overlays cycle to materialise the overlay raster
;; (cmd_view_overlays calls rebuild_overlay_raster which establishes
;; raster dimensions; test/page-pixel-rect reports these dimensions).
(send! "view/overlays" :|win-id| "w1" :|layers| nil)
(let* ((raw-pr (page-rect))
       (pr (if (and raw-pr (plusp (getf raw-pr :|w| 0)))
               raw-pr
               (list :|x| 0 :|y| 0 :|w| 1200 :|h| 900))))
  (format t "page rect (raw=~S, effective=~S)~%" raw-pr pr)

  (format t "~%→ Test 1: shape \"note\" at (0.5, 0.5)~%")
  (clear-overlays)
  (send! "view/overlays" :|win-id| "w1"
         :|layers| (list `(:|type| "icon" :|page| 0
                            :|x| 0.5 :|y| 0.5
                            :|shape| "note"
                            :|color| "#FFAA00"
                            :|size| 24)))
  ;; Compute widget center px from page-rect
  (let* ((cx (+ (getf pr :|x|) (round (* 0.5 (getf pr :|w|)))))
         (cy (+ (getf pr :|y|) (round (* 0.5 (getf pr :|h|))))))
    (let ((center (sample-pixel cx cy))
          (corner (sample-pixel 5 5)))
      (pixel-print "center (expect orange)" center)
      (pixel-print "(5,5)  (expect transparent)" corner)
      (assert (assert-orange center) ()
              "icon center is not orange — got ~S" center)
      (assert (assert-transparent corner) ()
              "(5,5) is not transparent — got ~S" corner)
      (format t "  OK~%")))

  (format t "~%→ Test 2: shape \"circle\" at (0.3, 0.3)~%")
  (clear-overlays)
  (send! "view/overlays" :|win-id| "w1"
         :|layers| (list `(:|type| "icon" :|page| 0
                            :|x| 0.3 :|y| 0.3
                            :|shape| "circle"
                            :|color| "#00FF00"
                            :|size| 30 :|opacity| 1.0)))
  (let* ((cx (+ (getf pr :|x|) (round (* 0.3 (getf pr :|w|)))))
         (cy (+ (getf pr :|y|) (round (* 0.3 (getf pr :|h|))))))
    (let ((center (sample-pixel cx cy)))
      (pixel-print "circle center (expect green)" center)
      (assert (and (<= (getf center :|r|) 50)
                   (>= (getf center :|g|) 200)
                   (<= (getf center :|b|) 50))
              () "circle center not green: ~S" center)
      (format t "  OK~%")))

  (format t "~%→ Test 3: shape \"square\" at (0.7, 0.3)~%")
  (clear-overlays)
  (send! "view/overlays" :|win-id| "w1"
         :|layers| (list `(:|type| "icon" :|page| 0
                            :|x| 0.7 :|y| 0.3
                            :|shape| "square"
                            :|color| "#0000FF"
                            :|size| 30 :|opacity| 1.0)))
  (let* ((cx (+ (getf pr :|x|) (round (* 0.7 (getf pr :|w|)))))
         (cy (+ (getf pr :|y|) (round (* 0.3 (getf pr :|h|))))))
    (let ((center (sample-pixel cx cy)))
      (pixel-print "square center (expect blue)" center)
      (assert (and (<= (getf center :|r|) 50)
                   (<= (getf center :|g|) 50)
                   (>= (getf center :|b|) 200))
              () "square center not blue: ~S" center)
      (format t "  OK~%")))

  (format t "~%→ Test 4: shape \"bookmark\" at (0.5, 0.7)~%")
  (clear-overlays)
  (send! "view/overlays" :|win-id| "w1"
         :|layers| (list `(:|type| "icon" :|page| 0
                            :|x| 0.5 :|y| 0.7
                            :|shape| "bookmark"
                            :|color| "#FF0000"
                            :|size| 30 :|opacity| 1.0)))
  ;; Bookmark center: the V-notch is in the lower middle, so sample
  ;; slightly above center (still inside the polygon).
  (let* ((cx (+ (getf pr :|x|) (round (* 0.5 (getf pr :|w|)))))
         (cy (- (+ (getf pr :|y|) (round (* 0.7 (getf pr :|h|)))) 8)))
    (let ((center (sample-pixel cx cy)))
      (pixel-print "bookmark upper-mid (expect red)" center)
      (assert (and (>= (getf center :|r|) 200)
                   (<= (getf center :|g|) 50)
                   (<= (getf center :|b|) 50))
              () "bookmark not red: ~S" center)
      (format t "  OK~%")))

  (format t "~%→ Test 5: default color (no :color field) → #FFAA00~%")
  (clear-overlays)
  (send! "view/overlays" :|win-id| "w1"
         :|layers| (list `(:|type| "icon" :|page| 0
                            :|x| 0.5 :|y| 0.5
                            :|shape| "square"
                            :|size| 24 :|opacity| 1.0)))
  (let* ((cx (+ (getf pr :|x|) (round (* 0.5 (getf pr :|w|)))))
         (cy (+ (getf pr :|y|) (round (* 0.5 (getf pr :|h|))))))
    (let ((center (sample-pixel cx cy)))
      (pixel-print "default-color center (expect orange #FFAA00)" center)
      (assert (assert-orange center)
              () "default color not orange: ~S" center)
      (format t "  OK~%")))

  (clear-overlays)
  (format t "~%ALL ICON TESTS PASS~%"))

(disconnect!)
(sb-ext:exit :code 0)
