;;;; W10 driver — 跨檔 bookmark
;;;; Paper A 設 bookmark m, paper B 設 b, 互跳。No m / ' key bindings
;;;; on pdf-mode-map; use pdf-set/jump-bookmark-name Lisp API directly.

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

(defparameter *out-dir* "/host-tmp/receipts/10/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (l ok &optional (d ""))
  (push (cons l ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") l
          (if (string= d "") "" (format nil "   [~a]" d))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(defun page-now ()
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (and (eq (car r) :ok) (getf (cdr r) :|page|))))

(defun nuke-sidecars ()
  (let ((dir (merge-pathnames ".limn/bookmarks/"
                              (or (sb-posix:getenv "HOME") "/root/"))))
    (when (probe-file dir)
      (dolist (f (ignore-errors (directory (merge-pathnames "*.lisp" dir))))
        (ignore-errors (delete-file f))))))

;; Make paper-B by copying tutorial.pdf
(uiop:copy-file "/limn/sioyek/tutorial.pdf" "/tmp/paper-B.pdf")

(format t "~%── W10 跨檔 bookmark ──~%")
(nuke-sidecars)

(let* ((sock (format nil "/tmp/limn-w10-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w10.log" :if-output-exists :supersede
              :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate")
  (sleep 0.3)

  ;; Open paper-A
  (let* ((rA (safe-call "bridge/engine-load" :|engine| "mupdf"
                         :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1"))
         (bid-A (and (eq (car rA) :ok) (getf (cdr rA) :|buffer-id|))))
    (format t "  paper A buffer-id = ~a~%" bid-A)
    (sleep 0.5)
    (safe-call "view/set" :|win-id| "w1" :|page| 3)
    (sleep 0.3)
    (let ((r (handler-case
                 (cons :ok (limn/pdf-mode:pdf-set-bookmark-name bid-A "m" 3))
               (error (e) (cons :err e)))))
      (check "A.1 set bookmark m on paper-A page 3"
             (eq (car r) :ok)
             (if (eq (car r) :err) (format nil "err ~a" (cdr r)) "ok")))

    ;; Open paper-B
    (let* ((rB (safe-call "bridge/engine-load" :|engine| "mupdf"
                           :|path| "/tmp/paper-B.pdf" :|win-id| "w1"))
           (bid-B (and (eq (car rB) :ok) (getf (cdr rB) :|buffer-id|))))
      (format t "  paper B buffer-id = ~a~%" bid-B)
      (sleep 0.5)
      (safe-call "view/set" :|win-id| "w1" :|page| 5)
      (sleep 0.3)
      (let ((r (handler-case
                   (cons :ok (limn/pdf-mode:pdf-set-bookmark-name bid-B "b" 5))
                 (error (e) (cons :err e)))))
        (check "A.2 set bookmark b on paper-B page 5"
               (eq (car r) :ok)
               (if (eq (car r) :err) (format nil "err ~a" (cdr r)) "ok")))

      ;; Switch back to paper-A, jump m
      (safe-call "bridge/engine-load" :|engine| "mupdf"
                  :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1")
      (sleep 0.5)
      ;; reset page
      (safe-call "view/set" :|win-id| "w1" :|page| 0)
      (sleep 0.2)
      ;; bid-A may have changed if buffer was re-opened
      (let* ((rA2 (safe-call "view/get" :|win-id| "w1"))
             (bid-A-now (and (eq (car rA2) :ok) (getf (cdr rA2) :|buffer-id|))))
        (format t "  paper A re-opened buffer-id = ~a~%" bid-A-now)
        (handler-case (limn/pdf-mode:pdf-jump-bookmark-name bid-A-now "m")
          (error (e) (format t "  jump-m err: ~a~%" e)))
        (sleep 0.3)
        (let ((p (page-now)))
          (check "A.3 'm on paper-A jumps to page 3 (持久化)"
                 (and (numberp p) (= p 3))
                 (format nil "page=~a" p))))

      ;; Switch to paper-B, jump b
      (safe-call "bridge/engine-load" :|engine| "mupdf"
                  :|path| "/tmp/paper-B.pdf" :|win-id| "w1")
      (sleep 0.5)
      (safe-call "view/set" :|win-id| "w1" :|page| 0)
      (sleep 0.2)
      (let* ((rB2 (safe-call "view/get" :|win-id| "w1"))
             (bid-B-now (and (eq (car rB2) :ok) (getf (cdr rB2) :|buffer-id|))))
        (handler-case (limn/pdf-mode:pdf-jump-bookmark-name bid-B-now "b")
          (error (e) (format t "  jump-b err: ~a~%" e)))
        (sleep 0.3)
        (let ((p (page-now)))
          (check "A.4 'b on paper-B jumps to page 5 (跨檔)"
                 (and (numberp p) (= p 5))
                 (format nil "page=~a" p))))))

  (let ((log (with-open-file (s "/tmp/limn-w10.log" :if-does-not-exist nil)
               (when s (let ((b (make-string (file-length s))))
                         (read-sequence b s) b)))))
    (when log
      (with-open-file (s (concatenate 'string *out-dir* "limn.log")
                          :direction :output :if-exists :supersede)
        (write-sequence log s))))
  (nuke-sidecars)
  (ignore-errors (delete-file "/tmp/paper-B.pdf"))
  (ignore-errors
    (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t))
  (sleep 0.2))

(let* ((rev (reverse *results*))
       (pass (count-if #'cdr rev)) (total (length rev)) (fail (- total pass)))
  (format t "~%── W10 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
