;;;; Batch 24: v0.14 view/overlays paintGL — VM-level e2e.
;;;;
;;;; Same strict per-pixel design as suites/overlays-paint.lisp (Qt-level),
;;;; just running against the REAL binary in Linux container + real Xvfb
;;;; backing store + real openbox WM + xdotool key inject.
;;;;
;;;; Test wire primitives required (v0.14 — ALL RED until shipped):
;;;;   test/sample-pixel   :x :y                          → {r g b a}
;;;;   test/region-bbox    :x0 :y0 :x1 :y1 :match-color  → {x y w h}
;;;;   test/region-hash    :x0 :y0 :x1 :y1                → {sha256}
;;;;   test/page-pixel-rect :win-id :page                 → {x y w h}
;;;;   test/last-text-render                               → {font-family ...}

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defun xdotool (&rest args)
  (let ((p (sb-ext:run-program "xdotool" args :search t
                                :wait t :output t :error t)))
    (unless (zerop (sb-ext:process-exit-code p))
      (error "xdotool ~{~a~^ ~} exited non-zero" args))))

(defun xdotool-stdout (&rest args)
  (with-output-to-string (s)
    (let ((p (sb-ext:run-program "xdotool" args :search t
                                  :wait t :output s :error t)))
      (unless (zerop (sb-ext:process-exit-code p))
        (error "xdotool ~{~a~^ ~} exited non-zero" args)))))

(defun wait-for-window-by-name (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((s (string-trim '(#\Space #\Newline #\Tab)
                             (handler-case
                                 (xdotool-stdout "search" "--name" name)
                               (error () "")))))
        (unless (zerop (length s))
          (return (parse-integer
                   (subseq s 0 (or (position #\Newline s) (length s)))))))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-ov"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

;;; ── primitive wrappers (limn:call against real socket) ────────────────

(defun sample-pixel (x y)
  (let ((r (limn:call "test/sample-pixel" :|x| x :|y| y)))
    (limn/bridge:response-data r)))

(defun region-bbox (x0 y0 x1 y1 match-color)
  (let ((r (limn:call "test/region-bbox" :|x0| x0 :|y0| y0
                       :|x1| x1 :|y1| y1 :|match-color| match-color)))
    (limn/bridge:response-data r)))

(defun page-pixel-rect (&key (win-id "w1") (page 0))
  (let ((r (limn:call "test/page-pixel-rect" :|win-id| win-id :|page| page)))
    (limn/bridge:response-data r)))

(defun last-text-render ()
  (let ((r (limn:call "test/last-text-render")))
    (limn/bridge:response-data r)))

(defun pixel-equals (px r g b &optional (tol 5))
  (and px
       (<= (abs (- (or (getf px :|r|) 0) r)) tol)
       (<= (abs (- (or (getf px :|g|) 0) g)) tol)
       (<= (abs (- (or (getf px :|b|) 0) b)) tol)))

(defun pixels-near (a b &optional (tol 5))
  (and a b
       (<= (abs (- (or (getf a :|r|) 0) (or (getf b :|r|) 0))) tol)
       (<= (abs (- (or (getf a :|g|) 0) (or (getf b :|g|) 0))) tol)
       (<= (abs (- (or (getf a :|b|) 0) (or (getf b :|b|) 0))) tol)))

(defun norm-to-px-xy (nx ny pr)
  "Translate norm coord → widget pixel coord using a page-pixel-rect."
  (values (+ (getf pr :|x|) (round (* nx (getf pr :|w|))))
          (+ (getf pr :|y|) (round (* ny (getf pr :|h|))))))

(defun clear-ov () (limn:call "view/overlays" :|win-id| "w1" :|layers| nil))

;;; ── session start ─────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-ov-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-ov.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

;;; ── Ω1: state round-trip (view/get :overlays) ─────────────────────

    (format t "~%── Ω1: view/get :overlays round-trip ──~%")
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.1 0.1 0.5 0.5)
                                   :|color| "#FF0000" :|opacity| 0.7)))
    (sleep 0.2)
    (let* ((d (limn/bridge:response-data (limn:call "view/get" :|win-id| "w1")))
           (ov (getf d :|overlays|))
           (oc (getf d :|overlay-count|)))
      (check (format nil "Ω1 — :overlay-count == 1 (got ~a)" oc)
             (eql oc 1))
      (check (format nil "Ω1 — :overlays list len 1 (got ~a)"
                     (and (listp ov) (length ov)))
             (and (listp ov) (= 1 (length ov)))))

;;; ── Ω2: per-pixel RED color ──────────────────────────────────────

    (format t "~%── Ω2: red rect → sampled pixels are RGB(255,0,0) ──~%")
    (clear-ov) (sleep 0.2)
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.2 0.2 0.8 0.8)
                                   :|color| "#FF0000" :|opacity| 1.0)))
    (sleep 0.3)
    (let ((pr (page-pixel-rect)))
      (if (null pr)
          (check "Ω2 — page-pixel-rect returns data" nil)
          ;; Sample 3 points inside the rect
          (dolist (nxy '((0.3 0.3) (0.5 0.5) (0.7 0.7)))
            (multiple-value-bind (px py)
                (norm-to-px-xy (car nxy) (cadr nxy) pr)
              (let ((p (sample-pixel px py)))
                (check (format nil "Ω2 — pixel at norm ~a is red (got ~a)" nxy p)
                       (pixel-equals p 255 0 0)))))))

;;; ── Ω3: per-pixel BLUE (different color, no false-pass) ─────────

    (format t "~%── Ω3: blue rect → sampled pixels are RGB(0,0,255) ──~%")
    (clear-ov) (sleep 0.2)
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.2 0.2 0.8 0.8)
                                   :|color| "#0000FF" :|opacity| 1.0)))
    (sleep 0.3)
    (let ((pr (page-pixel-rect)))
      (when pr
        (multiple-value-bind (px py) (norm-to-px-xy 0.5 0.5 pr)
          (let ((p (sample-pixel px py)))
            (check (format nil "Ω3 — center pixel is blue (got ~a)" p)
                   (pixel-equals p 0 0 255))))))

