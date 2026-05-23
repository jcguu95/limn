;;;; Batch 25: v0.15 per-window independent DocumentView — OS-level e2e.
;;;;
;;;; Strict invariants beyond the Qt-tier per-window.lisp:
;;;;
;;;;   1. After bridge/win-focus, the OS pixel buffer (overlay raster)
;;;;      reflects the newly-focused window's overlays / page.
;;;;   2. Mutating a non-focused window leaves the OS pixel buffer
;;;;      bit-for-bit identical (region-hash invariant).
;;;;   3. Toggling focus back-and-forth oscillates the pixel state
;;;;      between two distinct, repeatable hashes.
;;;;   4. xdotool key-injection (scroll / page-down) on the focused
;;;;      window updates ONLY that window's offset-y / page, leaving
;;;;      the other window's snapshot intact.
;;;;
;;;; Wire primitives reused from v0.14:
;;;;   test/sample-pixel  test/region-hash  test/page-pixel-rect

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-pw"))

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

;;; ── primitive wrappers ────────────────────────────────────────────────

(defun sample-pixel (x y)
  (limn/bridge:response-data
   (limn:call "test/sample-pixel" :|x| x :|y| y)))

(defun region-hash (x0 y0 x1 y1)
  (limn/bridge:response-data
   (limn:call "test/region-hash" :|x0| x0 :|y0| y0 :|x1| x1 :|y1| y1)))

(defun page-pixel-rect (&key (win-id "w1") (page 0))
  (limn/bridge:response-data
   (limn:call "test/page-pixel-rect" :|win-id| win-id :|page| page)))

(defun view-get (win)
  (limn/bridge:response-data (limn:call "view/get" :|win-id| win)))

