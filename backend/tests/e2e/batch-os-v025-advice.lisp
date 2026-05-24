;;;; v0.25 §F — advice system OS-tier via Xvfb keypress dispatch
;;;;
;;;; Exercises the full advice pipeline end-to-end:
;;;;   1. Define a plain function (v025-test-fn) with an fdefinition.
;;;;   2. Wrap it in a defcommand and bind to key "F9".
;;;;   3. Add :before / :after / :around advice that each push a
;;;;      keyword onto *v025-log*.
;;;;   4. xdotool key F9 → Qt key event → bridge "key" event →
;;;;      background pump thread → Lisp dispatch → command → advised fn.
;;;;   5. Verify all advice keywords appear in *v025-log*.
;;;;   6. advice-remove all three → inject F9 again → only :cmd
;;;;      appears (bare fn still runs; no advice).
;;;;
;;;; Xvfb + xdotool required.
;;;;
;;;; Ω1  :before advice fires (after F9 keypress)
;;;; Ω2  :after advice fires
;;;; Ω3  :cmd (bare fn body) fires
;;;; Ω4  :around advice fires
;;;; Ω5  after advice-remove, only :cmd fires on subsequent keypress

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v025adv"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-advice.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun xdotool (&rest args)
  (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool"
                                             '("search" "--name" "Limn")
                                             :search t :wait t
                                             :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
          do (return found)
        do (sleep 0.1)))

(format t "~%=== batch-os-v025-advice ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v025adv-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v025adv.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  ;;; ── define fn + command + key binding ────────────────────────────────
  ;;
  ;; v025-test-fn has a real fdefinition so advice-add can instrument it.
  ;; The defcommand wraps it; limn:bind connects it to key "F9".
  (defparameter *v025-log* nil)

  (defun v025-test-fn ()
    (push :cmd *v025-log*))

  (limn/cmd:defcommand v025-advice-cmd (:interactive nil)
    (lambda () (v025-test-fn)))

  (limn:bind "F9" 'v025-advice-cmd)

  ;;; ── install three advice types (keep refs for removal) ──────────────
  (defparameter *adv-before* (lambda ()       (push :before *v025-log*)))
  (defparameter *adv-after*  (lambda ()       (push :after  *v025-log*)))
  (defparameter *adv-around* (lambda (orig)   (funcall orig) (push :around *v025-log*)))

  (limn/advice:advice-add 'v025-test-fn :before *adv-before*)
  (limn/advice:advice-add 'v025-test-fn :after  *adv-after*)
  (limn/advice:advice-add 'v025-test-fn :around *adv-around*)

  ;;; ── Ω1-Ω4: inject F9 and verify all advice fire ───────────────────────
  (format t "~%── Ω1-Ω4: F9 keypress → advice pipeline ──~%")
  (xdotool "key" "F9")
  (sleep 0.4)    ; allow background pump to process the key event

  (check (format nil "Ω1 :before advice fired (log=~s)" *v025-log*)
         (member :before *v025-log*))
  (check (format nil "Ω2 :after advice fired (log=~s)" *v025-log*)
         (member :after *v025-log*))
  (check (format nil "Ω3 :cmd (fn body) ran (log=~s)" *v025-log*)
         (member :cmd *v025-log*))
  (check (format nil "Ω4 :around advice fired (log=~s)" *v025-log*)
         (member :around *v025-log*))

  ;;; ── Ω5: advice-remove all → only :cmd fires next time ─────────────────
  (format t "~%── Ω5: advice-remove → no advice on next F9 ──~%")
  (limn/advice:advice-remove 'v025-test-fn *adv-before*)
  (limn/advice:advice-remove 'v025-test-fn *adv-after*)
  (limn/advice:advice-remove 'v025-test-fn *adv-around*)

  (let ((len-before (length *v025-log*)))
    (xdotool "key" "F9")
    (sleep 0.4)
    (let ((delta (- (length *v025-log*) len-before)))
      ;; bare fn still runs → exactly one :cmd pushed, no :before/:after/:around
      (check (format nil "Ω5a log grew by exactly 1 (delta=~a, log=~s)" delta *v025-log*)
             (= delta 1))
      (check (format nil "Ω5b the new entry is :cmd (log head=~s)" (car *v025-log*))
             (eq (car *v025-log*) :cmd))))

  (ignore-errors (limn:stop))
  (sleep 0.1)
  (handler-case (sb-ext:process-kill proc 15) (error () nil))
  (handler-case (sb-ext:process-wait proc) (error () nil)))

(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failure(s))~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
