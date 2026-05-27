;;;; W03 driver — zoom ±5 + reset
;;;; Wire 驗 :|zoom| 值（pixel variance 走 B2 path 抓不到）

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defun xdotool (&rest args)
  (zerop (sb-ext:process-exit-code
           (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))

(defun wait-for-window (n &key (timeout 5))
  (let ((d (+ (get-universal-time) timeout)))
    (loop (when (zerop (sb-ext:process-exit-code
                         (sb-ext:run-program "xdotool" (list "search" "--name" n)
                                              :search t :wait t :output nil)))
            (return t))
          (when (> (get-universal-time) d) (return nil))
          (sleep 0.1))))

(defparameter *out-dir* "/host-tmp/receipts/03/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (l ok &optional (d ""))
  (push (cons l ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") l
          (if (string= d "") "" (format nil "   [~a]" d))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(defun zoom-now ()
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (and (eq (car r) :ok) (getf (cdr r) :|zoom|))))

(defun key (k) (xdotool "key" "--clearmodifiers" k) (sleep 0.22))

(format t "~%── W03 zoom ±5 + reset ──~%")

(let* ((sock (format nil "/tmp/limn-w03-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w03.log" :if-output-exists :supersede
              :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate")
  (sleep 0.3)

  (safe-call "bridge/engine-load" :|engine| "mupdf"
              :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1")
  (sleep 0.5)

  (let ((z0 (zoom-now)))
    (format t "  z0 = ~a~%" z0)

    ;; + ×5 (use = which is also pdf-zoom-in, no shift needed)
    (dotimes (i 5) (key "equal"))  ; xdotool's name for '='
    (let ((z-in (zoom-now)))
      (format t "  after =×5: ~a~%" z-in)
      (check "A.1 = ×5 increased zoom"
             (and (numberp z0) (numberp z-in) (> z-in z0))
             (format nil "~a → ~a" z0 z-in)))

    ;; - ×5
    (dotimes (i 5) (key "minus"))
    (let ((z-out (zoom-now)))
      (format t "  after -×5: ~a~%" z-out)
      (check "A.2 - ×5 brought zoom back close to baseline"
             (and (numberp z0) (numberp z-out)
                  (< (abs (- z0 z-out)) 0.01))
             (format nil "expected≈~a got ~a" z0 z-out)))

    ;; reset key — 0 is reset
    (key "equal") (sleep 0.1) ; one bump to 105%
    (key "0")                  ; reset
    (let ((z-reset (zoom-now)))
      (format t "  after 0 reset: ~a~%" z-reset)
      (check "A.3 '0' resets zoom to ~1.0"
             (and (numberp z-reset) (< (abs (- z-reset 1.0)) 0.05))
             (format nil "got ~a" z-reset))))

  (let ((log (with-open-file (s "/tmp/limn-w03.log" :if-does-not-exist nil)
               (when s (let ((b (make-string (file-length s))))
                         (read-sequence b s) b)))))
    (when log
      (with-open-file (s (concatenate 'string *out-dir* "limn.log")
                          :direction :output :if-exists :supersede)
        (write-sequence log s))))
  (ignore-errors
    (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t))
  (sleep 0.2))

(let* ((rev (reverse *results*))
       (pass (count-if #'cdr rev)) (total (length rev)) (fail (- total pass)))
  (format t "~%── W03 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
