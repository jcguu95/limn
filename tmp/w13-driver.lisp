;;;; W13 — PDF → .org 複製文字 (high risk)
(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))
(defun xdotool (&rest args) (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))
(defun wait-for-window (n) (let ((d (+ (get-universal-time) 5))) (loop (when (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" (list "search" "--name" n) :search t :wait t :output nil))) (return t)) (when (> (get-universal-time) d) (return nil)) (sleep 0.1))))
(ensure-directories-exist "/host-tmp/receipts/13/")
(defparameter *org-path* (format nil "/tmp/w13-notes-~a.org" (sb-posix:getpid)))
(defparameter *results* nil)
(defun check (l ok &optional (d "")) (push (cons l ok) *results*) (format t "  ~a ~a~a~%" (if ok "✓" "✗") l (if (string= d "") "" (format nil "   [~a]" d))))
(defun safe-call (cmd &rest args) (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args))) (error (e) (cons :err e))))

(format t "~%── W13 PDF → .org copy ──~%")
(with-open-file (s *org-path* :direction :output :if-exists :supersede)) ; touch

(let* ((sock (format nil "/tmp/limn-w13-~a" (sb-posix:getpid))) (limn-bin "/limn/sioyek/limn")
       (proc (sb-ext:run-program limn-bin (list "--test-mode" "--socket" sock) :wait nil :search nil :output "/tmp/limn-w13.log" :if-output-exists :supersede :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (wait-for-window "Limn") (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate") (sleep 0.3)

  (safe-call "bridge/engine-load" :|engine| "mupdf" :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1") (sleep 0.5)

  ;; Make a selection on PDF
  (safe-call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| 0 :|x| 0.2 :|y| 0.2)
              :|end|   (list :|page| 0 :|x| 0.7 :|y| 0.3))
  (sleep 0.3)

  ;; Get selection text via wire
  (let* ((sr (safe-call "view/selection-get" :|win-id| "w1"))
         (text (and (eq (car sr) :ok) (getf (cdr sr) :|text|))))
    (check "A.1 PDF selection text present"
           (and text (plusp (length text)))
           (format nil "text=~s" (and text (subseq text 0 (min 40 (length text)))))))

  ;; M-w copy via xdotool — expected B5 fail (Alt+w)
  (xdotool "key" "--clearmodifiers" "alt+w") (sleep 0.3)
  ;; Find-file org buffer
  (let ((bid (limn/file:find-file *org-path*)))
    (check "A.2 find-file org buffer" bid)
    ;; C-y paste via xdotool
    (xdotool "key" "--clearmodifiers" "ctrl+y") (sleep 0.3)
    (handler-case (limn/file:save-buffer bid) (error () nil))
    (sleep 0.3)
    (let ((c (when (probe-file *org-path*) (with-open-file (s *org-path*) (let ((b (make-string (file-length s)))) (read-sequence b s) b)))))
      (check "A.3 .org has pasted text"
             (and c (plusp (length c)))
             (format nil "org content=~s" (and c (subseq c 0 (min 40 (length c))))))))
  (ignore-errors (delete-file *org-path*))
  (ignore-errors (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t)))
(let* ((rev (reverse *results*)) (pass (count-if #'cdr rev)) (total (length rev)))
  (format t "~%── W13 result: ~a / ~a pass ──~%" pass total)
  (sb-ext:exit :code (if (= pass total) 0 1)))
