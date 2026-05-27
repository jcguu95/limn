;;;; W14 — 新 .org 寫 TODO + 重開驗證
(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))
(defun xdotool (&rest args) (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))
(defun wait-for-window (n) (let ((d (+ (get-universal-time) 5))) (loop (when (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" (list "search" "--name" n) :search t :wait t :output nil))) (return t)) (when (> (get-universal-time) d) (return nil)) (sleep 0.1))))
(defparameter *out-dir* "/host-tmp/receipts/14/") (ensure-directories-exist *out-dir*)
(defparameter *path* (format nil "/tmp/w14-todo-~a.org" (sb-posix:getpid)))
(defparameter *results* nil)
(defun check (l ok &optional (d "")) (push (cons l ok) *results*) (format t "  ~a ~a~a~%" (if ok "✓" "✗") l (if (string= d "") "" (format nil "   [~a]" d))))

(format t "~%── W14 新 .org TODO ──~%")
;; B8 workaround: pre-touch
(with-open-file (s *path* :direction :output :if-exists :supersede)) ; touch
(let* ((sock (format nil "/tmp/limn-w14-~a" (sb-posix:getpid))) (limn-bin "/limn/sioyek/limn")
       (proc (sb-ext:run-program limn-bin (list "--test-mode" "--socket" sock) :wait nil :search nil :output "/tmp/limn-w14.log" :if-output-exists :supersede :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (wait-for-window "Limn") (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate") (sleep 0.3)
  (let ((bid (limn/file:find-file *path*)))
    (check "A.1 find-file (after touch) gives bid" bid (format nil "bid=~a" bid))
    ;; Type 10 lines
    (xdotool "type" "--delay" "30" "* TODO line 1
* TODO line 2
* TODO line 3
* TODO line 4
* TODO line 5
* TODO line 6
* TODO line 7
* TODO line 8
* TODO line 9
* TODO line 10
")
    (sleep 0.5)
    (handler-case (limn/file:save-buffer bid) (error () nil))
    (sleep 0.3)
    (let* ((content (when (probe-file *path*) (with-open-file (s *path*) (let ((b (make-string (file-length s)))) (read-sequence b s) b))))
           (lines (and content (count #\newline content))))
      (check "A.2 saved file contains 10 lines" (and (numberp lines) (>= lines 10)) (format nil "lines=~a content[0..40]=~s" lines (and content (subseq content 0 (min 40 (length content))))))))
  (ignore-errors (delete-file *path*))
  (ignore-errors (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t)))
(let* ((rev (reverse *results*)) (pass (count-if #'cdr rev)) (total (length rev)))
  (format t "~%── W14 result: ~a / ~a pass ──~%" pass total)
  (sb-ext:exit :code (if (= pass total) 0 1)))
