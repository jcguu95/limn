;;;; v0.40 §2.1 — narrow-to-region / widen interactive command tests.
;;;;
;;;; Verifies that:
;;;;   - cl-user::narrow-to-region and cl-user::widen are registered as
;;;;     defcommands (M-x discoverable).
;;;;   - install-defaults binds C-x n n / C-x n w on the global keymap.

(in-package #:limn/unit-test)

(defun %ensure-narrow-defaults-registered ()
  (let* ((pkg (find-package '#:limn/default-config))
         (fn (and pkg (find-symbol "INSTALL-DEFAULT-COMMANDS" pkg))))
    (when (and fn (fboundp fn))
      (funcall (symbol-function fn)))))

;;; ── defcommands present ─────────────────────────────────────────────

(deftest narrow-cmd-narrow-to-region-defined
  "cl-user::narrow-to-region is registered as a defcommand."
  (%ensure-narrow-defaults-registered)
  (let* ((sym (find-symbol "NARROW-TO-REGION" :cl-user))
         (cmd (and sym (limn/cmd:find-command sym))))
    (check (not (null sym))
           "NARROW-TO-REGION symbol present in :cl-user" nil)
    (check (not (null cmd))
           "NARROW-TO-REGION registered as defcommand" nil)))

(deftest narrow-cmd-widen-defined
  "cl-user::widen is registered as a defcommand."
  (%ensure-narrow-defaults-registered)
  (let* ((sym (find-symbol "WIDEN" :cl-user))
         (cmd (and sym (limn/cmd:find-command sym))))
    (check (not (null sym))
           "WIDEN symbol present in :cl-user" nil)
    (check (not (null cmd))
           "WIDEN registered as defcommand" nil)))

;;; ── install-defaults wires C-x n n / C-x n w on global keymap ──────

(deftest narrow-cmd-install-binds-c-x-n-prefix
  "install-defaults binds C-x n n and C-x n w on the keymap it receives."
  (let* ((dc-pkg (find-package '#:limn/default-config))
         (install (and dc-pkg (find-symbol "INSTALL-DEFAULTS" dc-pkg)))
         (km (limn/keys:make-keymap)))
    (assert-true install "limn/default-config:install-defaults present")
    (when install
      (funcall (symbol-function install) km)
      (let ((nn (limn/keys:lookup-sequence km '("C-x" "n" "n")))
            (nw (limn/keys:lookup-sequence km '("C-x" "n" "w"))))
        (check (functionp nn) "C-x n n bound on keymap" nil)
        (check (functionp nw) "C-x n w bound on keymap" nil)))))
