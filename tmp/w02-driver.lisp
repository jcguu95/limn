;;;; W02 driver — 數字 prefix 跳頁
;;;;
;;;; 12g → page 12, gg → page 0, G → last page, 5j → 5× scroll-down

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defun xdotool (&rest args)
  (zerop (sb-ext:process-exit-code
           (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))

(defun wait-for-window (name &key (timeout 5))
  (let ((d (+ (get-universal-time) timeout)))
    (loop
      (when (zerop (sb-ext:process-exit-code
                     (sb-ext:run-program "xdotool" (list "search" "--name" name)
                                          :search t :wait t :output nil)))
        (return t))
      (when (> (get-universal-time) d) (return nil))
      (sleep 0.1))))

(defparameter *out-dir* "/host-tmp/receipts/02/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (l ok &optional (d ""))
  (push (cons l ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") l
          (if (string= d "") "" (format nil "   [~a]" d))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(defun page-count ()
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (and (eq (car r) :ok) (getf (cdr r) :|page-count|))))

(defun page-now ()
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (and (eq (car r) :ok) (getf (cdr r) :|page|))))

(defun off-y ()
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (and (eq (car r) :ok) (getf (cdr r) :|offset-y|))))

(defun key (k) (xdotool "key" "--clearmodifiers" k) (sleep 0.18))

(format t "~%── W02 數字 prefix 跳頁 ──~%")

(let* ((sock (format nil "/tmp/limn-w02-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w02.log" :if-output-exists :supersede
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

  (let ((pc (page-count)))
    (format t "  page-count = ~a~%" pc)
    (check "setup: tutorial.pdf has > 5 pages" (and pc (> pc 5))
           (format nil "page-count=~a" pc)))

  ;; A. 12g → page 12 (if pdf has 12+ pages, else page (pc-1))
  (format t "~%── A: 12g ──~%")
  (key "1") (key "2") (key "g")
  (sleep 0.4)
  (let ((p (page-now)) (pc (page-count)))
    (let ((expected (min 12 (1- pc))))
      (check "A.1 12g → page approx 12"
             (and (numberp p) (= p expected))
             (format nil "page=~a expected=~a (pc=~a)" p expected pc))))

  ;; B. gg → 0
  (format t "~%── B: gg ──~%")
  (key "g") (key "g")
  (sleep 0.3)
  (check "B.1 gg → page 0"
         (and (numberp (page-now)) (zerop (page-now)))
         (format nil "page=~a" (page-now)))

  ;; C. G → last page
  (format t "~%── C: G ──~%")
  (key "G")
  (sleep 0.3)
  (let ((p (page-now)) (pc (page-count)))
    (check "C.1 G → last page (page-count - 1)"
           (and (numberp p) (numberp pc) (= p (1- pc)))
           (format nil "page=~a / pc=~a" p pc)))

  ;; D. gg then 5j → offset-y > base by 5 × scroll-step
  (format t "~%── D: gg + 5j ──~%")
  (key "g") (key "g")
  (sleep 0.3)
  (let ((before (off-y)))
    (key "5") (key "j")
    (sleep 0.4)
    (let ((after (off-y)))
      (check "D.1 5j scrolled 5× more than 1j (multi from prefix-arg)"
             (and (numberp before) (numberp after) (> after (+ before 0.4)))
             (format nil "before=~a after=~a delta=~a"
                     before after (and (numberp before) (numberp after) (- after before))))))

  (let ((log (with-open-file (s "/tmp/limn-w02.log" :if-does-not-exist nil)
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
  (format t "~%── W02 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
