;;;; Unit tests for keyboard-quit (SPEC §9.2 / Emacs convention C-g).
;;;;
;;;; Design (per user, batch 8): C-g is NOT hardcoded into %dispatch-key.
;;;; Instead, keyboard-quit is a regular defcommand, and C-g is bound
;;;; into the global keymap by default — overridable like any other
;;;; binding via (limn:bind "C-g" ...).
;;;;
;;;; What keyboard-quit does:
;;;;   1. If a minibuffer-read is currently blocked (the runtime tracks
;;;;      this via *active-minibuffer-canceller*), abort it as if the
;;;;      user had pressed ESC.
;;;;   2. Always reset any partial multi-key prefix (otherwise C-g after
;;;;      C-x leaves the prefix accumulator stuck).

(in-package #:limn/unit-test)

;;; ── keyboard-quit registered as a command ──────────────────────────────

(deftest keyboard-quit-is-a-defcommand
  (limn/cmd:clear-commands)
  ;; Re-register defaults (limn-runtime ships a defcommand for it; we
  ;; trigger the registration by referencing the package symbol — the
  ;; real install runs on load).
  (limn/runtime:install-default-commands)
  (assert-true (limn/cmd:find-command 'limn/runtime:keyboard-quit)
               "keyboard-quit command exists in the registry"))

;;; ── canceller mechanism ────────────────────────────────────────────────

(deftest keyboard-quit-fires-active-canceller
  "When *active-minibuffer-canceller* is bound to a thunk, calling
   keyboard-quit must invoke it (this is how C-g aborts a pending
   minibuffer-read)."
  (limn/runtime:install-default-commands)
  (let ((aborted nil))
    (let ((limn/runtime:*active-minibuffer-canceller*
            (lambda () (setf aborted t))))
      (limn/cmd:call-interactively 'limn/runtime:keyboard-quit))
    (assert-true aborted "canceller thunk was invoked")))

(deftest keyboard-quit-noop-when-no-canceller
  "Outside a minibuffer-read, keyboard-quit is harmless — must not signal."
  (limn/runtime:install-default-commands)
  (let ((limn/runtime:*active-minibuffer-canceller* nil))
    (assert-no-error
      (limn/cmd:call-interactively 'limn/runtime:keyboard-quit))))

;;; ── default C-g binding ────────────────────────────────────────────────
;;;
;;; install-default-bindings installs a binding for C-g on the supplied
;;; keymap. Pure function, no session needed.

(deftest install-default-bindings-binds-cg
  (let ((km (limn/keys:make-keymap)))
    (limn/runtime:install-default-bindings km)
    (let ((action (limn/keys:lookup km "C-g")))
      (assert-true action "C-g is bound after install-default-bindings")
      (assert-true (functionp action) "binding is a function"))))

(deftest install-default-bindings-overridable
  "The default binding must be a regular binding — user can replace it
   with limn/keys:define-key (which is what limn:bind does)."
  (let ((km (limn/keys:make-keymap)))
    (limn/runtime:install-default-bindings km)
    (limn/keys:define-key km "C-g" :user-rebind)
    (assert-equal :user-rebind (limn/keys:lookup km "C-g")
                  "user-set binding wins")))

;;; ── end-to-end: keyboard-quit aborts a pending minibuffer-read ─────────
;;;
;;; Drive the same mock-session flow as batch 7, but instead of staging
;;; a real minibuffer-submit event, simulate C-g by invoking the
;;; keyboard-quit command from a hook fired before submit arrives.

(deftest cg-binding-aborts-minibuffer-read
  "When keyboard-quit is called via the C-g binding while a
   minibuffer-read is blocked, the read signals minibuffer-cancelled."
  (limn/cmd:clear-commands)
  (limn/hooks:clear-all-hooks)
  (limn/runtime:install-default-commands)
  (multiple-value-bind (sess m) (new-mock-session)
    ;; Stage: minibuffer/open response, then a 'tick' event (causes the
    ;; pump to fire a hook), then a close response.
    (stage-response m "r1")
    (mock-push-line m "{\"event\":\"tick\"}")
    (stage-response m "r2")
    ;; On 'tick', invoke keyboard-quit — this is what %dispatch-key
    ;; does when it sees C-g bound. We bypass the keymap walk and call
    ;; the command directly to keep the test focused on the cancel path.
    (limn/hooks:add-hook (limn/dispatch:event-hook-name "tick")
                         (lambda (_)
                           (declare (ignore _))
                           (limn/cmd:call-interactively
                            'limn/runtime:keyboard-quit)))
    (let ((reader (limn/runtime:make-minibuffer-reader sess)))
      (assert-error limn/runtime:minibuffer-cancelled
        (funcall reader "Search: ")))))
