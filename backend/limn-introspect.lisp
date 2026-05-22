;;;; limn-introspect — SPEC §9.4 introspection.
;;;;
;;;; Four queries that make Limn ask-able from the inside:
;;;;
;;;;   (describe-key spec &key mode-buffer global-keymap)
;;;;     → plist (:spec :action :layer [:mode])
;;;;
;;;;   (describe-command name)
;;;;     → plist (:name :spec :mode :body) or NIL
;;;;
;;;;   (where-is-command name)
;;;;     → list of key spec strings
;;;;
;;;;   (list-modes &key buffer)
;;;;     → (:major X :minors (...)) when :buffer given,
;;;;       or list of all defined mode-name symbols otherwise
;;;;
;;;; where-is is fundamentally about reverse lookup: given a command
;;;; symbol, which keys invoke it? The keymap stores opaque actions
;;;; (closures), so we can't introspect them. Convention: when a
;;;; binding is set via limn:bind with a command-name symbol, we wrap
;;;; it AND record the binding in a reverse table. Direct lambda
;;;; bindings stay invisible to where-is — same limit Emacs has.

(defpackage #:limn/introspect
  (:use #:cl)
  (:export #:describe-key #:describe-command #:where-is-command #:list-modes
           #:register-binding #:clear-binding-registry))

(in-package #:limn/introspect)

;;; ── reverse table: command → list of (keymap . spec) ──────────────────

(defvar *bindings-by-command* (make-hash-table :test 'eq)
  "command-name (symbol) → list of (KEYMAP . SPEC) cons cells.
   limn:bind populates this when binding a symbol. where-is reads it.")

(defun register-binding (command-name keymap spec)
  "Record that COMMAND-NAME is reachable via SPEC on KEYMAP.
   Multiple bindings per command are kept (no dedup yet — same key
   re-bound just appends; harmless for v0.8)."
  (push (cons keymap spec)
        (gethash command-name *bindings-by-command*))
  command-name)

(defun clear-binding-registry ()
  "Test helper: wipe the reverse table."
  (clrhash *bindings-by-command*))

;;; ── describe-command ───────────────────────────────────────────────────

(defun describe-command (name)
  "Return a plist describing the named command, or NIL if no such command."
  (let ((c (limn/cmd:find-command name)))
    (when c
      (list :name (limn/cmd:command-name c)
            :spec (limn/cmd:command-spec c)
            :mode (limn/cmd:command-mode c)
            :body (limn/cmd:command-body c)))))

;;; ── where-is-command ──────────────────────────────────────────────────

(defun where-is-command (name)
  "Return a list of key spec strings bound to NAME.
   Empty list if nothing bound (or all bindings are lambdas — see
   module docstring)."
  (mapcar #'cdr (gethash name *bindings-by-command*)))

;;; ── describe-key ──────────────────────────────────────────────────────

(defun %scan-mode-stack (mode-buffer spec)
  "Walk minors → major. Return (values action mode-symbol) on hit,
   (values NIL NIL) on miss."
  (unless mode-buffer (return-from %scan-mode-stack (values nil nil)))
  (dolist (minor-name (limn/mode:minor-modes mode-buffer))
    (let* ((m  (limn/mode:find-mode minor-name))
           (km (and m (limn/mode:mode-keymap m)))
           (a  (and km (limn/keys:lookup km spec))))
      (when a (return-from %scan-mode-stack (values a minor-name)))))
  (let* ((major-name (limn/mode:major-mode mode-buffer))
         (m  (and major-name (limn/mode:find-mode major-name)))
         (km (and m (limn/mode:mode-keymap m)))
         (a  (and km (limn/keys:lookup km spec))))
    (if a
        (values a major-name)
        (values nil nil))))

(defun describe-key (spec &key mode-buffer global-keymap)
  "Locate SPEC on the mode stack (if MODE-BUFFER given) then on
   GLOBAL-KEYMAP. Always returns a plist; :layer is one of
   :minor / :major / :global / :unbound."
  (multiple-value-bind (mode-action mode-name)
      (%scan-mode-stack mode-buffer spec)
    (cond
      (mode-action
       (let ((layer (let ((m (and mode-name (limn/mode:find-mode mode-name))))
                      (cond ((null m) :unknown)
                            ((eq (limn/mode:mode-type m) :minor) :minor)
                            (t :major)))))
         (list :spec spec :action mode-action :layer layer :mode mode-name)))
      ((and global-keymap (limn/keys:lookup global-keymap spec))
       (list :spec spec
             :action (limn/keys:lookup global-keymap spec)
             :layer :global))
      (t
       (list :spec spec :action nil :layer :unbound)))))

;;; ── list-modes ────────────────────────────────────────────────────────

(defun list-modes (&key buffer)
  "Without BUFFER: list every defined mode-name symbol.
   With BUFFER: return (:major X :minors (...)) reflecting that buffer's
   current state."
  (if buffer
      (list :major  (limn/mode:major-mode  buffer)
            :minors (limn/mode:minor-modes buffer))
      (mapcar #'limn/mode:mode-name (limn/mode:list-modes))))
