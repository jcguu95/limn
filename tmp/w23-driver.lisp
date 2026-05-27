;;;; W23 driver — defun + bind via leader (SPC m)

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

(defparameter *out-dir* "/host-tmp/receipts/23/")
(ensure-directories-exist *out-dir*)
(ensure-directories-exist "/tmp/.limn/")

(with-open-file (s "/tmp/.limn/init.lisp" :direction :output :if-exists :supersede)
  (write-string ";;;; W23 init: SPC m → my-w23-canary
(in-package :cl-user)
(defun my-w23-canary ()
  (with-open-file (s \"/tmp/w23-canary\" :direction :output :if-exists :supersede)
    (write-string \"SPC_M_PRESSED\" s)))
(limn/map-macro:map! :leader \"m\" 'my-w23-canary)
" s))

(sb-posix:setenv "LIMN_INIT" "/tmp/.limn/init.lisp" 1)
(ignore-errors (delete-file "/tmp/w23-canary"))

(defparameter *results* nil)
(defun check (l ok &optional (d ""))
  (push (cons l ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") l
          (if (string= d "") "" (format nil "   [~a]" d))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(defun slurp (p)
  (with-open-file (s p :if-does-not-exist nil)
    (when s (let ((b (make-string (file-length s)))) (read-sequence b s) b))))

(format t "~%── W23 defun + leader binding ──~%")

(let* ((sock (format nil "/tmp/limn-w23-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w23.log" :if-output-exists :supersede
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

  ;; Press SPC then m
  (xdotool "key" "--clearmodifiers" "space") (sleep 0.25)
  (xdotool "key" "--clearmodifiers" "m") (sleep 0.4)

  (let ((c (slurp "/tmp/w23-canary")))
    (check "A.1 SPC m fires my-w23-canary"
           (and c (search "SPC_M_PRESSED" c) t)
           (format nil "canary: ~s" c)))

  (let ((log (with-open-file (s "/tmp/limn-w23.log" :if-does-not-exist nil)
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
  (format t "~%── W23 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
