;;;; W06 driver — 單檔搜尋 / + n + C-g
;;;; / 開 isearch-forward → 鍵入 "the" → RET → n×3 → N×2 → C-g

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

(defparameter *out-dir* "/host-tmp/receipts/06/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (l ok &optional (d ""))
  (push (cons l ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") l
          (if (string= d "") "" (format nil "   [~a]" d))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(defun key (k &optional (s 0.22)) (xdotool "key" "--clearmodifiers" k) (sleep s))

(defun search-state ()
  "Return current pdf-search-state as plist via wire (if available)."
  (let* ((r (safe-call "view/get" :|win-id| "w1"))
         (data (and (eq (car r) :ok) (cdr r))))
    data))

(defun overlay-count ()
  (let* ((r (safe-call "view/get" :|win-id| "w1"))
         (data (and (eq (car r) :ok) (cdr r)))
         (overlays (and data (getf data :|overlays|))))
    (and overlays (length overlays))))

(format t "~%── W06 single-file search ──~%")

(let* ((sock (format nil "/tmp/limn-w06-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w06.log" :if-output-exists :supersede
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

  (let ((oc0 (overlay-count)))
    (format t "  baseline overlay count = ~a~%" oc0)

    ;; '/' → isearch-forward → minibuffer opens
    (format t "~%── press / ──~%")
    (key "slash" 0.4)
    (let* ((mb (safe-call "minibuffer/get"))
           (open (and (eq (car mb) :ok) (eq (getf (cdr mb) :|open|) t))))
      (check "A.1 / opens minibuffer for isearch"
             open
             (format nil "minibuffer: ~a"
                     (if (eq (car mb) :ok) (cdr mb) "err"))))

    ;; Type "the"
    (xdotool "type" "--delay" "60" "the")
    (sleep 0.4)
    (let* ((mb (safe-call "minibuffer/get"))
           (text (and (eq (car mb) :ok) (getf (cdr mb) :|text|))))
      (check "A.2 minibuffer contains 'the' after typing"
             (string= text "the")
             (format nil "text=~s" text)))

    ;; RET to commit search
    (key "Return" 0.5)
    (let ((oc-after-search (overlay-count)))
      (format t "  after RET: overlay count = ~a~%" oc-after-search)
      (check "A.3 search produced overlays (hits highlighted)"
             (and (numberp oc-after-search) (> oc-after-search 0))
             (format nil "overlays=~a" oc-after-search)))

    ;; n / N navigation
    (key "n") (key "n") (key "n") (key "N") (key "N")
    (sleep 0.3)
    (check "A.4 limn still alive after n/N navigation"
           (eq (car (safe-call "view/get" :|win-id| "w1")) :ok))

    ;; C-g should clear overlays
    (key "ctrl+g" 0.4)
    (let ((oc-after-cg (overlay-count)))
      (format t "  after C-g: overlay count = ~a~%" oc-after-cg)
      (check "A.5 C-g cleared search overlays"
             (or (null oc-after-cg) (zerop oc-after-cg))
             (format nil "overlays=~a" oc-after-cg))))

  (let ((log (with-open-file (s "/tmp/limn-w06.log" :if-does-not-exist nil)
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
  (format t "~%── W06 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
