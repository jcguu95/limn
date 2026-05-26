;;;; W26 driver — add-hook 驗證
;;;;
;;;; W26 spec 寫 'pdf-mode-hook，但 Limn 沒這個名字 — 用 string-keyed
;;;; 事件 "event/buffer-opened" 取代 (pdf-mode 自己就 subscribe 這個
;;;; 事件來載 sidecar)。init.lisp 加 handler 寫 canary，開 PDF，驗
;;;; canary 出現。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defun xdotool (&rest args)
  (let ((p (sb-ext:run-program "xdotool" args :search t
                                :wait t :output t :error t)))
    (zerop (sb-ext:process-exit-code p))))

(defun wait-for-window (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((p (sb-ext:run-program "xdotool" (list "search" "--name" name)
                                    :search t :wait t :output nil)))
        (when (zerop (sb-ext:process-exit-code p)) (return t)))
      (when (> (get-universal-time) deadline) (return nil))
      (sleep 0.1))))

(defparameter *init-path* "/tmp/.limn/init.lisp")
(defparameter *out-dir*   "/host-tmp/receipts/26/")
(ensure-directories-exist *out-dir*)
(ensure-directories-exist (directory-namestring *init-path*))

(defun write-init (content)
  (with-open-file (s *init-path* :direction :output :if-exists :supersede)
    (write-sequence content s)))

(defparameter *hook-init*
  ";;;; W26 hook test init.
(in-package :cl-user)
(limn/hooks:add-hook \"event/buffer-opened\"
  (lambda (ev)
    (with-open-file (s \"/tmp/w26-canary\" :direction :output :if-exists :supersede)
      (format s \"HOOK_FIRED path=~a\" (getf ev :|path|)))))
")

(defun slurp (path)
  (with-open-file (s path :if-does-not-exist nil)
    (when s (let ((b (make-string (file-length s)))) (read-sequence b s) b))))

(defparameter *results* nil)
(defun check (label ok &optional (details ""))
  (push (cons label ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") label
          (if (string= details "") "" (format nil "   [~a]" details))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(format t "~%── W26 add-hook 驗證 ──~%")

(write-init *hook-init*)
(sb-posix:setenv "LIMN_INIT" *init-path* 1)
(ignore-errors (delete-file "/tmp/w26-canary"))

(let* ((sock (format nil "/tmp/limn-w26-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w26.log" :if-output-exists :supersede
              :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (sleep 0.5)

  ;; engine-load triggers event/buffer-opened
  (format t "~%── engine-load tutorial.pdf (expect hook fire) ──~%")
  (let ((r (safe-call "bridge/engine-load" :|engine| "mupdf"
                       :|path| "/limn/sioyek/tutorial.pdf"
                       :|win-id| "w1")))
    (check "setup: engine-load ok"
           (eq (car r) :ok)
           (if (eq (car r) :err) (format nil "~a" (cdr r)) "ok")))
  (sleep 0.8)

  ;; Check canary
  (let ((c (slurp "/tmp/w26-canary")))
    (check "A.1 hook fired on buffer-opened, canary written"
           (and c (search "HOOK_FIRED" c) t)
           (format nil "canary: ~s" c)))
  (let ((c (slurp "/tmp/w26-canary")))
    (check "A.2 canary contains path=/limn/sioyek/tutorial.pdf"
           (and c (search "tutorial.pdf" c) t)
           (format nil "canary: ~s" c)))

  ;; Snapshot log
  (let ((log (slurp "/tmp/limn-w26.log")))
    (when log
      (with-open-file (s (concatenate 'string *out-dir* "limn.log")
                          :direction :output :if-exists :supersede)
        (write-sequence log s))))
  (ignore-errors
    (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t))
  (sleep 0.2))

(let* ((rev (reverse *results*))
       (pass (count-if #'cdr rev)) (total (length rev)) (fail (- total pass)))
  (format t "~%── W26 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
