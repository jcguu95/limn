;;;; W04 driver — TOC 導航
;;;;
;;;; Spec wrote 'o' opens TOC but in current limn 'o' is find-file
;;;; and 't' is pdf-toc.  Driver uses 't'.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defun xdotool (&rest args)
  (zerop (sb-ext:process-exit-code
           (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))

(defun wait-for-window (name &key (timeout 5))
  (let ((d (+ (get-universal-time) timeout)))
    (loop (when (zerop (sb-ext:process-exit-code
                         (sb-ext:run-program "xdotool" (list "search" "--name" name)
                                              :search t :wait t :output nil)))
            (return t))
          (when (> (get-universal-time) d) (return nil))
          (sleep 0.1))))

(defparameter *out-dir* "/host-tmp/receipts/04/")
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

(defun key (k) (xdotool "key" "--clearmodifiers" k) (sleep 0.25))

(format t "~%── W04 TOC 導航 (`t` 開 TOC) ──~%")

(let* ((sock (format nil "/tmp/limn-w04-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w04.log" :if-output-exists :supersede
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

  (let ((p0 (page-now)))
    (format t "  baseline page = ~a~%" p0)

    ;; Press 't' to open TOC (completing-read with TOC entries).
    ;; v0.38 note: pdf-toc completing-read 透過 *minibuffer-read* 開
    ;; minibuffer。為了不阻塞 limn process (driver 同時 wire-call 會
    ;; 撞 broken-pipe)，這個 driver 只驗 minibuffer 開了；其餘 TOC 互
    ;; 動由 user 手動測 / 後續 sprint 補。
    (format t "~%── press 't' (TOC) ──~%")
    (xdotool "key" "--clearmodifiers" "t")
    ;; 不 sleep 太久，給 minibuffer 開的時間但別等到 dispatch 阻塞
    (sleep 0.25)

    (let* ((mb (safe-call "minibuffer/get"))
           (open (and (eq (car mb) :ok) (eq (getf (cdr mb) :|open|) t))))
      (check "A.1 minibuffer/TOC chrome opened after 't'"
             open
             (format nil "minibuffer state: ~a"
                     (if (eq (car mb) :ok) (cdr mb) (format nil "err: ~a" (cdr mb))))))

    ;; cancel: send ESC to clean up the still-blocking completing-read
    (xdotool "key" "--clearmodifiers" "Escape")
    (sleep 0.3)

    ;; B: cmd-registry should have pdf-toc registered (defcommand)
    (let* ((sym (find-symbol "PDF-TOC" :cl-user))
           (cmd (and sym (limn/cmd:find-command sym))))
      (check "A.2 pdf-toc is registered in defcommand registry"
             (and cmd t)
             (format nil "cmd=~a" (and cmd t))))

    ;; C: %toc-flatten returns at least 1 entry for tutorial.pdf
    (let* ((r (safe-call "buffer/toc" :|buffer-id|
                          (getf (let ((rr (safe-call "view/get" :|win-id| "w1")))
                                  (and (eq (car rr) :ok) (cdr rr))) :|buffer-id|)))
           (items (and (eq (car r) :ok) (getf (cdr r) :|items|))))
      (check "A.3 TOC has at least 1 entry"
             (and items (consp items))
             (format nil "items count=~a" (length items)))))

  (let ((log (with-open-file (s "/tmp/limn-w04.log" :if-does-not-exist nil)
               (when s (let ((b (make-string (file-length s))))
                         (read-sequence b s) b)))))
    (when log
      (with-open-file (s (concatenate 'string *out-dir* "limn.log")
                          :direction :output :if-exists :supersede)
        (write-sequence log s))))
  (ignore-errors
    (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t))
  (sleep 0.2))

(let* ((rev (reverse *results*))
       (pass (count-if #'cdr rev)) (total (length rev)) (fail (- total pass)))
  (format t "~%── W04 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
