;;;; W27 driver — init.lisp 帶語法錯誤 → reload 不死、有 error msg、原 binding 仍能用
;;;;
;;;; Defensive version: wrap every wire call in handler-case, snapshot
;;;; log to host-tmp at each phase end so we always have receipts even
;;;; if limn crashes mid-flight.

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
      (let ((p (sb-ext:run-program "xdotool"
                                    (list "search" "--name" name)
                                    :search t :wait t :output nil)))
        (when (zerop (sb-ext:process-exit-code p))
          (return t)))
      (when (> (get-universal-time) deadline)
        (return nil))
      (sleep 0.1))))

(defparameter *init-path* "/tmp/.limn/init.lisp")
(defparameter *log-path*  "/tmp/limn-w27.log")
(defparameter *out-dir*   "/host-tmp/receipts/27/")
(ensure-directories-exist *out-dir*)
(ensure-directories-exist (directory-namestring *init-path*))

(defun write-init (content)
  (with-open-file (s *init-path* :direction :output :if-exists :supersede)
    (write-sequence content s)))

(defparameter *valid-init*
  ";;;; W27 phase-A valid init
(in-package :cl-user)
(with-open-file (s \"/tmp/w27-canary\" :direction :output :if-exists :supersede)
  (write-string \"VALID_LOADED_ALPHA\" s))
")

;; Broken: form 1 writes a canary (should fire), form 2 has unclosed
;; parens (reader error), form 3 writes another canary (should NOT fire).
(defparameter *broken-init*
  ";;;; W27 phase-B broken init (deliberate reader error)
(in-package :cl-user)
(with-open-file (s \"/tmp/w27-canary-half\" :direction :output :if-exists :supersede)
  (write-string \"BROKEN_HALF_RAN\" s))
(defparameter *w27-broken* (lambda (x) (+ x
;; ← missing two close parens above
(with-open-file (s \"/tmp/w27-canary-after\" :direction :output :if-exists :supersede)
  (write-string \"AFTER_BROKEN_RAN\" s))
")

(defun slurp (path)
  (with-open-file (s path :if-does-not-exist nil)
    (when s
      (let ((buf (make-string (file-length s))))
        (read-sequence buf s)
        buf))))

(defun snapshot-log (suffix)
  "Copy current limn log into receipts/27/ with SUFFIX."
  (let ((txt (slurp *log-path*)))
    (when txt
      (with-open-file (s (concatenate 'string *out-dir* "limn-" suffix ".log")
                          :direction :output :if-exists :supersede)
        (write-sequence txt s)))))

(defparameter *results* nil)
(defun check (label ok &optional (details ""))
  (push (cons label ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") label
          (if (string= details "") ""
              (format nil "   [~a]" details))))

(defun safe-call (cmd &rest args)
  "limn:call with broken-pipe protection.  Returns (:ok . data) or (:err . cond)."
  (handler-case
      (let ((r (apply #'limn:call cmd args)))
        (cons :ok (limn/bridge:response-data r)))
    (error (e) (cons :err e))))

(format t "~%── W27 init.lisp 帶語法錯誤 → reload ──~%")

;; ──── Setup: write VALID init, launch limn ──────────────────────
(write-init *valid-init*)
(sb-posix:setenv "LIMN_INIT" *init-path* 1)

(let* ((sock (format nil "/tmp/limn-w27-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output *log-path* :if-output-exists :supersede
              :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate")
  (sleep 0.3)

  ;; ──── Phase A: VALID init reload via M-r ──────────────────────
  (format t "~%── Phase A: valid init reload ──~%")
  ;; clean any prior canary
  (ignore-errors (delete-file "/tmp/w27-canary"))
  ;; W27 NOTE: alt+r xdotool keystroke does NOT seem to reach
  ;; reload-init-file in current test-mode (logged as W27-bug-X in
  ;; backlog).  For W27's actual subject (broken-init handling), call
  ;; reload-init-file directly via call-interactively — exercises the
  ;; same Lisp path the M-r dispatch would.
  (limn/cmd:call-interactively (find-symbol "RELOAD-INIT-FILE" :cl-user))
  (sleep 0.7)
  (snapshot-log "after-phase-a")
  (let ((c (slurp "/tmp/w27-canary")))
    (check "A.1 valid init canary file exists with VALID_LOADED_ALPHA after M-r"
           (and c (search "VALID_LOADED_ALPHA" c) t)
           (format nil "canary content: ~s" c)))

  ;; ──── Phase B: BROKEN init, reload ──────────────────────────
  (format t "~%── Phase B: write broken init + reload ──~%")
  (write-init *broken-init*)
  (ignore-errors (delete-file "/tmp/w27-canary-half"))
  (ignore-errors (delete-file "/tmp/w27-canary-after"))
  ;; W27 NOTE: alt+r xdotool keystroke does NOT seem to reach
  ;; reload-init-file in current test-mode (logged as W27-bug-X in
  ;; backlog).  For W27's actual subject (broken-init handling), call
  ;; reload-init-file directly via call-interactively — exercises the
  ;; same Lisp path the M-r dispatch would.
  (limn/cmd:call-interactively (find-symbol "RELOAD-INIT-FILE" :cl-user))
  (sleep 1.0)
  (snapshot-log "after-phase-b-reload")

  ;; B.1: process still responds
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (check "B.1 limn responds to view/get after broken reload"
           (eq (car r) :ok)
           (if (eq (car r) :err)
               (format nil "error: ~a" (cdr r))
               "ok")))

  ;; B.2: first form of broken init DID execute (before reader hit error)
  (let ((c (slurp "/tmp/w27-canary-half")))
    (check "B.2a broken init's first form (before error) ran"
           (and c (search "BROKEN_HALF_RAN" c) t)
           (format nil "canary-half: ~s" c)))

  ;; B.2b: post-error form did NOT execute (reader stopped early)
  (let ((c (slurp "/tmp/w27-canary-after")))
    (check "B.2b broken init's post-error form did NOT run"
           (null c)
           (format nil "canary-after: ~s (should be NIL)" c)))

  ;; ──── Phase B.3: original keymap still functional ───────────
  (format t "~%── Phase B.3: j key still works ──~%")
  (let ((load-r (safe-call "bridge/engine-load" :|engine| "mupdf"
                            :|path| "/limn/sioyek/tutorial.pdf"
                            :|win-id| "w1")))
    (cond
      ((eq (car load-r) :err)
       (check "B.3a engine-load works (precondition)" nil
              (format nil "engine-load errored: ~a" (cdr load-r))))
      (t
       (sleep 0.4)
       (safe-call "view/set" :|win-id| "w1" :|page| 0 :|offset-y| 0.0)
       (sleep 0.3)
       (xdotool "key" "--clearmodifiers" "j")
       (sleep 0.5)
       (let ((r (safe-call "view/get" :|win-id| "w1")))
         (if (eq (car r) :err)
             (check "B.3 j key result readable" nil
                    (format nil "view/get errored: ~a" (cdr r)))
             (let* ((data (cdr r))
                    (page (getf data :|page|))
                    (offset-y (getf data :|offset-y|)))
               (check "B.3 j key still scrolls/turns after broken-reload"
                      (or (and (numberp page) (> page 0))
                          (and (numberp offset-y) (> offset-y 0)))
                      (format nil "page=~a offset-y=~a" page offset-y))))))))

  (snapshot-log "final")
  (write-init *valid-init*)

  (ignore-errors
    (let ((bad-procs (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn")
                                           :search t :wait t)))
      (declare (ignore bad-procs))))
  (sleep 0.2))

;; ──── verdict ─────────────────────────────────────────────────────
(let* ((reversed (reverse *results*))
       (pass (count-if #'cdr reversed))
       (total (length reversed))
       (fail (- total pass)))
  (format t "~%── W27 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (format t "FAILURES:~%")
    (dolist (r reversed) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