;;; ── Ω4: opacity 0.5 black computes to ~baseline/2 ─────────────────

    (format t "~%── Ω4: opacity 0.5 black blends to baseline/2 ──~%")
    (clear-ov) (sleep 0.3)
    (let* ((pr (page-pixel-rect)))
      (when pr
        (multiple-value-bind (cx cy) (norm-to-px-xy 0.5 0.5 pr)
          (let ((baseline (sample-pixel cx cy)))
            (limn:call "view/overlays" :|win-id| "w1"
                        :|layers| (list '(:|type| "rect" :|page| 0
                                           :|rect| (0.2 0.2 0.8 0.8)
                                           :|color| "#000000"
                                           :|opacity| 0.5)))
            (sleep 0.3)
            (let* ((after (sample-pixel cx cy))
                   (exp-r (round (/ (or (getf baseline :|r|) 0) 2)))
                   (exp-g (round (/ (or (getf baseline :|g|) 0) 2)))
                   (exp-b (round (/ (or (getf baseline :|b|) 0) 2))))
              (check (format nil "Ω4 — α=0.5 black: baseline=~a after=~a expect=(~a,~a,~a)"
                             baseline after exp-r exp-g exp-b)
                     (pixel-equals after exp-r exp-g exp-b 8)))))))

;;; ── Ω5: bbox precision — region-bbox matches request ───────────

    (format t "~%── Ω5: region-bbox of red rect matches request ±2px ──~%")
    (clear-ov) (sleep 0.2)
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.25 0.25 0.75 0.75)
                                   :|color| "#FF0000" :|opacity| 1.0)))
    (sleep 0.3)
    (let ((pr (page-pixel-rect)))
      (when pr
        (let* ((bb (region-bbox (getf pr :|x|) (getf pr :|y|)
                                 (+ (getf pr :|x|) (getf pr :|w|))
                                 (+ (getf pr :|y|) (getf pr :|h|))
                                 "#FF0000"))
               (exp-x (+ (getf pr :|x|) (round (* 0.25 (getf pr :|w|)))))
               (exp-w (round (* 0.5 (getf pr :|w|)))))
          (check (format nil "Ω5 — bbox x ~a ≈ expect ~a ±2"
                         (and bb (getf bb :|x|)) exp-x)
                 (and bb (<= (abs (- (getf bb :|x|) exp-x)) 2)))
          (check (format nil "Ω5 — bbox w ~a ≈ expect ~a ±2"
                         (and bb (getf bb :|w|)) exp-w)
                 (and bb (<= (abs (- (getf bb :|w|) exp-w)) 2))))))

