;;;; W08 driver — 5 高亮 round-trip
;;;; Use wire view/selection-set to create selection (no mouse drag),
;;;; xdotool key h to actually highlight (R2' keystroke is the action).
;;;; Close PDF and reopen, verify annotation count via wire.

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

(defparameter *out-dir* "/host-tmp/receipts/08/")
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

(defun key (k &optional (s 0.22)) (xdotool "key" "--clearmodifiers" k) (sleep s))

(defun nuke-sidecars ()
  (let ((dir (merge-pathnames ".limn/annotations/"
                              (or (sb-posix:getenv "HOME") "/root/"))))
    (when (probe-file dir)
      (dolist (f (ignore-errors (directory (merge-pathnames "*.lisp" dir))))
        (ignore-errors (delete-file f))))))

(defun make-selection (page x1 y1 x2 y2)
  (safe-call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| page :|x| x1 :|y| y1)
              :|end|   (list :|page| page :|x| x2 :|y| y2))
  (sleep 0.2))

(format t "~%── W08 5 高亮 round-trip ──~%")

(nuke-sidecars)

(let* ((sock (format nil "/tmp/limn-w08-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w08.log" :if-output-exists :supersede
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

  ;; Make 5 highlights on different pages (tutorial has 6 pages, p0..p5)
  (loop for p from 0 below 5 do
    (safe-call "view/set" :|win-id| "w1" :|page| p)
    (sleep 0.2)
    (make-selection p 0.2 (+ 0.2 (* p 0.05)) 0.6 (+ 0.25 (* p 0.05)))
    (key "h" 0.35))

  (let ((oc (overlay-count)))
    (format t "  after 5 highlights: overlay count = ~a~%" oc)
    (check "A.1 5 highlights created (overlay count >= 5)"
           (and (numberp oc) (>= oc 5))
           (format nil "overlays=~a" oc)))

  ;; Close buffer → reopen
  (format t "~%── close + reopen tutorial.pdf ──~%")
  (safe-call "buffer/close" :|win-id| "w1")
  (sleep 0.3)
  (safe-call "bridge/engine-load" :|engine| "mupdf"
              :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1")
  (sleep 0.8)

  (let ((oc (overlay-count)))
    (format t "  after reopen: overlay count = ~a~%" oc)
    (check "A.2 5 highlights survived close+reopen (sidecar persisted)"
           (and (numberp oc) (>= oc 5))
           (format nil "overlays=~a" oc)))

  (let ((log (with-open-file (s "/tmp/limn-w08.log" :if-does-not-exist nil)
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
  (format t "~%── W08 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
