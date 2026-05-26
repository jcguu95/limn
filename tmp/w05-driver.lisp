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
  "Save current paint to OUT-PATH as PNG. Uses test/grab-window."
  (let* ((r    (limn:call "test/grab-window" :|win-id| "w1"))
         (data (limn/bridge:response-data r))
         (b64  (getf data :|png|))
         (raw  (cl-user::base64-string-to-bytes b64)))
    (with-open-file (s out-path :direction :output
                                :element-type '(unsigned-byte 8)
                                :if-exists :supersede)
      (write-sequence raw s))
    (length raw)))

(defparameter *out-dir* "/host-tmp/receipts/05/")
(ensure-directories-exist *out-dir*)

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

  ;; Baseline (light mode expected)
  (let ((n (grab-png (concatenate 'string *out-dir* "step-00.png"))))
    (format t "  step-00 captured (~a bytes)~%" n))

  ;; Diagnostic helper — prints current dark-mode state from both paths
  (flet ((diag (label)
           (let* ((v (limn/bridge:response-data
                      (limn:call "view/get" :|win-id| "w1")))
                  (top-dark (getf v :|dark-mode|))
                  (ep       (getf v :|engine-params|))
                  (nested-dark (and ep (getf ep :|dark-mode|))))
             (format t "  diag ~a: top=~a  nested=~a~%"
                     label top-dark nested-dark))))
    (diag "step-00")
    ;; Toggle 3 times
    (dolist (i '("01" "02" "03"))
      (format t "  → xdotool key d (step ~a)~%" i)
      (xdotool "key" "--clearmodifiers" "d")
      (sleep 0.5)
      (let ((n (grab-png (concatenate 'string *out-dir* "step-" i ".png"))))
        (format t "  step-~a captured (~a bytes)~%" i n))
      (diag (concatenate 'string "step-" i))
      (sleep 0.2)))

  (format t "~%── source-of-truth: backend/limn-pdf-mode.lisp pdf-toggle-dark ──~%")
  (with-open-file (s "/limn/backend/limn-pdf-mode.lisp")
    (loop with start = nil
          for line = (read-line s nil nil)
          for n from 1
          while line do
            (when (search "pdf-toggle-dark nil" line) (setf start n))
            (when (and start (<= start n (+ start 18)))
              (format t "  ~3d: ~a~%" n line))))

  ;; Cleanup
  (ignore-errors (sb-ext:process-kill proc 15))
  (sleep 0.3)
  (ignore-errors (sb-ext:process-kill proc 9)))

(format t "~%done. PNGs at /host-tmp/receipts/05/~%")
(sb-ext:exit :code 0)