;;; ── Ω6: page filter — page-5 overlay invisible on page-0 view ───

    (format t "~%── Ω6: overlay on page 5 → page-0 center pixel unchanged ──~%")
    (limn:call "view/set" :|win-id| "w1" :|page| 0)
    (sleep 0.2)
    (clear-ov) (sleep 0.3)
    (let ((pr (page-pixel-rect)))
      (when pr
        (multiple-value-bind (cx cy) (norm-to-px-xy 0.5 0.5 pr)
          (let ((baseline (sample-pixel cx cy)))
            (limn:call "view/overlays" :|win-id| "w1"
                        :|layers| (list '(:|type| "rect" :|page| 5
                                           :|rect| (0.0 0.0 1.0 1.0)
                                           :|color| "#FF0000" :|opacity| 1.0)))
            (sleep 0.3)
            (let ((after (sample-pixel cx cy)))
              (check (format nil "Ω6 — page-5 overlay didn't touch page-0 (baseline=~a after=~a)"
                             baseline after)
                     (pixels-near baseline after)))))))

;;; ── Ω7: z-order — intersection shows later layer ────────────────

    (format t "~%── Ω7: z-order intersection is the later (blue) color ──~%")
    (clear-ov) (sleep 0.2)
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.2 0.2 0.6 0.6)
                                   :|color| "#FF0000" :|opacity| 1.0)
                                '(:|type| "rect" :|page| 0
                                   :|rect| (0.4 0.4 0.8 0.8)
                                   :|color| "#0000FF" :|opacity| 1.0)))
    (sleep 0.3)
    (let ((pr (page-pixel-rect)))
      (when pr
        (multiple-value-bind (cx cy) (norm-to-px-xy 0.5 0.5 pr)
          (let ((p (sample-pixel cx cy)))
            (check (format nil "Ω7 — intersection center is blue (got ~a)" p)
                   (pixel-equals p 0 0 255))))))

;;; ── Ω8: clear restores pixel AND state ────────────────────────────

    (format t "~%── Ω8: set→clear restores pixel + view/get state ──~%")
    (clear-ov) (sleep 0.3)
    (let ((pr (page-pixel-rect)))
      (when pr
        (multiple-value-bind (cx cy) (norm-to-px-xy 0.5 0.5 pr)
          (let ((baseline (sample-pixel cx cy)))
            (limn:call "view/overlays" :|win-id| "w1"
                        :|layers| (list '(:|type| "rect" :|page| 0
                                           :|rect| (0.2 0.2 0.8 0.8)
                                           :|color| "#00FF00" :|opacity| 1.0)))
            (sleep 0.3)
            (clear-ov) (sleep 0.3)
            (let* ((after (sample-pixel cx cy))
                   (st (limn/bridge:response-data
                        (limn:call "view/get" :|win-id| "w1")))
                   (oc (getf st :|overlay-count|)))
              (check (format nil "Ω8 — :overlay-count back to 0 (got ~a)" oc)
                     (eql oc 0))
              (check (format nil "Ω8 — pixel restored (~a vs ~a)" baseline after)
                     (pixels-near baseline after)))))))

;;; ── Ω9: overlays survive xdotool key inject (real keystroke) ─────

    (format t "~%── Ω9: red rect survives j/k xdotool inject ──~%")
    (limn:call "view/set" :|win-id| "w1" :|page| 0)
    (sleep 0.2)
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.3 0.3 0.7 0.7)
                                   :|color| "#FF0000" :|opacity| 1.0)))
    (sleep 0.3)
    (xdotool "key" "--clearmodifiers" "j")
    (sleep 0.2)
    (xdotool "key" "--clearmodifiers" "k")
    (sleep 0.2)
    (let ((pr (page-pixel-rect)))
      (when pr
        (multiple-value-bind (cx cy) (norm-to-px-xy 0.5 0.5 pr)
          (let* ((p (sample-pixel cx cy))
                 (st (limn/bridge:response-data
                      (limn:call "view/get" :|win-id| "w1")))
                 (oc (getf st :|overlay-count|)))
            (check (format nil "Ω9 — :overlay-count == 1 after key inject (got ~a)" oc)
                   (eql oc 1))
            (check (format nil "Ω9 — pixel still red after key inject (got ~a)" p)
                   (pixel-equals p 255 0 0))))))

