;;;; W29 — C-g 各階段 abort minibuffer
(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))
(defun xdotool (&rest args) (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))
(defun wait-for-window (n) (let ((d (+ (get-universal-time) 5))) (loop (when (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" (list "search" "--name" n) :search t :wait t :output nil))) (return t)) (when (> (get-universal-time) d) (return nil)) (sleep 0.1))))
(ensure-directories-exist "/host-tmp/receipts/29/")
(defparameter *results* nil)
(defun check (l ok &optional (d "")) (push (cons l ok) *results*) (format t "  ~a ~a~a~%" (if ok "✓" "✗") l (if (string= d "") "" (format nil "   [~a]" d))))
(defun safe-call (cmd &rest args) (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args))) (error (e) (cons :err e))))
(defun mb-open-p () (let ((r (safe-call "minibuffer/get"))) (and (eq (car r) :ok) (eq (getf (cdr r) :|open|) t))))

(format t "~%── W29 C-g abort ──~%")
(let* ((sock (format nil "/tmp/limn-w29-~a" (sb-posix:getpid))) (limn-bin "/limn/sioyek/limn")
       (proc (sb-ext:run-program limn-bin (list "--test-mode" "--socket" sock) :wait nil :search nil :output "/tmp/limn-w29.log" :if-output-exists :supersede :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (wait-for-window "Limn") (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate") (sleep 0.3)
  (safe-call "bridge/engine-load" :|engine| "mupdf" :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1") (sleep 0.5)

  ;; Use / (isearch) as the minibuffer to test C-g — works without B5
  ;; Case 1: open + C-g immediately
  (xdotool "key" "--clearmodifiers" "slash") (sleep 0.3)
  (check "A.1 / opens minibuffer" (mb-open-p))
  (xdotool "key" "--clearmodifiers" "ctrl+g") (sleep 0.3)
  (check "A.2 C-g empty closes minibuffer" (not (mb-open-p)))

  ;; Case 2: open + type + C-g
  (xdotool "key" "--clearmodifiers" "slash") (sleep 0.3)
  (xdotool "type" "--delay" "60" "abc") (sleep 0.3)
  (check "A.3 minibuffer has 'abc' before C-g"
         (let* ((r (safe-call "minibuffer/get")) (text (and (eq (car r) :ok) (getf (cdr r) :|text|))))
           (string= text "abc")))
  (xdotool "key" "--clearmodifiers" "ctrl+g") (sleep 0.3)
  (check "A.4 C-g during typing closes minibuffer" (not (mb-open-p)))

  (ignore-errors (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t)))
(let* ((rev (reverse *results*)) (pass (count-if #'cdr rev)) (total (length rev)))
  (format t "~%── W29 result: ~a / ~a pass ──~%" pass total)
  (sb-ext:exit :code (if (= pass total) 0 1)))
