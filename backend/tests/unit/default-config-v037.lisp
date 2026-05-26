;;;; v0.37 Phase B — default-config + init.lisp + hot-reload coverage
;;;;
;;;; Verifies:
;;;;   1. execute-command + reload-init-file defcommands exist
;;;;   2. M-x + M-r are bound on the global keymap after install-defaults
;;;;   3. load-init-file accepts :resilient and swallows errors when set

(in-package #:limn/unit-test)

;;; Earlier tests in this suite call (limn/cmd:clear-commands) for
;;; isolation, which wipes any defcommands registered at file-load
;;; time.  Re-register before each assertion via the install function.
(defun %ensure-defaults-registered ()
  (let* ((pkg (find-package '#:limn/default-config))
         (fn (and pkg (find-symbol "INSTALL-DEFAULT-COMMANDS" pkg))))
    (when (and fn (fboundp fn))
      (funcall (symbol-function fn)))))

;;; ── defcommands present ─────────────────────────────────────────────────

(deftest default-config-execute-command-defined
  "limn/default-config provides execute-command in :cl-user registry."
  (%ensure-defaults-registered)
  (let* ((sym (find-symbol "EXECUTE-COMMAND" :cl-user))
         (cmd (and sym (limn/cmd:find-command sym))))
    (check (not (null sym))
           "EXECUTE-COMMAND symbol present in :cl-user" nil)
    (check (not (null cmd))
           "EXECUTE-COMMAND registered as defcommand" nil)))

(deftest default-config-reload-init-file-defined
  "limn/default-config provides reload-init-file in :cl-user registry."
  (%ensure-defaults-registered)
  (let* ((sym (find-symbol "RELOAD-INIT-FILE" :cl-user))
         (cmd (and sym (limn/cmd:find-command sym))))
    (check (not (null sym))
           "RELOAD-INIT-FILE symbol present in :cl-user" nil)
    (check (not (null cmd))
           "RELOAD-INIT-FILE registered as defcommand" nil)))

;;; ── install-defaults wires M-x / M-r onto a keymap ──────────────────────

(deftest default-config-install-binds-mx-mr
  "install-defaults binds M-x and M-r on the keymap it receives."
  (let* ((dc-pkg (find-package '#:limn/default-config))
         (install (and dc-pkg (find-symbol "INSTALL-DEFAULTS" dc-pkg)))
         (km (limn/keys:make-keymap)))
    (assert-true install "limn/default-config:install-defaults present")
    (when install
      (funcall (symbol-function install) km)
      (let ((mx (limn/keys:lookup-sequence km '("M-x")))
            (mr (limn/keys:lookup-sequence km '("M-r"))))
        (check (functionp mx) "M-x bound on keymap" nil)
        (check (functionp mr) "M-r bound on keymap" nil)))))

;;; ── load-init-file resilience ───────────────────────────────────────────

(deftest default-config-load-init-resilient-swallows-errors
  "load-init-file :resilient t logs+returns instead of unwinding on error.
   Strategy: temporarily point $LIMN_INIT at a file that signals an error
   on load, run with :resilient t, assert no error escapes."
  (let* ((rt-pkg (find-package '#:limn/runtime))
         (loader (and rt-pkg (find-symbol "LOAD-INIT-FILE" rt-pkg)))
         (tmp (format nil "/tmp/limn-bad-init-test-~a.lisp"
                      (sb-posix:getpid)))
         (orig-env (sb-posix:getenv "LIMN_INIT")))
    (assert-true loader "limn/runtime:load-init-file present")
    (when loader
      ;; Write a deliberately broken init file.
      (with-open-file (s tmp :direction :output :if-exists :supersede)
        (format s "(error \"deliberate test failure: init.lisp~%"))
      (sb-posix:setenv "LIMN_INIT" tmp 1)
      (unwind-protect
           (let ((result (handler-case
                             (funcall (symbol-function loader) :resilient t)
                           (error (e)
                             (format t "  ~%got error: ~a~%" e)
                             :ESCAPED))))
             (check (not (eq result :ESCAPED))
                    "load-init-file :resilient t did not unwind on broken init"
                    nil)
             (check (or (null result) (stringp result))
                    "returns nil or path (not a condition)" nil))
        (ignore-errors (delete-file tmp))
        (if orig-env
            (sb-posix:setenv "LIMN_INIT" orig-env 1)
            (sb-posix:unsetenv "LIMN_INIT"))))))
