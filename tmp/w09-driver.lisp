;;;; W09 driver — 建/刪/再建高亮
;;;; 3 highlight → 刪中間 → 剩 2 → 加第 4 → 共 3

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

(defparameter *out-dir* "/host-tmp/receipts/09/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (l ok &optional (d ""))
  (push (cons l ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") l
          (if (string= d "") "" (format nil "   [~a]" d))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(defun overlays ()
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (and (eq (car r) :ok) (or (getf (cdr r) :|overlays|) '()))))

(defun key (k &optional (s 0.3)) (xdotool "key" "--clearmodifiers" k) (sleep s))

(defun nuke-sidecars ()
  (let ((dir (merge-pathnames ".limn/annotations/"
                              (or (sb-posix:getenv "HOME") "/root/"))))
    (when (probe-file dir)
      (dolist (f (ignore-errors (directory (merge-pathnames "*.lisp" dir))))
        (ignore-errors (delete-file f))))))

(defun mksel (p y0 y1)
  (safe-call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| p :|x| 0.2 :|y| y0)
              :|end|   (list :|page| p :|x| 0.6 :|y| y1))
  (sleep 0.2))

(format t "~%── W09 建/刪/再建高亮 ──~%")
(nuke-sidecars)

(let* ((sock (format nil "/tmp/limn-w09-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w09.log" :if-output-exists :supersede
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

  ;; 3 highlights on page 0
  (mksel 0 0.20 0.25) (key "h")
  (mksel 0 0.30 0.35) (key "h")
  (mksel 0 0.40 0.45) (key "h")
  (let ((n (length (overlays))))
    (check "A.1 3 highlights created"
           (= n 3) (format nil "overlays=~a" n)))

  ;; Delete the middle highlight via the Lisp API pdf-annotations-delete-at-point.
  ;; No "view/overlay-delete" wire cmd exists; the user-facing path is
  ;; %add-annotation / pdf-annotations-delete-at-point + %refresh-overlays.
  ;; Middle rect was at y 0.30..0.35; use the mid-point of the rect as
  ;; the (x,y) for delete-at-point.
  (let ((path (limn/pdf-mode::%current-pdf-path)))
    (format t "  current path = ~s~%" path)
    (if path
        (let ((deleted (limn/pdf-mode:pdf-annotations-delete-at-point
                         path 0 0.4 0.32)))
          (sleep 0.3)
          (check "A.2 delete-at-point returned truthy (target found)"
                 deleted
                 (format nil "deleted=~a" deleted)))
        (check "A.2 path resolves" nil "no path")))

  (let ((n (length (overlays))))
    (check "A.3 remaining 2 after middle deletion"
           (= n 2) (format nil "overlays=~a" n)))

  ;; Add 4th highlight
  (mksel 0 0.50 0.55) (key "h")
  (let ((n (length (overlays))))
    (check "A.4 add 4th → 3 highlights total"
           (= n 3) (format nil "overlays=~a" n)))

  (let ((log (with-open-file (s "/tmp/limn-w09.log" :if-does-not-exist nil)
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
  (format t "~%── W09 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
