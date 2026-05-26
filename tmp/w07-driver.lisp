;;;; W07 driver — isearch 即時搜尋 (incremental highlighting while typing)
;;;; 用 / (PDF-ISEARCH-FORWARD)。觀察打字過程中 overlay count 是否變化。

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

(defparameter *out-dir* "/host-tmp/receipts/07/")
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

(defun mb-text ()
  (let ((r (safe-call "minibuffer/get")))
    (and (eq (car r) :ok) (getf (cdr r) :|text|))))

(defun key (k &optional (s 0.25)) (xdotool "key" "--clearmodifiers" k) (sleep s))
(defun type-char (c) (xdotool "type" "--delay" "60" c) (sleep 0.2))

(format t "~%── W07 isearch (incremental?) ──~%")

(let* ((sock (format nil "/tmp/limn-w07-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w07.log" :if-output-exists :supersede
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

  ;; / + type "fig" — note state after each char
  (key "slash" 0.4)
  (type-char "f")
  (let ((oc-f (overlay-count)) (tx (mb-text)))
    (format t "  after 'f': minibuffer=~s overlays=~a~%" tx oc-f)
    (check "A.1 typing 'f' incrementally updates overlays (or not)"
           (numberp oc-f)
           (format nil "overlays=~a (note: pre-RET overlay state)" oc-f)))
  (type-char "i") (type-char "g")
  (let ((oc-fig (overlay-count)) (tx (mb-text)))
    (format t "  after 'fig': minibuffer=~s overlays=~a~%" tx oc-fig)
    (check "A.2 minibuffer reads 'fig'" (string= tx "fig")
           (format nil "text=~s" tx)))

  ;; backspace + type "ure" → "fiure"
  (key "BackSpace")
  (type-char "u") (type-char "r") (type-char "e")
  (let ((tx (mb-text)))
    (check "A.3 backspace + type leaves 'fiure' in minibuffer"
           (string= tx "fiure")
           (format nil "text=~s" tx)))

  ;; RET commits; expect overlays for "fiure" (might be 0 hits!)
  (key "Return" 0.5)
  (let ((oc-commit (overlay-count)))
    (format t "  after RET: overlays=~a~%" oc-commit)
    (check "A.4 RET commits search (numeric overlay count)"
           (numberp oc-commit)
           (format nil "overlays=~a" oc-commit)))

  (let ((log (with-open-file (s "/tmp/limn-w07.log" :if-does-not-exist nil)
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
  (format t "~%── W07 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