;;; ── Ω10: engine-load resets overlays (state + pixel) ────────────

    (format t "~%── Ω10: engine-load resets overlays ──~%")
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.2 0.2 0.8 0.8)
                                   :|color| "#FF0000" :|opacity| 1.0)))
    (sleep 0.2)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.5)
    (let* ((st (limn/bridge:response-data (limn:call "view/get" :|win-id| "w1")))
           (oc (getf st :|overlay-count|)))
      (check (format nil "Ω10 — engine-load resets :overlay-count to 0 (got ~a)" oc)
             (eql oc 0)))
    (let ((pr (page-pixel-rect)))
      (when pr
        (multiple-value-bind (cx cy) (norm-to-px-xy 0.5 0.5 pr)
          (let ((p (sample-pixel cx cy)))
            (check (format nil "Ω10 — center pixel not red after engine-load (got ~a)" p)
                   (not (pixel-equals p 255 0 0)))))))

;;; ── Ω11: text overlay introspect — font matches request ────────

    (format t "~%── Ω11: text overlay font introspect ──~%")
    (clear-ov) (sleep 0.2)
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "text" :|page| 0
                                   :|pos| (0.3 0.5) :|text| "Hello"
                                   :|font| "DejaVu Sans"
                                   :|color| "#000000" :|size| 48.0
                                   :|opacity| 1.0)))
    (sleep 0.3)
    (let ((info (last-text-render)))
      (check (format nil "Ω11 — test/last-text-render returns info (got ~a)" info)
             (not (null info)))
      (when info
        (check (format nil "Ω11 — font-family == 'DejaVu Sans' (got ~s)"
                       (getf info :|font-family|))
               (equal "DejaVu Sans" (getf info :|font-family|)))
        (check (format nil "Ω11 — pixel-size == 48 (got ~a)"
                       (getf info :|pixel-size|))
               (eql 48 (getf info :|pixel-size|)))
        (check (format nil "Ω11 — glyphs-substituted == 0 (got ~a)"
                       (getf info :|glyphs-substituted|))
               (eql 0 (getf info :|glyphs-substituted|)))))

;;; ── Ω12: structural font sanity — 'I' < 0.5 × 'M' ────────────────

    (format t "~%── Ω12: I bbox width < 0.5 × M bbox width ──~%")
    (clear-ov) (sleep 0.2)
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "text" :|page| 0
                                   :|pos| (0.3 0.5) :|text| "I"
                                   :|font| "DejaVu Sans"
                                   :|color| "#000000" :|size| 96.0
                                   :|opacity| 1.0)))
    (sleep 0.3)
    (let ((i-bbox (and (last-text-render) (getf (last-text-render) :|bbox|))))
      (clear-ov) (sleep 0.2)
      (limn:call "view/overlays" :|win-id| "w1"
                  :|layers| (list '(:|type| "text" :|page| 0
                                     :|pos| (0.3 0.5) :|text| "M"
                                     :|font| "DejaVu Sans"
                                     :|color| "#000000" :|size| 96.0
                                     :|opacity| 1.0)))
      (sleep 0.3)
      (let ((m-bbox (and (last-text-render) (getf (last-text-render) :|bbox|))))
        (check (format nil "Ω12 — both bboxes available (I=~a M=~a)" i-bbox m-bbox)
               (and i-bbox m-bbox))
        (when (and i-bbox m-bbox)
          (let ((iw (getf i-bbox :|w|))
                (mw (getf m-bbox :|w|)))
            (check (format nil "Ω12 — M width (~a) > 2× I width (~a)" mw iw)
                   (and iw mw (> mw (* 2 iw))))))))

;;; ── Ω13: per-window isolation ─────────────────────────────────────

    (format t "~%── Ω13: bridge/win-split — w2 doesn't see w1's overlays ──~%")
    (clear-ov) (sleep 0.2)
    (limn:call "bridge/win-split" :|orient| "horizontal")
    (sleep 0.3)
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.0 0.0 0.5 0.5)
                                   :|color| "#FF0000" :|opacity| 0.5)))
    (sleep 0.2)
    (let* ((d2 (limn/bridge:response-data (limn:call "view/get" :|win-id| "w2")))
           (oc2 (getf d2 :|overlay-count|)))
      (check (format nil "Ω13 — w2's :overlay-count is 0 (got ~a)" oc2)
             (eql oc2 0)))

;;; ── final verdict ────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 24 overlays paintGL green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-ov")
        (rename-file "/tmp/.limn/init.lisp.stash-ov" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
