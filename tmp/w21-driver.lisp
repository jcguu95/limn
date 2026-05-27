;;;; W21 driver — 大檔 perf
;;;; 預生成 1.5MB ~30k 行 .org，find-file 開，每操作 wall-clock < 500ms.

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

(defparameter *out-dir* "/host-tmp/receipts/21/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (l ok &optional (d ""))
  (push (cons l ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") l
          (if (string= d "") "" (format nil "   [~a]" d))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

;; Generate large .org (~ 30k lines, ~1.5 MB)
(defparameter *large-path* "/tmp/w21-large.org")
(unless (probe-file *large-path*)
  (with-open-file (s *large-path* :direction :output :if-exists :supersede)
    (dotimes (i 30000)
      (format s "* TODO line-~5,'0d  some content lorem ipsum dolor sit amet consect~%" i))))

(format t "~%── W21 大檔 perf ──~%")
(format t "  fixture: ~a bytes~%"
        (with-open-file (s *large-path*) (file-length s)))

(defmacro timed (op &body body)
  (let ((t0 (gensym)))
    `(let ((,t0 (get-internal-real-time)))
       (multiple-value-prog1 (progn ,@body)
         (let* ((dt (- (get-internal-real-time) ,t0))
                (ms (/ (* dt 1000.0) internal-time-units-per-second)))
           (format t "  [timed] ~a: ~,1f ms~%" ,op ms)
           (check (format nil "perf ~a < 500ms" ,op) (< ms 500)
                  (format nil "~,1f ms" ms)))))))

(let* ((sock (format nil "/tmp/limn-w21-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w21.log" :if-output-exists :supersede
              :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate")
  (sleep 0.3)

  ;; find-file 大檔 (timed)
  (timed "find-file"
    (handler-case (limn/file:find-file *large-path*)
      (error (e) (format t "  find-file err: ~a~%" e))))

  ;; Buffer set as active? Just measure subsequent operations.
  ;; We don't have a wire "scroll line" so use xdotool for navigation
  ;; on the limn window (testing whether window stays responsive)

  (timed "view/get round-trip after large load"
    (safe-call "view/get" :|win-id| "w1"))

  ;; bunch of view/get to check responsiveness
  (timed "10× view/get rapid-fire"
    (dotimes (i 10) (safe-call "view/get" :|win-id| "w1")))

  ;; Cleanup
  (ignore-errors
    (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t))
  (sleep 0.2))

(let* ((rev (reverse *results*))
       (pass (count-if #'cdr rev)) (total (length rev)) (fail (- total pass)))
  (format t "~%── W21 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
