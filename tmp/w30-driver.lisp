;;;; W30 driver — auto-revert
;;;; Write 'old' → find-file → enable auto-revert → external write 'new' →
;;;; wait → expect buffer content updated to 'new'.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *out-dir* "/host-tmp/receipts/30/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (l ok &optional (d ""))
  (push (cons l ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") l
          (if (string= d "") "" (format nil "   [~a]" d))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(defun wait-for-window (n &key (timeout 5))
  (let ((d (+ (get-universal-time) timeout)))
    (loop (when (zerop (sb-ext:process-exit-code
                         (sb-ext:run-program "xdotool" (list "search" "--name" n)
                                              :search t :wait t :output nil)))
            (return t))
          (when (> (get-universal-time) d) (return nil))
          (sleep 0.1))))

(defparameter *path* (format nil "/tmp/w30-revert-~a.txt" (sb-posix:getpid)))

;; Pre-create file with "old"
(with-open-file (s *path* :direction :output :if-exists :supersede)
  (write-string "old content" s))

(format t "~%── W30 auto-revert ──~%")

(let* ((sock (format nil "/tmp/limn-w30-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w30.log" :if-output-exists :supersede
              :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (sleep 0.5)

  (let ((bid (limn/file:find-file *path*)))
    (format t "  bid=~a~%" bid)
    (let* ((bufs (symbol-value (find-symbol "*BUFS*" :limn/file)))
           (b (gethash bid bufs))
           (struct-content-sym (find-symbol "FBUF-CONTENT" :limn/file))
           (content (funcall (symbol-function struct-content-sym) b)))
      (check "A.1 buffer content reads 'old content'"
             (search "old content" content)
             (format nil "content=~s" content)))

    ;; Enable auto-revert (toggle takes single arg)
    (let ((r (handler-case
                 (progn (limn/auto-revert:auto-revert-mode bid) :ok)
               (error (e) (cons :err e)))))
      (check "A.2 auto-revert-mode enabled"
             (eq r :ok)
             (if (consp r) (format nil "err: ~a" (cdr r)) "ok")))

    ;; External write "new"
    (with-open-file (s *path* :direction :output :if-exists :supersede)
      (write-string "new content here" s))
    (format t "  external write 'new' done~%")

    ;; Wait for auto-revert; pump events periodically
    (dotimes (i 20)
      (sleep 0.25)
      (ignore-errors (limn:pump)))

    (let* ((bufs (symbol-value (find-symbol "*BUFS*" :limn/file)))
           (b (gethash bid bufs))
           (struct-content-sym (find-symbol "FBUF-CONTENT" :limn/file))
           (content (funcall (symbol-function struct-content-sym) b)))
      (check "A.3 after external write + wait, buffer content reflects 'new'"
             (search "new content here" content)
             (format nil "content=~s" content))))

  (let ((log (with-open-file (s "/tmp/limn-w30.log" :if-does-not-exist nil)
               (when s (let ((b (make-string (file-length s))))
                         (read-sequence b s) b)))))
    (when log
      (with-open-file (s (concatenate 'string *out-dir* "limn.log")
                          :direction :output :if-exists :supersede)
        (write-sequence log s))))
  (ignore-errors (delete-file *path*))
  (ignore-errors
    (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t))
  (sleep 0.2))

(let* ((rev (reverse *results*))
       (pass (count-if #'cdr rev)) (total (length rev)) (fail (- total pass)))
  (format t "~%── W30 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
