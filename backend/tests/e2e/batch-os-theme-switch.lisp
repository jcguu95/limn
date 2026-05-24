;;;; Batch v0.25-A: display/sync-faces + face overlay — OS-level e2e.
;;;;
;;;; Verifies the full face/theme pipeline end-to-end:
;;;;   Ω1 — sync-faces then overlay :face renders the face foreground colour
;;;;   Ω2 — re-sync with different colour → overlay updates
;;;;   Ω3 — :face overrides :color in the same layer
;;;;   Ω4 — unknown face → layer is silently skipped (no crash)

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

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

;;; ── helpers ───────────────────────────────────────────────────────────

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun sync-faces! (&rest face-plists)
  (limn:call "display/sync-faces" :|faces| face-plists))

(defun set-face-overlay! (win-id page face-name x0 y0 x1 y1)
  (limn:call "view/overlays"
             :|win-id| win-id
             :|layers| (list (list :|type| "rect"
                                   :|page| page
                                   :|face| face-name
                                   :|x0| x0 :|y0| y0
                                   :|x1| x1 :|y1| y1
                                   :|opacity| 1.0))))

(defun sample (win-id page nx ny)
  "Sample pixel at page-normalised coord (NX, NY)."
  (let* ((r    (limn:call "test/page-pixel-rect" :|win-id| win-id :|page| page))
         (rect (data r))
         (px   (+ (getf rect :|x|) (round (* nx (getf rect :|w|)))))
         (py   (+ (getf rect :|y|) (round (* ny (getf rect :|h|)))))
         (pr   (limn:call "test/sample-pixel" :|x| px :|y| py)))
    (data pr)))

(defun near? (pixel r g b &optional (tol 10))
  (and pixel
       (<= (abs (- (getf pixel :|r|) r)) tol)
       (<= (abs (- (getf pixel :|g|) g)) tol)
       (<= (abs (- (getf pixel :|b|) b)) tol)))

;;; ── session ───────────────────────────────────────────────────────────

(let* ((sock    (format nil "/tmp/limn-e2e-face-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc    (sb-ext:run-program
                 limn-bin
                 (list "--test-mode" "--socket" sock)
                 :wait nil :search nil
                 :output "/tmp/limn-os-face.log"
                 :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)

  (let* ((er   (limn:call "bridge/engine-load"
                           :|engine| "mupdf"
                           :|path| (b/ "tests/fixtures/test.pdf")
                           :|win-id| "w1"))
         (buf  (getf (data er) :|buffer-id|))
         (win  "w1")
         (page 0))
    (check (format nil "setup — buffer-id (~a)" buf) (stringp buf))

    ;; ── Ω1: face colour painted ──────────────────────────────────
    (format t "~%── Ω1: face foreground renders ──~%")
    (check "Ω1a — sync-faces ok"
           (ok? (sync-faces! (list :|name| "os-test-red" :|foreground| "#ff0000"))))
    (check "Ω1b — set overlay ok"
           (ok? (set-face-overlay! win page "os-test-red" 0.1 0.1 0.9 0.9)))
    (let ((px (sample win page 0.5 0.5)))
      (check (format nil "Ω1c — centre pixel is red (~s)" px)
             (near? px 255 0 0)))

    ;; ── Ω2: re-sync changes colour ───────────────────────────────
    (format t "~%── Ω2: re-sync updates colour ──~%")
    (check "Ω2a — re-sync with green ok"
           (ok? (sync-faces! (list :|name| "os-test-red" :|foreground| "#00ff00"))))
    (check "Ω2b — re-set overlay ok"
           (ok? (set-face-overlay! win page "os-test-red" 0.1 0.1 0.9 0.9)))
    (let ((px (sample win page 0.5 0.5)))
      (check (format nil "Ω2c — centre pixel is now green (~s)" px)
             (near? px 0 255 0)))

    ;; ── Ω3: face overrides color field ───────────────────────────
    (format t "~%── Ω3: face overrides :color ──~%")
    (sync-faces! (list :|name| "os-test-override" :|foreground| "#ff0000"))
    (check "Ω3a — overlay with both :color and :face ok"
           (ok? (limn:call "view/overlays"
                            :|win-id| win
                            :|layers| (list (list :|type| "rect"
                                                  :|page| page
                                                  :|color| "#0000ff"
                                                  :|face|  "os-test-override"
                                                  :|x0| 0.1 :|y0| 0.1
                                                  :|x1| 0.9 :|y1| 0.9
                                                  :|opacity| 1.0)))))
    (let ((px (sample win page 0.5 0.5)))
      (check (format nil "Ω3b — face (red) wins over color (blue) (~s)" px)
             (near? px 255 0 0)))

    ;; ── Ω4: unknown face → layer skipped, no crash ───────────────
    (format t "~%── Ω4: unknown face gracefully skipped ──~%")
    (let ((r (limn:call "view/overlays"
                         :|win-id| win
                         :|layers| (list (list :|type| "rect"
                                               :|page| page
                                               :|face|  "no-such-face-xyz"
                                               :|x0| 0.2 :|y0| 0.2
                                               :|x1| 0.8 :|y1| 0.8
                                               :|opacity| 1.0)))))
      (check "Ω4a — command doesn't crash (ok response)" (ok? r))))

  ;; ── summary ─────────────────────────────────────────────────────
  (format t "~%~%── face/theme OS e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
