;;;; W25 — which-key prefix popup
(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))
(defun xdotool (&rest args) (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))
(defun wait-for-window (n) (let ((d (+ (get-universal-time) 5))) (loop (when (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" (list "search" "--name" n) :search t :wait t :output nil))) (return t)) (when (> (get-universal-time) d) (return nil)) (sleep 0.1))))
(ensure-directories-exist "/host-tmp/receipts/25/")
(defparameter *results* nil)
(defun check (l ok &optional (d "")) (push (cons l ok) *results*) (format t "  ~a ~a~a~%" (if ok "✓" "✗") l (if (string= d "") "" (format nil "   [~a]" d))))
(defun safe-call (cmd &rest args) (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args))) (error (e) (cons :err e))))

(format t "~%── W25 which-key prefix popup ──~%")
;; init.lisp adds SPC f → submap with three keys
(ensure-directories-exist "/tmp/.limn/")
(with-open-file (s "/tmp/.limn/init.lisp" :direction :output :if-exists :supersede)
  (write-string ";;;; W25
(in-package :cl-user)
(defun my-w25-fs () (with-open-file (s \"/tmp/w25-fs\" :direction :output :if-exists :supersede) (write-string \"FS\" s)))
(defun my-w25-fo () (with-open-file (s \"/tmp/w25-fo\" :direction :output :if-exists :supersede) (write-string \"FO\" s)))
(defun my-w25-fc () (with-open-file (s \"/tmp/w25-fc\" :direction :output :if-exists :supersede) (write-string \"FC\" s)))
(limn/map-macro:map! :leader \"f s\" 'my-w25-fs \"f o\" 'my-w25-fo \"f c\" 'my-w25-fc)
" s))
(sb-posix:setenv "LIMN_INIT" "/tmp/.limn/init.lisp" 1)
(ignore-errors (delete-file "/tmp/w25-fs"))

(let* ((sock (format nil "/tmp/limn-w25-~a" (sb-posix:getpid))) (limn-bin "/limn/sioyek/limn")
       (proc (sb-ext:run-program limn-bin (list "--test-mode" "--socket" sock) :wait nil :search nil :output "/tmp/limn-w25.log" :if-output-exists :supersede :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (wait-for-window "Limn") (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate") (sleep 0.3)

  ;; Press SPC then wait for which-key popup (1.5s idle)
  (xdotool "key" "--clearmodifiers" "space") (sleep 1.6)
  ;; Press f
  (xdotool "key" "--clearmodifiers" "f") (sleep 1.6)
  ;; Press s → should fire my-w25-fs
  (xdotool "key" "--clearmodifiers" "s") (sleep 0.5)

  (let ((c (with-open-file (s "/tmp/w25-fs" :if-does-not-exist nil)
             (when s (let ((b (make-string (file-length s)))) (read-sequence b s) b)))))
    (check "A.1 SPC f s 觸發 my-w25-fs"
           (and c (search "FS" c) t) (format nil "canary=~s" c)))
  (ignore-errors (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t)))
(let* ((rev (reverse *results*)) (pass (count-if #'cdr rev)) (total (length rev)))
  (format t "~%── W25 result: ~a / ~a pass ──~%" pass total)
  (sb-ext:exit :code (if (= pass total) 0 1)))
