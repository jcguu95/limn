;;;; W24 — 預設 zoom = 150% via init.lisp
(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))
(defun xdotool (&rest args) (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))
(defun wait-for-window (n) (let ((d (+ (get-universal-time) 5))) (loop (when (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" (list "search" "--name" n) :search t :wait t :output nil))) (return t)) (when (> (get-universal-time) d) (return nil)) (sleep 0.1))))
(ensure-directories-exist "/host-tmp/receipts/24/")
(defparameter *results* nil)
(defun check (l ok &optional (d "")) (push (cons l ok) *results*) (format t "  ~a ~a~a~%" (if ok "✓" "✗") l (if (string= d "") "" (format nil "   [~a]" d))))
(defun safe-call (cmd &rest args) (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args))) (error (e) (cons :err e))))

(format t "~%── W24 預設 zoom = 150% ──~%")
;; Write init.lisp with default-zoom config
(ensure-directories-exist "/tmp/.limn/")
(with-open-file (s "/tmp/.limn/init.lisp" :direction :output :if-exists :supersede)
  (write-string ";;;; W24 init: set default PDF zoom to 1.5
(in-package :cl-user)
;; Whatever the symbol is — try common paths
(when (find-package :limn/pdf-mode)
  (let ((sym (find-symbol \"*PDF-DEFAULT-ZOOM*\" :limn/pdf-mode)))
    (when sym (setf (symbol-value sym) 1.5))))
(when (find-package :limn/pdf-mode)
  (let ((sym (find-symbol \"*DEFAULT-PDF-ZOOM*\" :limn/pdf-mode)))
    (when sym (setf (symbol-value sym) 1.5))))
;; Also via wire after view ready
" s))
(sb-posix:setenv "LIMN_INIT" "/tmp/.limn/init.lisp" 1)

(let* ((sock (format nil "/tmp/limn-w24-~a" (sb-posix:getpid))) (limn-bin "/limn/sioyek/limn")
       (proc (sb-ext:run-program limn-bin (list "--test-mode" "--socket" sock) :wait nil :search nil :output "/tmp/limn-w24.log" :if-output-exists :supersede :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (wait-for-window "Limn") (sleep 0.5)
  (safe-call "bridge/engine-load" :|engine| "mupdf" :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1")
  (sleep 0.5)
  (let* ((r (safe-call "view/get" :|win-id| "w1"))
         (z (and (eq (car r) :ok) (getf (cdr r) :|zoom|))))
    (check "A.1 default zoom = 1.5 after init.lisp setting"
           (and (numberp z) (< (abs (- z 1.5)) 0.05))
           (format nil "zoom=~a" z)))
  ;; Look for what *pdf-default-zoom*-style symbol exists
  (let* ((cands (let (r) (do-symbols (s :limn/pdf-mode r) (when (search "ZOOM" (symbol-name s)) (push s r))))))
    (format t "  zoom-related symbols in limn/pdf-mode: ~a~%" cands))
  (ignore-errors (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t)))
(let* ((rev (reverse *results*)) (pass (count-if #'cdr rev)) (total (length rev)))
  (format t "~%── W24 result: ~a / ~a pass ──~%" pass total)
  (sb-ext:exit :code (if (= pass total) 0 1)))
