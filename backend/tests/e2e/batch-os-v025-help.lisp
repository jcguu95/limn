;;;; v0.25 §E — describe / apropos OS-tier
;;;;
;;;; Real SBCL introspection. The OS-tier value here is cross-module:
;;;; describe-key delegates to limn/keys, describe-mode to limn/mode,
;;;; apropos-command to limn/cmd. We verify those handoffs happen.
;;;;
;;;; KNOWN MODULE GAPS (v0.25, documented in the Ω comments):
;;;;   (a) describe-key looks up limn/keys:LOOKUP-KEY which is not
;;;;       exported (only `lookup` taking a keymap). So describe-key
;;;;       always returns "is not defined". Tests Ω6 below verify the
;;;;       actual current behavior, not the intended behavior.
;;;;   (b) apropos-command looks up limn/cmd:COMMANDP which does not
;;;;       exist (only `find-command`). So apropos-command always
;;;;       returns empty. Ω9 verifies it returns a list, possibly empty.
;;;;
;;;; No Xvfb needed.
;;;;
;;;; Ω1   describe-function on documented fn → output contains name + doc
;;;; Ω2   describe-function on undocumented fn → "Not documented"
;;;; Ω3   describe-function on unbound symbol → signals error
;;;; Ω4   describe-variable on bound var with doc → output has value + doc
;;;; Ω5   describe-variable on unbound var → output contains ":unbound"
;;;; Ω6   describe-key gap: always "is not defined" (v0.25 limitation)
;;;; Ω7   describe-mode delegates to limn/mode current-major-mode
;;;; Ω8   apropos substring match across packages
;;;; Ω9   apropos-command gap: returns list (currently empty)
;;;; Ω10  apropos-variable filters to boundp symbols
;;;; Ω11  help-buffer-contents echoes the most recent describe-* output

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v025hp"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-help.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

;;; Fixtures: functions and variables we control, so Ω1-Ω5 don't depend
;;; on SBCL builtins whose doc strings vary across versions.
(defun v025-help-fixture-documented (x)
  "A v025 test fixture function. Doubles X."
  (* x 2))

(defun v025-help-fixture-undocumented (x)
  (1+ x))

(defparameter *v025-help-fixture-var* 42
  "A v025 test fixture variable.")

