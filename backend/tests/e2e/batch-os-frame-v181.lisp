;;;; Batch 29: v0.18.1 — real second Qt MainWindow per frame.
;;;;
;;;; v0.18.0 shipped the frame REGISTRY (abstract). v0.18.1 ships the
;;;; visible part: frame/create instantiates a real OS-level Qt window;
;;;; frame/focus raises it; frame/close tears it down. Verified via
;;;; xdotool counting "Limn" windows on the Xvfb display.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defun xdotool-stdout (&rest args)
  (with-output-to-string (s)
    (let ((p (sb-ext:run-program "xdotool" args :search t
                                  :wait t :output s :error t)))
      (unless (zerop (sb-ext:process-exit-code p))
        (error "xdotool ~{~a~^ ~} exited non-zero" args)))))

(defun count-limn-windows ()
  "Return how many X11 windows have a name matching 'Limn'."
  (let* ((out (handler-case (xdotool-stdout "search" "--name" "Limn")
                (error () "")))
         (lines (remove-if (lambda (s) (zerop (length s)))
                           (split-sequence-on-newline out))))
    (length lines)))

(defun split-sequence-on-newline (s)
  (loop with start = 0
        for i from 0 below (length s)
        when (char= (char s i) #\Newline)
          collect (subseq s start i)
          and do (setf start (1+ i))
        finally (when (< start (length s))
                  (return (append (loop with start2 = 0
                                        for j from 0 below (length s)
                                        when (char= (char s j) #\Newline)
                                          collect (subseq s start2 j)
                                          and do (setf start2 (1+ j)))
                                  (list (subseq s start)))))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-f181"))

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

(defun ok? (r) (eq (getf r :|ok|) t))

(let* ((sock (format nil "/tmp/limn-e2e-f181-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-f181.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.5)

;;; ── baseline measurement ──────────────────────────────────────────
;;;
;;; Qt's xcb backend creates 2-3 child X11 windows per MainWidget
;;; (top-level + opengl viewport + chrome bar), all named "Limn".
;;; xdotool search by name counts ALL of them. We therefore measure
;;; the *delta* in window count, not an absolute, so this driver is
;;; robust to Qt version changes that add/remove decoration widgets.

  (defparameter *baseline-windows* (count-limn-windows))
  (format t "~%baseline: ~a Limn-named X windows~%" *baseline-windows*)

;;; ── Ω1: frame/create instantiates a second OS window ────────────

  (format t "~%── Ω1: frame/create → window count grows ──~%")
  (let* ((r (limn:call "frame/create"))
         (fid (getf (getf r :|data|) :|frame-id|)))
    (check "Ω1a — frame/create ok" (ok? r))
    (sleep 0.8)   ; let Qt show + WM map the window
    (let ((delta (- (count-limn-windows) *baseline-windows*)))
      (check (format nil "Ω1b — Limn windows grew by ≥1 (delta=~a)" delta)
             (>= delta 1)))

;;; ── Ω2: frame/focus on f2 + back to f1 — no window count change ─

    (format t "~%── Ω2: frame/focus is a no-op on window count ──~%")
    (limn:call "frame/focus" :|frame-id| fid) (sleep 0.3)
    (let ((d1 (- (count-limn-windows) *baseline-windows*)))
      (check (format nil "Ω2a — focus f2 ok (delta=~a, still ≥1)" d1)
             (>= d1 1)))
    (limn:call "frame/focus" :|frame-id| "f1") (sleep 0.3)
    (let ((d2 (- (count-limn-windows) *baseline-windows*)))
      (check (format nil "Ω2b — focus back to f1 ok (delta=~a, still ≥1)" d2)
             (>= d2 1)))

;;; ── Ω3: frame/close tears down the OS window ────────────────────

    (format t "~%── Ω3: frame/close → window count back to baseline ──~%")
    (limn:call "frame/close" :|frame-id| fid)
    (sleep 0.8)
    (let ((delta (- (count-limn-windows) *baseline-windows*)))
      (check (format nil "Ω3 — delta back to 0 (got ~a)" delta)
             (= delta 0))))

;;; ── Ω4: many create/close cycles don't leak ─────────────────────

  (format t "~%── Ω4: 3 create/close cycles — no leaked windows ──~%")
  (dotimes (_ 3)
    (let* ((r (limn:call "frame/create"))
           (fid (getf (getf r :|data|) :|frame-id|)))
      (sleep 0.3)
      (limn:call "frame/close" :|frame-id| fid)
      (sleep 0.3)))
  (let ((delta (- (count-limn-windows) *baseline-windows*)))
    (check (format nil "Ω4 — delta back to 0 after 3 cycles (got ~a)" delta)
           (= delta 0)))

  ;; ── summary ─────────────────────────────────────────────────
  (format t "~%~%── frame-v181 e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
