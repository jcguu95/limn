;;;; W20 driver — 新檔 → 寫 → 落地
;;;;
;;;; 用 xdotool type 把內容打進去 (R2' 真實鍵盤)，限制：因為 C-x C-f
;;;; 預設沒綁，這次先 direct-call find-file 把 buffer 開出來（同 W27
;;;; 套路：跳過 dispatch、保留 action-level 驗證）。

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

(defparameter *fresh-path*
  (format nil "/tmp/w20-fresh-~a.txt" (sb-posix:getpid)))
(defparameter *out-dir* "/host-tmp/receipts/20/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (label ok &optional (details ""))
  (push (cons label ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") label
          (if (string= details "") ""
              (format nil "   [~a]" details))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(format t "~%── W20 新檔 → 寫 → 落地 ──~%")

;; B8 workaround: limn/file:find-file refuses non-existent paths.
;; Pre-create an empty file so find-file can pick it up.  The "new
;; file" semantic gets verified via "file was empty before; has 'hello'
;; after" rather than "file didn't exist before".
(ignore-errors (delete-file *fresh-path*))
(with-open-file (s *fresh-path* :direction :output :if-does-not-exist :create)
  (declare (ignore s)))  ; touch
(check "setup: target path is empty zero-byte file"
       (and (probe-file *fresh-path*)
            (zerop (with-open-file (s *fresh-path*) (file-length s))))
       *fresh-path*)

(let* ((sock (format nil "/tmp/limn-w20-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w20.log" :if-output-exists :supersede
              :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate")
  (sleep 0.3)

  ;; ──── Phase A: find-file existing-empty path via direct call
  (format t "~%── Phase A: find-file empty path via direct call ──~%")
  (defvar *w20-bufid* nil)
  (let ((r (handler-case
               (cons :ok (limn/file:find-file *fresh-path*))
             (error (e) (cons :err e)))))
    (when (eq (car r) :ok) (setf *w20-bufid* (cdr r)))
    (check "A.1 find-file empty path returns buffer-id"
           (eq (car r) :ok)
           (if (eq (car r) :err)
               (format nil "err: ~a" (cdr r))
               (format nil "buffer-id=~a" (cdr r)))))

  ;; Verify a buffer for this path exists via wire
  (let ((r (safe-call "buffer/list")))
    (if (eq (car r) :ok)
        (let* ((bufs (cdr r))
               (paths (and (listp bufs) (mapcar (lambda (b) (getf b :|path|)) bufs))))
          (check "A.2 buffer list contains the new path"
                 (and paths (find *fresh-path* paths :test #'string=) t)
                 (format nil "paths=~a" paths)))
        (check "A.2 buffer list" nil (format nil "err: ~a" (cdr r)))))

  ;; ──── Phase B: type "hello" via xdotool type (R2' 真實鍵盤)
  (format t "~%── Phase B: xdotool type 'hello' ──~%")
  (sleep 0.3)
  (xdotool "type" "--delay" "30" "hello")
  (sleep 0.5)

  ;; ──── Phase C: save buffer via direct call
  (format t "~%── Phase C: save-buffer via direct call ──~%")
  (let ((r (handler-case
               (cons :ok (limn/file:save-buffer *w20-bufid*))
             (error (e) (cons :err e)))))
    (check "C.1 save-buffer returns without error"
           (eq (car r) :ok)
           (if (eq (car r) :err) (format nil "err: ~a" (cdr r)) "ok")))

  ;; ──── Phase D: file on disk
  (sleep 0.3)
  (check "D.1 file exists on disk"
         (and (probe-file *fresh-path*) t)
         *fresh-path*)
  (let ((content (when (probe-file *fresh-path*)
                   (with-open-file (s *fresh-path*)
                     (let ((b (make-string (file-length s))))
                       (read-sequence b s) b)))))
    (check "D.2 file content is 'hello' (xdotool type landed in buffer)"
           (and content (search "hello" content) t)
           (format nil "content: ~s" content)))

  ;; Cleanup
  (let ((log (with-open-file (s "/tmp/limn-w20.log" :if-does-not-exist nil)
               (when s (let ((b (make-string (file-length s))))
                         (read-sequence b s) b)))))
    (when log
      (with-open-file (s (concatenate 'string *out-dir* "limn.log")
                          :direction :output :if-exists :supersede)
        (write-sequence log s))))
  (ignore-errors (delete-file *fresh-path*))
  (ignore-errors
    (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t))
  (sleep 0.2))

(let* ((rev (reverse *results*))
       (pass (count-if #'cdr rev)) (total (length rev)) (fail (- total pass)))
  (format t "~%── W20 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (format t "FAILURES:~%")
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