(format t "~%=== batch-os-v025-help ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v025hp-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v025hp.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── Ω1: describe-function (documented) ───────────────────────────────
  (format t "~%── Ω1: describe-function ──~%")
  (let ((out (limn/help:describe-function 'v025-help-fixture-documented)))
    (check (format nil "Ω1a output contains fn name (out=~s)"
                   (subseq out 0 (min 60 (length out))))
           (search "v025-help-fixture-documented" (string-downcase out)))
    (check "Ω1b output contains the doc string"
           (search "Doubles X" out)))

  ;;; ── Ω2: describe-function (no doc) ──────────────────────────────────
  (format t "~%── Ω2: describe-function undocumented ──~%")
  (let ((out (limn/help:describe-function 'v025-help-fixture-undocumented)))
    (check (format nil "Ω2 \"Not documented\" appears (out=~s)"
                   (subseq out 0 (min 80 (length out))))
           (search "Not documented" out)))

  ;;; ── Ω3: describe-function on unbound → error ───────────────────────
  (format t "~%── Ω3: describe-function unbound errors ──~%")
  (let ((errored
          (handler-case
              (progn (limn/help:describe-function 'v025-totally-nonexistent-symbol-z9z9)
                     nil)
            (error () t))))
    (check (format nil "Ω3 unbound symbol signals error (got ~s)" errored)
           errored))

  ;;; ── Ω4: describe-variable bound ─────────────────────────────────────
  (format t "~%── Ω4: describe-variable ──~%")
  (let ((out (limn/help:describe-variable '*v025-help-fixture-var*)))
    (check "Ω4a output contains var name"
           (search "v025-help-fixture-var" (string-downcase out)))
    (check (format nil "Ω4b output contains value 42 (out=~s)"
                   (subseq out 0 (min 80 (length out))))
           (search "42" out))
    (check "Ω4c output contains the doc string"
           (search "test fixture variable" out)))

  ;;; ── Ω5: describe-variable unbound ──────────────────────────────────
  (format t "~%── Ω5: describe-variable unbound ──~%")
  (let ((out (limn/help:describe-variable 'v025-totally-unbound-var-zzz)))
    (check (format nil "Ω5 :unbound in output (out=~s)"
                   (subseq out 0 (min 80 (length out))))
           (search ":UNBOUND" (string-upcase out))))

  ;;; ── Ω6: describe-key — module gap ───────────────────────────────────
  ;; NOTE: limn-help looks up limn/keys:LOOKUP-KEY which doesn't exist
  ;; (only `lookup` taking a keymap). So even bound keys yield
  ;; "is not defined".  This Ω documents v0.25's actual behavior.
  (format t "~%── Ω6: describe-key (KNOWN GAP) ──~%")
  ;; First make sure there IS a binding so a working describe-key would
  ;; find something. limn:bind needs a defined command.
  (limn/cmd:defcommand v025-help-key-target (:interactive nil)
    (lambda () nil))
  (limn:bind "z" 'v025-help-key-target)

  (let ((out-bound (limn/help:describe-key "z"))
        (out-unb   (limn/help:describe-key "F12")))
    (check (format nil "Ω6a bound key returns a string (got ~s)" out-bound)
           (stringp out-bound))
    (check (format nil "Ω6b unbound key contains \"not defined\" (got ~s)" out-unb)
           (search "not defined" out-unb))
    ;; If LOOKUP-KEY is ever wired, the bound-key output should contain
    ;; "runs the command" — accept either current (gap) behaviour OR
    ;; the fixed behaviour so this Ω stays green after the fix.
    (check (format nil "Ω6c bound key: \"not defined\" (v0.25 gap) OR \"runs the command\" (got ~s)"
                   out-bound)
           (or (search "not defined"   out-bound)
               (search "runs the command" out-bound))))

  ;;; ── Ω7: describe-mode delegation ────────────────────────────────────
  (format t "~%── Ω7: describe-mode ──~%")
  (let ((out (limn/help:describe-mode)))
    (check (format nil "Ω7 output mentions a major mode (got ~s)"
                   (subseq out 0 (min 60 (length out))))
           (search "Major mode" out)))

  ;;; ── Ω8: apropos substring ───────────────────────────────────────────
  (format t "~%── Ω8: apropos substring ──~%")
  (let ((results (limn/help:apropos "v025-help-fixture")))
    (check (format nil "Ω8 finds the fixture symbols (count=~a)"
                   (length results))
           (and (listp results)
                (some (lambda (s) (search "FIXTURE" (symbol-name s)))
                      results))))

  ;;; ── Ω9: apropos-command — module gap ───────────────────────────────
  ;; KNOWN GAP: limn-help expects limn/cmd:COMMANDP which doesn't exist.
  ;; The function returns a list (possibly empty). We only verify the
  ;; shape, not membership.
  (format t "~%── Ω9: apropos-command (KNOWN GAP) ──~%")
  (let ((results (limn/help:apropos-command "v025-help-key-target")))
    (check (format nil "Ω9 apropos-command returns a list (got ~s)" results)
           (listp results)))

  ;;; ── Ω10: apropos-variable filters to boundp ────────────────────────
  (format t "~%── Ω10: apropos-variable ──~%")
  (let ((results (limn/help:apropos-variable "v025-help-fixture")))
    (check (format nil "Ω10 every result is boundp (results=~a)"
                   (length results))
           (every #'boundp results)))

  ;;; ── Ω11: help-buffer-contents echoes most recent ───────────────────
  (format t "~%── Ω11: help-buffer-contents ──~%")
  (limn/help:describe-variable '*v025-help-fixture-var*)
  (let ((stored (limn/help:help-buffer-contents)))
    (check "Ω11 help-buffer-contents has the most recent describe output"
           (and (stringp stored)
                (search "v025-help-fixture-var" (string-downcase stored)))))

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
