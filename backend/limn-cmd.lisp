;;;; limn-cmd — defcommand + interactive spec (SPEC §9.2).
;;;;
;;;; A "command" is a named function decorated with an interactive spec
;;;; describing what input it needs:
;;;;
;;;;   (defcommand my-search (:interactive "sSearch: " :mode pdf-mode)
;;;;     (lambda (query) ...))
;;;;
;;;; The framework's job is to AUTO-fill those args (from minibuffer,
;;;; prefix arg, region, etc) when the command is invoked interactively,
;;;; so command bodies never poke the minibuffer themselves.
;;;;
;;;; Interactive spec characters (Emacs conventions, subset for v0.7):
;;;;   s  — string from minibuffer (rest of spec after 's' = prompt)
;;;;   p  — numeric prefix arg (defaults to 1 if no prefix supplied)
;;;;   f  — file path (future: completion)
;;;;   r  — region (future)
;;;;
;;;; nil  spec = command takes no args.
;;;;
;;;; The actual minibuffer round-trip is abstracted behind
;;;; *minibuffer-read*: tests rebind it to inject canned input without
;;;; needing a live frontend. The real bridge wiring (call minibuffer/open,
;;;; await minibuffer-submit event, return text) lives in the runtime
;;;; consumer of this module, not here.

(defpackage #:limn/cmd
  (:use #:cl)
  (:export #:defcommand #:find-command #:list-commands #:clear-commands
           #:call-interactively
           #:command-name #:command-spec #:command-mode #:command-body
           #:*minibuffer-read* #:*prefix-arg*
           #:*last-command* #:*this-command*))

(in-package #:limn/cmd)

;;; ── command object ─────────────────────────────────────────────────────

(defstruct (command (:conc-name command-))
  name
  spec   ; the :interactive value — string or nil
  mode   ; mode symbol or nil (no restriction)
  body)  ; a function

(defvar *commands* (make-hash-table :test 'eq))

(defun find-command  (name)  (gethash name *commands*))
(defun list-commands ()
  (loop for c being the hash-values of *commands* collect c))
(defun clear-commands ()
  (clrhash *commands*))

(defun register-command (name spec mode body)
  (let ((c (make-command :name name :spec spec :mode mode :body body)))
    (setf (gethash name *commands*) c)
    c))

(defmacro defcommand (name (&key interactive mode) &body body)
  "Register a command named NAME.
   BODY should be a single (lambda ...) form whose lambda-list matches
   what the interactive spec produces.

   E.g.
     :interactive nil          → body is (lambda () ...)
     :interactive \"sQuery: \" → body is (lambda (q) ...)
     :interactive \"p\"        → body is (lambda (prefix) ...)"
  `(register-command ',name ,interactive ',mode (progn ,@body)))

;;; ── runtime context ───────────────────────────────────────────────────
;;;
;;; These are special variables the dispatcher rebinds when running a
;;; command interactively. Tests rebind them to inject canned input
;;; without needing a live minibuffer.

(defvar *minibuffer-read* (lambda (prompt)
                            (declare (ignore prompt))
                            (error "limn/cmd: no minibuffer-read handler installed"))
  "Function (prompt → string) used by the 's' spec to obtain user input.
   The runtime installs a version that drives bridge minibuffer/open +
   awaits minibuffer-submit. Tests rebind this to a thunk that returns
   canned text.")

(defvar *prefix-arg* 1
  "The numeric prefix argument for the current call. 'p' spec reads it.")

(defvar *last-command* nil
  "Symbol identifying the previously executed command. Dispatch loop
   copies *this-command* here after each command completes.")

(defvar *this-command* nil
  "Symbol identifying the currently executing command. Set by dispatch
   loop before calling the command body.")

;;; ── interactive spec parsing ──────────────────────────────────────────

(defun parse-spec (spec)
  "Return a list of (kind extra) pairs describing each arg the body wants.
   v0.7 supports a single arg encoded by leading char:
     'sSomething: '  → (:string \"Something: \")
     'p'             → (:prefix nil)
     nil             → ()

   Future: multi-arg specs are newline-separated, per Emacs convention."
  (cond
    ((null spec) '())
    ((zerop (length spec))
     (error "limn/cmd: empty interactive spec"))
    (t
     (let ((kind-char (char spec 0))
           (rest      (subseq spec 1)))
       (case kind-char
         (#\s (list (list :string rest)))
         (#\p (list (list :prefix nil)))
         (#\f (list (list :file   rest)))
         (#\r (list (list :region nil)))
         (otherwise
          (error "limn/cmd: unsupported interactive spec char ~s" kind-char)))))))

(defun gather-args (spec)
  "Use parse-spec + the runtime context to produce the actual arg list."
  (loop for (kind extra) in (parse-spec spec)
        collect (ecase kind
                  (:string (funcall *minibuffer-read* extra))
                  (:prefix *prefix-arg*)
                  (:file   (funcall *minibuffer-read* extra))   ; v0.7: same as :string
                  (:region (error "limn/cmd: 'r' (region) spec not yet implemented")))))

;;; ── invocation ────────────────────────────────────────────────────────

(defun call-interactively (name-or-cmd &optional prefix)
  "Invoke command NAME-OR-CMD, filling its args according to its
   interactive spec. NAME-OR-CMD may be a registered command name
   (symbol) or a command struct returned by FIND-COMMAND. PREFIX, if
   supplied, is bound as *PREFIX-ARG* for the duration of the call."
  (let ((c (cond ((command-p name-or-cmd) name-or-cmd)
                 (t (find-command name-or-cmd)))))
    (unless c
      (error "limn/cmd: unknown command ~s" name-or-cmd))
    (let ((*prefix-arg* (or prefix *prefix-arg*)))
      (apply (command-body c) (gather-args (command-spec c))))))
