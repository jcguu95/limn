;;;; W12 driver — sidecar manual destruction

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

(defparameter *out-dir* "/host-tmp/receipts/12/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (l ok &optional (d ""))
  (push (cons l ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") l
          (if (string= d "") "" (format nil "   [~a]" d))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(defun overlay-count ()
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (and (eq (car r) :ok) (length (or (getf (cdr r) :|overlays|) '())))))

(defun key (k &optional (s 0.3)) (xdotool "key" "--clearmodifiers" k) (sleep s))

(defun mksel (p y0 y1)
  (safe-call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| p :|x| 0.2 :|y| y0)
              :|end|   (list :|page| p :|x| 0.6 :|y| y1))
  (sleep 0.2))

(defun nuke-sidecars ()
  (let ((dir (merge-pathnames ".limn/annotations/"
                              (or (sb-posix:getenv "HOME") "/root/"))))
    (when (probe-file dir)
      (dolist (f (ignore-errors (directory (merge-pathnames "*.lisp" dir))))
        (ignore-errors (delete-file f))))))

(format t "~%── W12 sidecar manual destruction ──~%")
(nuke-sidecars)

(let* ((sock (format nil "/tmp/limn-w12-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w12.log" :if-output-exists :supersede
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

  ;; Make 3 highlights
  (mksel 0 0.20 0.25) (key "h")
  (mksel 1 0.20 0.25) (key "h")
  (mksel 2 0.20 0.25) (key "h")
  (let ((n (overlay-count)))
    (format t "  3 highlights → overlay count = ~a~%" n)
    (check "A.1 baseline: 3 highlights present"
           (and (numberp n) (>= n 3))
           (format nil "overlays=~a" n)))

  ;; Find + delete sidecar files (external action)
  (let* ((dir (merge-pathnames ".limn/annotations/"
                                (or (sb-posix:getenv "HOME") "/root/")))
         (files (and (probe-file dir)
                     (ignore-errors (directory (merge-pathnames "*.lisp" dir))))))
    (format t "  sidecar files before nuke: ~a~%" (length files))
    (dolist (f files) (ignore-errors (delete-file f)))
    (format t "  deleted ~a sidecar files~%" (length files))
    (check "A.2 sidecars existed before nuke"
           (> (length files) 0)
           (format nil "~a files" (length files))))

  ;; Close + reopen the PDF
  (safe-call "buffer/close" :|win-id| "w1")
  (sleep 0.3)
  (let ((r (safe-call "bridge/engine-load" :|engine| "mupdf"
                       :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1")))
    (check "A.3 reopen after sidecar nuke does not crash"
           (eq (car r) :ok)
           (if (eq (car r) :err) (format nil "err: ~a" (cdr r)) "ok"))
    (sleep 0.5))

  ;; overlay count should be 0
  (let ((n (overlay-count)))
    (check "A.4 after nuke + reopen, 0 highlights"
           (or (null n) (zerop n))
           (format nil "overlays=~a" n)))

  ;; limn process alive
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (check "A.5 limn process still alive (wire responds)"
           (eq (car r) :ok)))

  (let ((log (with-open-file (s "/tmp/limn-w12.log" :if-does-not-exist nil)
               (when s (let ((b (make-string (file-length s))))
                         (read-sequence b s) b)))))
    (when log
      (with-open-file (s (concatenate 'string *out-dir* "limn.log")
                          :direction :output :if-exists :supersede)
        (write-sequence log s))))
  (nuke-sidecars)
  (ignore-errors
    (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t))
  (sleep 0.2))

(let* ((rev (reverse *results*))
       (pass (count-if #'cdr rev)) (total (length rev)) (fail (- total pass)))
  (format t "~%── W12 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
