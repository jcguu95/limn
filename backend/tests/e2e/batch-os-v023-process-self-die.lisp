;;;; OS-tier batch v0.23 §A1'': real wall-clock self-die timing
;;;;
;;;; Spawns subprocesses that sleep then exit, measures wall-clock
;;;; elapsed time, asserts it lands in the expected window. This is
;;;; the test the unit-tier can only approximate (because unit tests
;;;; should not depend on real time precision); doing it once at
;;;; OS-tier proves the abstraction layer doesn't add measurable
;;;; overhead and that the sentinel fires at the right moment.

(in-package :cl-user)
(require :sb-posix)

(defparameter *bdir*
  (or (handler-case (sb-posix:getenv "LIMN_BACKEND_DIR") (error () nil))
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))

(load (concatenate 'string *bdir* "limn-hooks.lisp"))
(load (concatenate 'string *bdir* "limn-log.lisp"))
(load (concatenate 'string *bdir* "limn-error.lisp"))
(load (concatenate 'string *bdir* "limn-process.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    → ~a~%" details))
  (unless ok (push msg *failures*)))

(defparameter *sh*
  (loop for p in '("/bin/sh" "/usr/bin/sh") when (probe-file p) return p))

(defun wall-elapsed (fn)
  (let ((t0 (get-internal-real-time)))
    (funcall fn)
    (/ (- (get-internal-real-time) t0)
       (coerce internal-time-units-per-second 'double-float))))

(format t "~%=== batch-os-v023-process-self-die ===~%")

;;; ── 1 second sleep then clean exit ───────────────────────────────────
(let ((dt nil) (final-status nil) (code nil))
  (setf dt
        (wall-elapsed
         (lambda ()
           (let ((p (limn/process:make-process
                     :command (list *sh* "-c" "sleep 1; exit 0"))))
             (limn/process:process-wait p :timeout 3)
             (setf final-status (limn/process:process-status p)
                   code         (limn/process:process-exit-code p))))))
  (format t "  measured 1s sleep: ~,3F s~%" dt)
  (check "1s sleep elapsed ∈ [0.8, 1.6]" (and (>= dt 0.8) (<= dt 1.6))
         (format nil "got ~,3F" dt))
  (check "1s sleep status :EXIT" (eq :exit final-status))
  (check "1s sleep exit-code 0" (eql 0 code)))

;;; ── 0.3s sleep + exit 7 (custom exit code propagation) ──────────────
(let ((dt nil) (final-status nil) (code nil))
  (setf dt
        (wall-elapsed
         (lambda ()
           (let ((p (limn/process:make-process
                     :command (list *sh* "-c" "sleep 0.3; exit 7"))))
             (limn/process:process-wait p :timeout 3)
             (setf final-status (limn/process:process-status p)
                   code         (limn/process:process-exit-code p))))))
  (format t "  measured 0.3s sleep: ~,3F s~%" dt)
  (check "0.3s sleep elapsed ∈ [0.2, 0.8]" (and (>= dt 0.2) (<= dt 0.8))
         (format nil "got ~,3F" dt))
  (check "0.3s sleep status :EXIT" (eq :exit final-status))
  (check "0.3s sleep exit-code 7" (eql 7 code)))

;;; ── Sentinel fires at exit moment ────────────────────────────────────
(let* ((sentinel-time nil)
       (t0 (get-internal-real-time))
       (p (limn/process:make-process
           :command (list *sh* "-c" "sleep 0.5; exit 0")
           :sentinel (lambda (proc)
                       (declare (ignore proc))
                       (setf sentinel-time
                             (/ (- (get-internal-real-time) t0)
                                (coerce internal-time-units-per-second 'double-float)))))))
  (limn/process:process-wait p :timeout 3)
  (sleep 0.1)  ; give sentinel a chance to be invoked
  (check "sentinel fired" sentinel-time)
  (when sentinel-time
    (format t "  sentinel fired at: ~,3F s~%" sentinel-time)
    (check "sentinel fired near 0.5s mark"
           (and (>= sentinel-time 0.4) (<= sentinel-time 1.5))
           (format nil "got ~,3F" sentinel-time))))

;;; ── kill mid-flight: status :SIGNAL ──────────────────────────────────
(let ((p (limn/process:make-process
          :command (list *sh* "-c" "sleep 5"))))
  (sleep 0.1)
  (limn/process:kill-process p :KILL)
  (limn/process:process-wait p :timeout 3)
  (check "killed proc status :SIGNAL"
         (eq :signal (limn/process:process-status p))
         (format nil "got ~S" (limn/process:process-status p))))

;;; ── Verdict ──────────────────────────────────────────────────────────
(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failures)~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