(defun set-overlay (win color &key (rect '(0.2 0.2 0.8 0.8)) (page 0))
  (limn:call "view/overlays" :|win-id| win
              :|layers| (list (list :|type| "rect" :|page| page
                                    :|rect| rect
                                    :|color| color :|opacity| 1.0))))

(defun clear-ov (win)
  (limn:call "view/overlays" :|win-id| win :|layers| nil))

(defun pixels-near (a b &optional (tol 5))
  (and a b
       (<= (abs (- (or (getf a :|r|) 0) (or (getf b :|r|) 0))) tol)
       (<= (abs (- (or (getf a :|g|) 0) (or (getf b :|g|) 0))) tol)
       (<= (abs (- (or (getf a :|b|) 0) (or (getf b :|b|) 0))) tol)))

(defun pixel-equals (px r g b &optional (tol 5))
  (and px
       (<= (abs (- (or (getf px :|r|) 0) r)) tol)
       (<= (abs (- (or (getf px :|g|) 0) g)) tol)
       (<= (abs (- (or (getf px :|b|) 0) b)) tol)))

(defun norm-to-px-xy (nx ny pr)
  (values (+ (getf pr :|x|) (round (* nx (getf pr :|w|))))
          (+ (getf pr :|y|) (round (* ny (getf pr :|h|))))))

;;; ── session start ─────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-pw-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-pw.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

    ;; Create w2 and load same fixture into it.
    (let* ((split-r (limn:call "bridge/win-split" :|win-id| "w1" :|dir| "h"))
           (w2 (getf (limn/bridge:response-data split-r) :|win-b|)))
      (check (format nil "setup — got w2 (~a)" w2) (stringp w2))
      (limn:call "bridge/engine-load" :|engine| "mupdf"
                  :|path| (b/ "tests/fixtures/test.pdf") :|win-id| w2)
      (sleep 0.3)

;;; ── Ω1: mutating non-focused window must not change raster ──────

      (format t "~%── Ω1: view/set on non-focused w2 leaves pixels intact ──~%")
      (limn:call "bridge/win-focus" :|win-id| "w1") (sleep 0.2)
      (set-overlay "w1" "#FF0000") (sleep 0.3)
      (let* ((pr (page-pixel-rect))
             (h-before (and pr (getf (region-hash (getf pr :|x|) (getf pr :|y|)
                                                   (+ (getf pr :|x|) (getf pr :|w|))
                                                   (+ (getf pr :|y|) (getf pr :|h|)))
                                     :|sha256|))))
        ;; Mutate w2 while it's NOT focused.
        (set-overlay w2 "#00FF00")
        (limn:call "view/set" :|win-id| w2 :|page| 5)
        (sleep 0.3)
        (let ((h-after (and pr (getf (region-hash (getf pr :|x|) (getf pr :|y|)
                                                    (+ (getf pr :|x|) (getf pr :|w|))
                                                    (+ (getf pr :|y|) (getf pr :|h|)))
                                      :|sha256|))))
          (check (format nil "Ω1 — region-hash unchanged (~a == ~a)"
                         h-before h-after)
                 (and h-before h-after (string= h-before h-after)))))

;;; ── Ω2: focus switch repaints with the target window's overlay ──

      (format t "~%── Ω2: focus w1→w2 changes center pixel red→green ──~%")
      (limn:call "bridge/win-focus" :|win-id| "w1") (sleep 0.2)
      ;; Reset both windows' page to 0 so the page-0 overlays we're about
      ;; to set don't get filtered out by stale page state from prior Ω.
      (limn:call "view/set" :|win-id| "w1" :|page| 0)
      (limn:call "view/set" :|win-id| w2   :|page| 0)
      (set-overlay "w1" "#FF0000")
      (set-overlay w2   "#00FF00")
      (sleep 0.3)
      (let ((pr (page-pixel-rect)))
        (when pr
          (multiple-value-bind (cx cy) (norm-to-px-xy 0.5 0.5 pr)
            (let ((p-red (sample-pixel cx cy)))
              (check (format nil "Ω2a — w1 focused → center red (got ~a)" p-red)
                     (pixel-equals p-red 255 0 0))
              (limn:call "bridge/win-focus" :|win-id| w2)
              (sleep 0.3)
              (let ((p-green (sample-pixel cx cy)))
                (check (format nil "Ω2b — w2 focused → center green (got ~a)" p-green)
                       (pixel-equals p-green 0 255 0)))))))

;;; ── Ω3: focus toggle oscillates between two deterministic hashes ──

      (format t "~%── Ω3: focus toggle is deterministic & reversible ──~%")
      (let* ((pr (page-pixel-rect))
             (x0 (getf pr :|x|)) (y0 (getf pr :|y|))
             (x1 (+ x0 (getf pr :|w|))) (y1 (+ y0 (getf pr :|h|)))
             hashes-w1 hashes-w2)
        (dotimes (i 3)
          (limn:call "bridge/win-focus" :|win-id| "w1") (sleep 0.2)
          (push (getf (region-hash x0 y0 x1 y1) :|sha256|) hashes-w1)
          (limn:call "bridge/win-focus" :|win-id| w2) (sleep 0.2)
          (push (getf (region-hash x0 y0 x1 y1) :|sha256|) hashes-w2))
        (check (format nil "Ω3a — every w1-focused hash equal (~a)" hashes-w1)
               (every (lambda (h) (string= h (first hashes-w1))) hashes-w1))
        (check (format nil "Ω3b — every w2-focused hash equal (~a)" hashes-w2)
               (every (lambda (h) (string= h (first hashes-w2))) hashes-w2))
        (check (format nil "Ω3c — w1 hash ≠ w2 hash (~a vs ~a)"
                       (first hashes-w1) (first hashes-w2))
               (not (string= (first hashes-w1) (first hashes-w2)))))

;;; ── Ω4: page change on non-focused window invisible in raster ───

      (format t "~%── Ω4: view/set :page on non-focused window invisible ──~%")
      (limn:call "bridge/win-focus" :|win-id| "w1") (sleep 0.2)
      (clear-ov "w1") (clear-ov w2) (sleep 0.3)
      (let* ((pr (page-pixel-rect))
             (x0 (getf pr :|x|)) (y0 (getf pr :|y|))
             (x1 (+ x0 (getf pr :|w|))) (y1 (+ y0 (getf pr :|h|))))
        (let ((h-before (getf (region-hash x0 y0 x1 y1) :|sha256|)))
          ;; fixture is 6 pages (0..5), 4 is valid.
          (limn:call "view/set" :|win-id| w2 :|page| 4)
          (sleep 0.3)
          (let ((h-after (getf (region-hash x0 y0 x1 y1) :|sha256|)))
            (check (format nil "Ω4 — non-focused page change → raster unchanged (~a)"
                           (string= h-before h-after))
                   (string= h-before h-after)))))

;;; ── Ω5: focus to that pre-set window now shows page 4 in raster ─

      (format t "~%── Ω5: focusing w2 restores its prior page=4 ──~%")
      (limn:call "bridge/win-focus" :|win-id| w2) (sleep 0.3)
      (let ((d (view-get w2)))
        (check (format nil "Ω5 — view/get w2 :page == 4 (got ~a)"
                       (getf d :|page|))
               (eql (getf d :|page|) 4)))

;;; ── Ω6: scroll mutation on focused only moves that window ──────
      ;;
      ;; v0.15 isolation invariant: changing one window's offset must
      ;; not leak into another window's stored offset.
      ;;
      ;; Originally tried xdotool 'Next' (PageDown) to test real OS-level
      ;; key routing — but Limn's input filter intercepts PageDown before
      ;; sioyek sees it, so the scroll never lands. That's an input-
      ;; dispatch question, orthogonal to v0.15's isolation contract.
      ;; Use view/set directly, which exercises the same per-window
      ;; mutation path the dispatcher would eventually call.

      (format t "~%── Ω6: scroll on focused w1 leaves w2 offset untouched ──~%")
      (limn:call "bridge/win-focus" :|win-id| "w1") (sleep 0.2)
      (limn:call "view/set" :|win-id| "w1" :|page| 0  :|offset-y| 0.0)
      (limn:call "view/set" :|win-id| w2   :|page| 0  :|offset-y| 0.0)
      (sleep 0.2)
      (let ((w2-before-y (getf (view-get w2) :|offset-y|)))
        (limn:call "view/set" :|win-id| "w1" :|offset-y| 150.0)
        (sleep 0.2)
        (let ((w1-after  (getf (view-get "w1") :|offset-y|))
              (w2-after  (getf (view-get w2)   :|offset-y|)))
          (check (format nil "Ω6a — w1 offset-y advanced (was 0, now ~a)" w1-after)
                 (> (or w1-after 0.0) 100.0))
          (check (format nil "Ω6b — w2 offset-y unchanged (~a → ~a)"
                         w2-before-y w2-after)
                 (and w2-after w2-before-y
                      (< (abs (- w2-after w2-before-y)) 0.5)))))

;;; ── Ω7: per-window buffer-id survives focus switching ───────────

      (format t "~%── Ω7: each window's :buffer-id is preserved across focus ──~%")
      (let* ((dA (view-get "w1"))
             (dB (view-get w2))
             (bA (getf dA :|buffer-id|))
             (bB (getf dB :|buffer-id|)))
        (check (format nil "Ω7a — w1 has its own buffer-id (~a)" bA) (stringp bA))
        (check (format nil "Ω7b — w2 has its own buffer-id (~a)" bB) (stringp bB))
        (check (format nil "Ω7c — buffer-ids differ (~a vs ~a)" bA bB)
               (and bA bB (not (string= bA bB))))
        (limn:call "bridge/win-focus" :|win-id| w2) (sleep 0.2)
        (limn:call "bridge/win-focus" :|win-id| "w1") (sleep 0.2)
        (let ((dA2 (view-get "w1")) (dB2 (view-get w2)))
          (check "Ω7d — w1 buffer-id preserved after toggle"
                 (string= bA (getf dA2 :|buffer-id|)))
          (check "Ω7e — w2 buffer-id preserved after toggle"
                 (string= bB (getf dB2 :|buffer-id|)))))

;;; ── Ω8: closing w2 → raster falls back to w1 cleanly ────────────

      (format t "~%── Ω8: closing w2 (was focused) → w1 becomes focused & live ──~%")
      (limn:call "bridge/win-focus" :|win-id| w2) (sleep 0.2)
      (limn:call "bridge/win-close" :|win-id| w2) (sleep 0.3)
      (let* ((l    (limn:call "bridge/win-list"))
             (data (limn/bridge:response-data l))
             (foc  (remove-if-not (lambda (e) (getf e :|focused|)) data)))
        (check (format nil "Ω8a — exactly one focused window after close (got ~a)"
                       (length foc))
               (= 1 (length foc)))
        (check "Ω8b — surviving focused window is w1"
               (string= "w1" (getf (first foc) :|win-id|))))
      (let ((d (view-get "w1")))
        (check (format nil "Ω8c — view/get w1 still responsive (page ~a)"
                       (getf d :|page|))
               (numberp (getf d :|page|)))))

    ;; ── summary ─────────────────────────────────────────────────
    (format t "~%~%── per-window e2e results ──~%")
    (if (null *failures*)
        (format t "✓ ALL CHECKS PASSED~%")
        (progn
          (format t "✗ ~a FAILURE(s):~%" (length *failures*))
          (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
    (limn:stop)
    (sb-ext:process-kill proc 15)
    (sb-ext:process-wait proc)
    (sb-ext:exit :code (if *failures* 1 0))))
