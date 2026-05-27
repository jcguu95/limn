;;;; W05 dark-mode toggle ×3 driver — v0.38 dogfood
;;;;
;;;; Runs inside limn-e2e container. xdotool sends real keystrokes
;;;; (R2'), test/grab-window saves paint PNGs (R3' — paint result, not
;;;; state query). PNG sequence written to /host-tmp/receipts/05/ for
;;;; host-side Pillow analysis.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))
(load (b/ "repl-helpers.lisp"))

(defun xdotool (&rest args)
  (let ((p (sb-ext:run-program "xdotool" args :search t
                                :wait t :output t :error t)))
    (unless (zerop (sb-ext:process-exit-code p))
      (error "xdotool ~{~a~^ ~} exited non-zero" args))))

(defun wait-for-window (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((p (sb-ext:run-program "xdotool"
                                    (list "search" "--name" name)
                                    :search t :wait t :output nil)))
        (when (zerop (sb-ext:process-exit-code p))
          (return t)))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

(defun grab-png (out-path)
  "Save current paint to OUT-PATH as PNG.  Uses test/grab-window and
   returns (bytes avg-luminance gl-color-mode capture-source).
   v0.39 W05 honest²: gl-color-mode is THE PRODUCTION state — the
   PdfViewOpenGLWidget's color_mode enum, which the dark-mode
   fragment shader reads at paint time.  Asserting on it catches
   regressions that break set_dark_mode wiring without depending on
   grabFramebuffer (which is null in headless Xvfb).  Capture-source
   surfaces which path produced the bytes (opengl / mupdf / widget-
   grab) so it's clear what was actually exercised."
  (let* ((r    (limn:call "test/grab-window" :|win-id| "w1"))
         (data (limn/bridge:response-data r))
         (b64  (getf data :|png|))
         (lum  (getf data :|avg-luminance|))
         (cm   (getf data :|gl-color-mode|))
         (src  (getf data :|capture-source|))
         (raw  (cl-user::base64-string-to-bytes b64)))
    (with-open-file (s out-path :direction :output
                                :element-type '(unsigned-byte 8)
                                :if-exists :supersede)
      (write-sequence raw s))
    (values (length raw) lum cm src)))

(defparameter *out-dir* "/host-tmp/receipts/05/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (label ok &optional (details ""))
  (push (cons label ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") label
          (if (string= details "") "" (format nil "   [~a]" details))))

(defun %dark-now ()
  "Return current dark-mode value from the focused view's
   engine-params nest (T / :FALSE / NIL).  Was the W05 B6
   diagnostic — promoted to a helper now that checks fire on it."
  (let* ((v (limn/bridge:response-data
              (limn:call "view/get" :|win-id| "w1")))
         (ep (getf v :|engine-params|)))
    (and ep (getf ep :|dark-mode|))))

(format t "~%── W05 dark-mode toggle ×3 ──~%")

(let* ((sock (format nil "/tmp/limn-w05-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (tutorial "/limn/sioyek/tutorial.pdf")
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w05.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (limn:call "bridge/engine-load" :|engine| "mupdf"
              :|path| tutorial :|win-id| "w1")
  (sleep 1.0)

  ;; Force a paint refresh — sometimes Xvfb framebuffer is empty until
  ;; an interaction touches it.  Send a no-op (Right then Left) and wait.
  (xdotool "key" "--clearmodifiers" "Right") (sleep 0.4)
  (xdotool "key" "--clearmodifiers" "Left")  (sleep 0.6)

  ;; Activate the window via xdotool for good measure
  (xdotool "search" "--name" "Limn" "windowactivate") (sleep 0.3)

  ;; Baseline: dark-mode should be off (NIL or :false).
  (multiple-value-bind (bytes-00 lum-00 cm-00 src-00)
      (grab-png (concatenate 'string *out-dir* "step-00.png"))
    (let ((dark-00 (%dark-now)))
      (format t "  step-00 captured (~a bytes, lum=~,1f, cm=~a, src=~a), dark=~a~%"
              bytes-00 lum-00 cm-00 src-00 dark-00)
      (check "A.1 baseline win->dark_mode is off (state)"
             (or (null dark-00) (eq dark-00 :false))
             (format nil "dark=~a" dark-00))
      (check "A.2 baseline GL widget color_mode is 'normal' (production state)"
             (equal cm-00 "normal")
             (format nil "gl-color-mode=~a" cm-00))
      (check "A.3 baseline frame has bright avg luminance (light render)"
             (and (numberp lum-00) (> lum-00 200))
             (format nil "lum=~,1f via ~a" lum-00 src-00))

      ;; Toggle 3 times; verify ALL THREE signals flip together:
      ;;   - win->dark_mode (LimnWindow snapshot field)
      ;;   - opengl_widget->color_mode (production GL shader input)
      ;;   - avg-luminance (mupdf render with fz_invert_pixmap, OR
      ;;                    real GL framebuffer when grabFramebuffer
      ;;                    works — capture-source surfaces which)
      ;;
      ;; The GL color_mode check is the honest² part: it's the
      ;; PRODUCTION state slot the dark-mode fragment shader reads.
      ;; If a regression breaks the set_dark_mode → color_mode wiring
      ;; (so the user's screen wouldn't actually go dark on a real
      ;; display), this assertion fails — independent of whether
      ;; headless Xvfb can grab the GL framebuffer.
      (let ((prev-lum lum-00)
            (steps '("01" "02" "03"))
            (expected-dark '(t :false t))
            (expected-cm   '("dark" "normal" "dark")))
        (loop for label in steps
              for want in expected-dark
              for want-cm in expected-cm
              do (format t "  → xdotool key d (step ~a)~%" label)
                 (xdotool "key" "--clearmodifiers" "d")
                 (sleep 0.5)
                 (multiple-value-bind (bytes lum cm src)
                     (grab-png (concatenate 'string *out-dir*
                                             "step-" label ".png"))
                   (declare (ignore bytes))
                   (let ((dark (%dark-now)))
                     (format t "  step-~a captured (lum=~,1f, cm=~a, src=~a), dark=~a~%"
                             label lum cm src dark)
                     (check (format nil "B.~a win->dark_mode state is ~a"
                                    label want)
                            (if (eq want t)
                                (eq dark t)
                                (or (eq dark want) (null dark)))
                            (format nil "dark=~a (want ~a)" dark want))
                     (check (format nil "B.~a GL color_mode is '~a' (production shader input)"
                                    label want-cm)
                            (equal cm want-cm)
                            (format nil "gl-color-mode=~a (want ~a)"
                                    cm want-cm))
                     (let ((delta (abs (- lum prev-lum))))
                       (check (format nil "B.~a avg-lum moved ≥ 100 (pixel evidence via ~a)"
                                      label src)
                              (> delta 100)
                              (format nil "prev=~,1f now=~,1f delta=~,1f"
                                      prev-lum lum delta)))
                     (setf prev-lum lum)))))))

  ;; Cleanup
  (ignore-errors (sb-ext:process-kill proc 15))
  (sleep 0.3)
  (ignore-errors (sb-ext:process-kill proc 9)))

(let* ((rev (reverse *results*))
       (pass (count-if #'cdr rev)) (total (length rev)) (fail (- total pass)))
  (format t "~%── W05 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
