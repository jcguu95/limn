;;;; Unit tests for limn/introspect — SPEC §9.4.
;;;;
;;;; Four query functions making Limn "ask-able":
;;;;   describe-key       what action is on this spec?
;;;;   describe-command   what is this command (spec, mode, body)?
;;;;   where-is-command   which keys invoke this command?
;;;;   list-modes         modes active on buffer, or all defined
;;;;
;;;; where-is is interesting: the keymap stores opaque actions
;;;; (closures), so we can't ask a binding "which command are you?".
;;;; The convention: limn:bind accepts a command-name SYMBOL, in which
;;;; case it (a) wraps it in a call-interactively closure and (b)
;;;; registers the binding in a reverse table. where-is reads that table.
;;;; Direct lambda bindings remain invisible to where-is — same as Emacs.

(in-package #:limn/unit-test)

;;; ── describe-command ───────────────────────────────────────────────────

(deftest describe-command-returns-spec-and-mode
  (limn/cmd:clear-commands)
  (limn/cmd:defcommand my-cmd-1 (:interactive "sQuery: " :mode pdf-mode)
    (lambda (q) q))
  (let ((d (limn/introspect:describe-command 'my-cmd-1)))
    (assert-true d "describe-command returns non-nil for known command")
    (assert-equal 'my-cmd-1 (getf d :name))
    (assert-equal "sQuery: " (getf d :spec))
    (assert-equal 'pdf-mode  (getf d :mode))
    (assert-true (functionp  (getf d :body)) "body is a function")))

(deftest describe-command-unknown-returns-nil
  (limn/cmd:clear-commands)
  (assert-equal nil (limn/introspect:describe-command 'no-such-cmd-9999)))

;;; ── where-is-command ───────────────────────────────────────────────────

(deftest where-is-finds-symbol-bound-command
  "limn/introspect:register-binding records (keymap spec) per command.
   where-is reads that table back."
  (limn/cmd:clear-commands)
  (limn/introspect:clear-binding-registry)
  (limn/cmd:defcommand toy-jump ()
    (lambda () :jumped))
  (let ((km (limn/keys:make-keymap)))
    (limn/introspect:register-binding 'toy-jump km "j")
    (let ((found (limn/introspect:where-is-command 'toy-jump)))
      (assert-true (find "j" found :test #'string=)
                   "\"j\" appears in where-is-command output"))))

(deftest where-is-empty-for-unbound
  (limn/introspect:clear-binding-registry)
  (assert-equal '() (limn/introspect:where-is-command 'no-bindings-here)))

(deftest where-is-collects-multiple-bindings
  (limn/cmd:clear-commands)
  (limn/introspect:clear-binding-registry)
  (limn/cmd:defcommand multibound () (lambda () nil))
  (let ((km (limn/keys:make-keymap)))
    (limn/introspect:register-binding 'multibound km "j")
    (limn/introspect:register-binding 'multibound km "n")
    (let ((found (limn/introspect:where-is-command 'multibound)))
      (assert-equal 2 (length found))
      (assert-true (find "j" found :test #'string=))
      (assert-true (find "n" found :test #'string=)))))

;;; ── describe-key ───────────────────────────────────────────────────────

(deftest describe-key-finds-global-binding
  "Given a global keymap with j → :go-down, describe-key returns a
   plist mentioning the action and the layer (:global)."
  (let ((km (limn/keys:make-keymap)))
    (limn/keys:define-key km "j" :go-down)
    (let ((d (limn/introspect:describe-key "j" :global-keymap km)))
      (assert-true d "describe-key returns something")
      (assert-equal :go-down (getf d :action))
      (assert-equal :global  (getf d :layer)))))

(deftest describe-key-finds-mode-binding
  "When a mode-buffer has a major mode whose keymap binds j, describe-key
   should locate it via the mode stack — not via global."
  (limn/mode:clear-modes)
  (let* ((global (limn/keys:make-keymap))
         (mkm    (limn/keys:make-keymap)))
    (limn/keys:define-key global "j" :global-fallback)
    (limn/keys:define-key mkm    "j" :mode-action)
    (limn/mode:define-mode 'mymode :type :major)
    (setf (limn/mode:mode-keymap (limn/mode:find-mode 'mymode)) mkm)
    (let ((buf (limn/mode:make-mode-buffer)))
      (limn/mode:activate buf 'mymode)
      (let ((d (limn/introspect:describe-key "j"
                                              :mode-buffer buf
                                              :global-keymap global)))
        (assert-equal :mode-action (getf d :action) "mode wins over global")
        (assert-equal 'mymode      (getf d :mode)
                      "describe-key reports which mode supplied the binding")))))

(deftest describe-key-unbound-returns-nil-action
  (let ((km (limn/keys:make-keymap)))
    (let ((d (limn/introspect:describe-key "z" :global-keymap km)))
      (assert-true d "describe-key still returns a plist for unbound keys")
      (assert-equal nil (getf d :action))
      (assert-equal :unbound (getf d :layer)))))

;;; ── list-modes ─────────────────────────────────────────────────────────

(deftest list-modes-of-buffer
  (limn/mode:clear-modes)
  (limn/mode:define-mode 'major1   :type :major)
  (limn/mode:define-mode 'minor-a  :type :minor)
  (limn/mode:define-mode 'minor-b  :type :minor)
  (let ((buf (limn/mode:make-mode-buffer)))
    (limn/mode:activate buf 'major1)
    (limn/mode:activate buf 'minor-a)
    (limn/mode:activate buf 'minor-b)
    (let ((ml (limn/introspect:list-modes :buffer buf)))
      (assert-equal 'major1 (getf ml :major))
      (assert-equal '(minor-b minor-a) (getf ml :minors)
                    "minors newest-first per limn/mode contract"))))

(deftest list-modes-all-defined
  "Without :buffer, return all defined modes (names only)."
  (limn/mode:clear-modes)
  (limn/mode:define-mode 'ma :type :major)
  (limn/mode:define-mode 'mb :type :minor)
  (let ((all (limn/introspect:list-modes)))
    (assert-true (find 'ma all) "major shows up")
    (assert-true (find 'mb all) "minor shows up")))
