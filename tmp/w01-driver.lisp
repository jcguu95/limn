;;;; W01 driver — j×30 連續翻頁
;;;;
;;;; Pixel verify blocked by Xvfb framebuffer (B2). Use view/get
;;;; offset-y / page progression as the "did the key actually do
;;;; something" signal. This is action-effect verification (paint
;;;; happens in C++ then state updates in C++ which we read), not
;;;; state-reader-comparing-itself.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defun xdotool (&rest args)
  (zerop (sb-ext:process-exit-code
           (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))

(defun wait-for-window (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (when (zerop (sb-ext:process-exit-code
                     (sb-ext:run-program "xdotool" (list "search" "--name" name)
                                          :search t :wait t :output nil)))
        (return t))
      (when (> (get-universal-time) deadline) (return nil))
      (sleep 0.1))))

(defparameter *out-dir* "/host-tmp/receipts/01/")
(ensure-directories-exist *out-dir*)

(defparameter *results* nil)
(defun check (label ok &optional (details ""))
  (push (cons label ok) *results*)
  (format t "  ~a ~a~a~%" (if ok "✓" "✗") label
          (if (string= details "") "" (format nil "   [~a]" details))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(defun state ()
  "Return (cons page offset-y) from view/get."
  (let ((r (safe-call "view/get" :|win-id| "w1")))
    (if (eq (car r) :ok)
        (cons (getf (cdr r) :|page|) (getf (cdr r) :|offset-y|))
        '(:err . :err))))

(format t "~%── W01 j×30 連續翻頁 ──~%")

(let* ((sock (format nil "/tmp/limn-w01-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-w01.log" :if-output-exists :supersede
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

  ;; baseline
  (let ((s0 (state)))
    (format t "  state-00 = ~s~%" s0))

  ;; Loop: j × 30, snapshot every 5
  (let ((snapshots (list (state))))
    (dotimes (i 30)
      (xdotool "key" "--clearmodifiers" "j")
      (sleep 0.18)  ; R5 human pacing
      (when (zerop (mod (1+ i) 5))
        (let ((s (state)))
          (push s snapshots)
          (format t "  after ~2d × j: state = ~s~%" (1+ i) s))))
    (setf snapshots (reverse snapshots))

    ;; Each snapshot should differ from previous (j must move state)
    (let ((all-distinct t))
      (loop for (a b) on snapshots while b
            do (when (equal a b)
                 (setf all-distinct nil)))
      (check "A.1 every 5-step snapshot differs from previous (j actually moves)"
             all-distinct
             (format nil "snapshots: ~s" snapshots)))

    ;; Final state must differ from initial
    (check "A.2 final state differs from initial after 30 j"
           (not (equal (first snapshots) (car (last snapshots))))
           (format nil "init=~s  final=~s"
                   (first snapshots) (car (last snapshots))))

    ;; Send gg → should return to top (or near it)
    (xdotool "key" "--clearmodifiers" "g")
    (sleep 0.15)
    (xdotool "key" "--clearmodifiers" "g")
    (sleep 0.4)
    (let ((s-gg (state)))
      (check "A.3 gg returns to page 0 (or offset 0)"
             (let ((page (car s-gg)) (off (cdr s-gg)))
               (and (numberp page)
                    (or (zerop page)
                        (and (numberp off) (< off 0.05)))))
             (format nil "after gg: ~s" s-gg))))

  ;; Variant: same with 'l' (also bound to pdf-next-page).
  ;; NB: SPC is reserved as Doom-style leader key (limn/keys:*leader-key*),
  ;; so the original spec's "space×10 翻頁" 慣例不適用 — leader takes
  ;; precedence; use 'l' which is the explicit next-page binding.
  (format t "~%── 變奏: 用 l 取代 j ──~%")
  (safe-call "view/set" :|win-id| "w1" :|page| 0 :|offset-y| 0.0)
  (sleep 0.3)
  (let ((s0 (state)))
    (dotimes (i 10)
      (xdotool "key" "--clearmodifiers" "l")
      (sleep 0.18))
    (let ((s10 (state)))
      (check "B.1 l×10 also moves state"
             (not (equal s0 s10))
             (format nil "init=~s  after-10-l=~s" s0 s10))))

  (let ((log (with-open-file (s "/tmp/limn-w01.log" :if-does-not-exist nil)
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
  (format t "~%── W01 result: ~a / ~a pass ──~%" pass total)
  (when (> fail 0)
    (dolist (r rev) (unless (cdr r) (format t "  • ~a~%" (car r)))))
  (sb-ext:exit :code (if (zerop fail) 0 1)))
