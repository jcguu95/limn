;;;; W22 driver — keybind + hot-reload
;;;;
;;;; 1. Empty init.lisp.  2. Start limn, load tutorial.pdf, press 'v'
;;;;    (no binding) → expect nothing.
;;;; 2. Write init.lisp that binds 'v' → my-w22-canary.
;;;; 3. reload-init-file (direct call; B5: M-r dispatch broken).
;;;; 4. Press 'v' → expect canary file written.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))
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
(defparameter *out-dir*   "/host-tmp/receipts/22/")
(ensure-directories-exist *out-dir*)
(ensure-directories-exist (directory-namestring *init-path*))

(defun write-init (content)
  (with-open-file (s *init-path* :direction :output :if-exists :supersede)
    (write-sequence content s)))

(defun slurp (path)
  (with-open-file (s path :if-does-not-exist nil)
    (when s (let ((b (make-string (file-length s))))
              (read-sequence b s) b))))

(defparameter *empty-init*
  ";;;; W22 phase-A baseline: no v binding.
(in-package :cl-user)
")

(defparameter *binding-init*
  ";;;; W22 phase-B: bind 'v' to my-w22-canary on pdf-mode-map.
(in-package :cl-user)
(defun my-w22-canary ()
  (with-open-file (s \"/tmp/w22-canary\" :direction :output :if-exists :supersede)
    (write-string \"V_KEY_PRESSED\" s)))
(limn/map-macro:map! :mode 'pdf-mode \"v\" 'my-w22-canary)
")

(defparameter *results* nil)
(defun check (label ok &optional (details ""))
  (push (cons label ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") label
          (if (string= details "") ""
              (format nil "   [~a]" details))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(format t "~%── W22 keybind + hot-reload ──~%")

(write-init *empty-init*)
(sb-posix:setenv "LIMN_INIT" *init-path* 1)
(ignore-errors (delete-file "/tmp/w22-canary"))

(let* ((sock (format nil "/tmp/limn-w22-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w22.log" :if-output-exists :supersede
              :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate")
  (sleep 0.3)

  ;; Open the PDF so pdf-mode is active
  (let ((r (safe-call "bridge/engine-load" :|engine| "mupdf"
                       :|path| "/limn/sioyek/tutorial.pdf"
                       :|win-id| "w1")))
    (check "setup: engine-load tutorial.pdf"
           (eq (car r) :ok)
           (if (eq (car r) :ok) "ok" (format nil "err: ~a" (cdr r)))))
  (sleep 0.5)

  ;; ──── Phase A: empty init.  Press 'v' → nothing.
  (format t "~%── Phase A: empty init, press 'v' (expect no canary) ──~%")
  (xdotool "key" "--clearmodifiers" "v")
  (sleep 0.4)
  (check "A.1 'v' produces no canary (no binding yet)"
         (null (slurp "/tmp/w22-canary"))
         (format nil "canary: ~s (should be NIL)" (slurp "/tmp/w22-canary")))

  ;; ──── Phase B: write init.lisp with v binding, reload, press v
  (format t "~%── Phase B: rewrite init.lisp + reload + press 'v' ──~%")
  (write-init *binding-init*)
  (handler-case
      (limn/cmd:call-interactively (find-symbol "RELOAD-INIT-FILE" :cl-user))
    (error (e) (format t "  reload error (caught): ~a~%" e)))
  (sleep 0.3)

  ;; Press 'v' — should trigger my-w22-canary now
  (ignore-errors (delete-file "/tmp/w22-canary"))
  (xdotool "key" "--clearmodifiers" "v")
  (sleep 0.4)
  (let ((c (slurp "/tmp/w22-canary")))
    (check "B.1 after reload, 'v' triggers canary write"
           (and c (search "V_KEY_PRESSED" c) t)
           (format nil "canary: ~s" c)))

  ;; ──── Phase C: original binding (n) still works (regression)
  (format t "~%── Phase C: pre-existing 'n' binding still works ──~%")
  (safe-call "view/set" :|win-id| "w1" :|page| 0 :|offset-y| 0.0)
  (sleep 0.3)
  (xdotool "key" "--clearmodifiers" "n")
  (sleep 0.4)
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (if (eq (car r) :ok)
        (let* ((d (cdr r)) (page (getf d :|page|)))
          (check "C.1 'n' still advances page (reload didn't break it)"
                 (and (numberp page) (> page 0))
                 (format nil "page=~a" page)))
        (check "C.1 view/get after n" nil (format nil "err: ~a" (cdr r)))))

  ;; Cleanup
  (let ((log (slurp "/tmp/limn-w22.log")))
    (when log
      (with-open-file (s (concatenate 'string *out-dir* "limn.log")
                          :direction :output :if-exists :supersede)
        (write-sequence log s))))
  (write-init *empty-init*)
  (ignore-errors
    (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t))
  (sleep 0.2))

(let* ((rev (reverse *results*))
       (pass (count-if #'cdr rev)) (total (length rev)) (fail (- total pass)))
  (format t "~%── W22 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (format t "FAILURES:~%")
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
