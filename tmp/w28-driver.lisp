;;;; W28 driver — M-x completion → execute
;;;; 先試 alt+x（可能撞 B5），如撞到 fallback direct-call execute-command.

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

(defparameter *out-dir* "/host-tmp/receipts/28/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (l ok &optional (d ""))
  (push (cons l ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") l
          (if (string= d "") "" (format nil "   [~a]" d))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(format t "~%── W28 M-x completion → execute ──~%")

(let* ((sock (format nil "/tmp/limn-w28-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w28.log" :if-output-exists :supersede
              :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate")
  (sleep 0.3)

  ;; Phase A: alt+x triggers minibuffer open?
  (format t "~%── Phase A: alt+x ──~%")
  (xdotool "key" "--clearmodifiers" "alt+x")
  (sleep 0.5)
  (let* ((mb (safe-call "minibuffer/get"))
         (open (and (eq (car mb) :ok) (eq (getf (cdr mb) :|open|) t))))
    (check "A.1 alt+x opens minibuffer (M-x dispatch path)"
           open
           (format nil "minibuffer: ~a" (if (eq (car mb) :ok) (cdr mb) "err"))))
  ;; close if opened
  (xdotool "key" "--clearmodifiers" "Escape")
  (sleep 0.3)

  ;; Phase B: command registry — execute-command lookup
  (format t "~%── Phase B: registry lookup ──~%")
  (let ((cmds (and (find-package '#:limn/cmd)
                    (funcall (find-symbol "LIST-COMMANDS" :limn/cmd)))))
    (check "B.1 limn/cmd:list-commands returns non-empty"
           (and cmds (> (length cmds) 0))
           (format nil "~a commands" (and cmds (length cmds)))))

  (let* ((cmds (and (find-package '#:limn/cmd)
                     (funcall (find-symbol "LIST-COMMANDS" :limn/cmd))))
         (names (mapcar (lambda (c)
                          (string-downcase
                           (symbol-name
                            (funcall (find-symbol "COMMAND-NAME" :limn/cmd) c))))
                        cmds))
         (que-matches (remove-if-not (lambda (n) (search "que" n)) names)))
    (check "B.2 'que' prefix matches at least one command"
           (and que-matches (> (length que-matches) 0))
           (format nil "matches: ~a" que-matches)))

  (let ((log (with-open-file (s "/tmp/limn-w28.log" :if-does-not-exist nil)
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
  (format t "~%── W28 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
