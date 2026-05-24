;;;; Pure-Lisp unit test runner
;;;;
;;;; Runs all tests in backend/tests/unit/ without needing a running Limn.
;;;; Tests target the backend modules (limn-keys, limn-undo, etc.) — most
;;;; will fail until those modules are implemented. That's TDD by design.
;;;;
;;;; Usage:
;;;;   sbcl --script backend/tests/unit/run-unit.lisp

(in-package #:cl-user)

;; limn-runtime uses sb-posix:getenv for init-file lookup; load before
;; importing it. (The integration runner gets this via repl.lisp.)
(require :sb-posix)

(defparameter *unit-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil))

(defun rel (p)
  (namestring (merge-pathnames p *unit-dir*)))

;; Framework
(load (rel "unit-framework.lisp"))

;; v0.23 shared helpers (with-timeout-bound, fake-clock, mock-buffer)
(load (rel "v023-helpers.lisp"))

;; v0.24 shared helpers (cursor-aware mock-buf24, with-kill-buf, with-mark-buf)
(load (rel "v024-helpers.lisp"))

;; Backend implementation modules (loaded BEFORE tests so the unit-test
;; package-stubs are replaced by real packages).
(dolist (impl '("limn-hooks.lisp"
                "limn-log.lisp"
                "limn-error.lisp"
                "limn-timer.lisp"
                "limn-process.lisp"
                "limn-buffer.lisp"
                "limn-bridge.lisp"
                "limn-undo.lisp"
                "limn-buffer-undo.lisp"
                "limn-keys.lisp"
                "limn-search.lisp"
                "limn-client.lisp"
                "limn-dispatch.lisp"
                "limn-mode.lisp"
                "limn-cmd.lisp"
                "limn-runtime.lisp"
                "limn-introspect.lisp"
                "limn-text-mode.lisp"
                ;; v0.24 modules
                "limn-kill.lisp"
                "limn-mark.lisp"
                "limn-register.lisp"
                "limn-kmacro.lisp"
                "limn-file.lisp"
                "limn-auto-save.lisp"
                "limn-backup.lisp"
                "limn-recentf.lisp"
                ;; v0.25 modules
                "limn-history.lisp"
                "limn-custom.lisp"
                "limn-advice.lisp"
                "limn-face.lisp"
                "limn-text-props.lisp"
                "limn-help.lisp"
                "limn-completion.lisp"
                ;; v0.26 modules
                "limn-isearch.lisp"
                "limn-occur.lisp"
                ;; v0.27 — pdf-mode (depends on v0.25 + v0.26)
                "limn-pdf-mode.lisp"
                ;; v0.28 modules
                "limn-text-nav.lisp"
                "limn-map-macro.lisp"
                "limn-which-key.lisp"))
  (let ((p (namestring (merge-pathnames (concatenate 'string "../../" impl)
                                         *unit-dir*))))
    (format t "[loading impl] ~a~%" impl)
    (handler-case (load p)
      (error (e) (format t "  !! ~a: ~a~%" impl e)))))

;; All unit-test files
(dolist (file '("bridge-client.lisp"
                "keymap.lisp"
                "keymap-v019.lisp"
                "text-mode-v022.lisp"
                "undo.lisp"
                "hooks.lisp"
                "buffer-registry.lisp"
                "search.lisp"
                "dispatch.lisp"
                "mode.lisp"
                "defcommand.lisp"
                "runtime.lisp"
                "minibuffer-read.lisp"
                "keyboard-quit.lisp"
                "init-load.lisp"
                "introspect.lisp"
                ;; v0.23 RED tests — expected to fail until impl lands
                "process-v023.lisp"
                "timer-v023.lisp"
                "condition-v023.lisp"
                "buffer-undo-v023.lisp"
                "logging-v023.lisp"
                ;; v0.24 RED tests — expected to fail until impl lands
                "kill-ring-v024.lisp"
                "mark-ring-v024.lisp"
                "registers-v024.lisp"
                "kmacro-v024.lisp"
                "file-io-v024.lisp"
                "auto-save-v024.lisp"
                "backup-v024.lisp"
                "recentf-v024.lisp"
                ;; v0.25 tests (GREEN)
                "defface-v025.lisp"
                "text-props-v025.lisp"
                "history-v025.lisp"
                "help-v025.lisp"
                "advice-v025.lisp"
                "defcustom-v025.lisp"
                "completion-v025.lisp"
                ;; v0.26 RED tests — expected to fail until impl lands
                "isearch-v026.lisp"
                "occur-v026.lisp"
                ;; v0.27 RED tests — expected to fail until limn-pdf-mode lands
                "pdf-mode-v027.lisp"
                ;; v0.28 RED tests — expected to fail until impl lands
                "text-nav-v028.lisp"
                "map-macro-v028.lisp"
                "which-key-v028.lisp"
                ;; v0.29 wiring tests
                "runtime-wireup-v028.lisp"))
  (format t "[loading unit] ~a~%" file)
  (handler-case (load (rel file))
    (error (e) (format t "  !! ~a: ~a~%" file e))))

(in-package #:limn/unit-test)

(let ((ok (run-suite)))
  (sb-ext:exit :code (if ok 0 1)))
