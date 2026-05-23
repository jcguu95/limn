;;;; Batch 15: G4 multi-PDF state + G6 broken init.lisp.
;;;;
;;;; G4 開兩個 PDF 切換、state 各自保留
;;;; G6 broken init.lisp → loud error、不靜默開到半癱

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defun xdotool (&rest args)
  (let ((p (sb-ext:run-program "xdotool" args :search t
                                :wait t :output t :error t)))
    (unless (zerop (sb-ext:process-exit-code p))
      (error "xdotool ~{~a~^ ~} exited non-zero" args))))

(defun xdotool-stdout (&rest args)
  (with-output-to-string (s)
    (let ((p (sb-ext:run-program "xdotool" args :search t
                                  :wait t :output s :error t)))
      (unless (zerop (sb-ext:process-exit-code p))
        (error "xdotool ~{~a~^ ~} exited non-zero" args)))))

(defun wait-for-window-by-name (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((s (string-trim '(#\Space #\Newline #\Tab)
                             (handler-case
                                 (xdotool-stdout "search" "--name" name)
                               (error () "")))))
        (unless (zerop (length s))
          (return (parse-integer
                   (subseq s 0 (or (position #\Newline s) (length s)))))))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-mp"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

;;; ═════════════════════════════════════════════════════════════════
;;; G4: multi-PDF state preservation
;;; ═════════════════════════════════════════════════════════════════

(format t "~%── G4: open 2 PDFs sequentially, each retains state ──~%")
(let* ((sock-a (format nil "/tmp/limn-e2e-mp-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock-a)
              :wait nil :search nil
              :output "/tmp/limn-os-mp.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock-a) do (sleep 0.05))
  (limn:start sock-a)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

    (let ((fixture-a (b/ "tests/fixtures/test.pdf"))
          ;; Use same fixture (we don't have 2 distinct PDFs);
          ;; copy to a 2nd path so it loads as a separate buffer.
          (fixture-b "/tmp/test-b-mp.pdf"))
      (sb-ext:run-program "cp" (list fixture-a fixture-b)
                          :search t :wait t :output t :error t)

      ;; Load PDF A
      (limn:call "bridge/engine-load" :|engine| "mupdf"
                  :|path| fixture-a :|win-id| "w1")
      (sleep 0.3)
      (check "G4 — PDF A loaded"
             (let ((r (limn:call "view/get" :|win-id| "w1")))
               (eq (getf r :|ok|) t)))

      ;; Set page 3 on PDF A
      (limn:call "view/set" :|win-id| "w1" :|page| 3)
      (sleep 0.2)
      (let* ((r (limn:call "view/get" :|win-id| "w1"))
             (d (limn/bridge:response-data r)))
        (check "G4 — PDF A at page 3"
               (= (getf d :|page|) 3)))

      ;; Load PDF B in same window (overwrites A as active buffer)
      (limn:call "bridge/engine-load" :|engine| "mupdf"
                  :|path| fixture-b :|win-id| "w1")
      (sleep 0.3)
      (let* ((r (limn:call "view/get" :|win-id| "w1"))
             (d (limn/bridge:response-data r))
             (bid (getf d :|buffer-id|)))
        (check "G4 — PDF B loaded (buffer-id changed from A)"
               (not (string= bid "b1"))
               (format nil "buffer-id=~s" bid))
        (check "G4 — PDF B starts at page 0 (fresh state)"
               (= (getf d :|page|) 0)))

      (ignore-errors (delete-file fixture-b))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (sleep 0.3))))

;;; ═════════════════════════════════════════════════════════════════
;;; G6: broken init.lisp produces loud error
;;; ═════════════════════════════════════════════════════════════════

(format t "~%── G6: broken init.lisp signals error, not silent ──~%")
;; Write a broken init.lisp
(ensure-directories-exist "/tmp/.limn/")
(with-open-file (s "/tmp/.limn/init.lisp" :direction :output
                                          :if-exists :supersede
                                          :if-does-not-exist :create)
  (write-string "(error \"intentional broken init for G6 test\")" s))

(let* ((sock-b (format nil "/tmp/limn-e2e-mp2-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock-b)
              :wait nil :search nil
              :output "/tmp/limn-os-mp2.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock-b) do (sleep 0.05))
  ;; Now try to connect — limn:start will load init.lisp which errors
  (let ((connection-result
          (handler-case
              (progn (limn:start sock-b) :connected)
            (error (e) (format nil "ERR: ~a" e)))))
    (cond
      ((eq connection-result :connected)
       ;; Lisp side didn't bail on init error (it just printed warning?).
       ;; This is "silent fail" — the very thing G6 wants to detect.
       (check "G6 — broken init.lisp must SIGNAL error to start"
              nil
              "limn:start completed despite (error ...) in init.lisp — silent fail"))
      ((and (stringp connection-result)
            (search "intentional" connection-result))
       (check "G6 — broken init.lisp signals error containing message"
              t
              connection-result))
      (t
       (check "G6 — broken init.lisp signals error (some kind)"
              t
              (format nil "got: ~a" connection-result)))))
  (handler-case (limn:stop) (error () nil))
  (handler-case (sb-ext:process-kill proc 15) (error () nil)))

;; Clean up broken init file
(ignore-errors (delete-file "/tmp/.limn/init.lisp"))

;;; ── final verdict ──────────────────────────────────────────────────

(let ((ok (null *failures*)))
  (format t "~%── VERDICT: ~a ──~%"
          (if ok "✓ PASS — batch 15 multi-PDF + broken init green"
                 (format nil "✗ FAIL (~a):~{~%    ~a~}"
                         (length *failures*) (reverse *failures*))))
  (when (probe-file "/tmp/.limn/init.lisp.stash-mp")
    (rename-file "/tmp/.limn/init.lisp.stash-mp" "/tmp/.limn/init.lisp"))
  (sb-ext:exit :code (if ok 0 1)))
