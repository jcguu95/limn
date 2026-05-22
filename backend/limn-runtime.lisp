;;;; limn-runtime — wires wire-level buffer-ids to Lisp-side mode-buffers,
;;;; tracks per-window active buffer, and implements the mode keymap stack
;;;; walk (SPEC v0.5 §9.1).
;;;;
;;;; Pure-Lisp, no I/O. The wire glue in limn.lisp:
;;;;   - on start: calls init-chrome-buffers
;;;;   - in %dispatch-key: calls mode-buffer-for-window + dispatch-key-via-stack
;;;;   - on event/buffer-opened: register-mode-buffer with engine-default-mode
;;;;   - on event/buffer-closed: unregister-mode-buffer
;;;;
;;;; Separation of concerns:
;;;;   - limn/mode owns the mode object + per-mode-buffer state (major,
;;;;     minors, hooks)
;;;;   - limn/runtime owns the wire↔mode bridge (buffer-id strings → mode-buffer,
;;;;     win-id strings → buffer-id) and the dispatch walker that adds the
;;;;     global-keymap fallback layer
;;;;
;;;; All registries are simple equal hash tables keyed by string. Single
;;;; threaded — the pump thread is the only mutator at runtime.

(defpackage #:limn/runtime
  (:use #:cl)
  (:export #:reset-all
           #:register-mode-buffer #:find-mode-buffer #:unregister-mode-buffer
           #:set-window-active-buffer #:window-active-buffer
           #:register-engine-default-mode #:engine-default-mode
           #:mode-buffer-for-window
           #:dispatch-key-via-stack
           #:init-chrome-buffers
           ;; Chrome default mode names. Exported so the wire layer, user
           ;; init.lisp, and tests refer to the SAME interned symbol —
           ;; limn/mode keys modes by `eq` on symbol, so the package the
           ;; symbol lives in matters. Anyone customising chrome modes
           ;; should call define-mode on these exact symbols.
           #:minibuffer-mode #:fundamental-mode
           ;; Minibuffer round-trip: builds the limn/cmd:*minibuffer-read*
           ;; thunk that the framework installs at session start.
           #:make-minibuffer-reader #:minibuffer-cancelled
           ;; C-g / keyboard-quit. keyboard-quit is a defcommand bound
           ;; into the global keymap by install-default-bindings — it's
           ;; deliberately a regular binding (NOT hardcoded in
           ;; %dispatch-key) so users can rebind. *active-minibuffer-
           ;; canceller* is bound dynamically by make-minibuffer-reader
           ;; while it blocks, so keyboard-quit can abort the wait.
           #:keyboard-quit #:*active-minibuffer-canceller*
           #:install-default-commands #:install-default-bindings))

(in-package #:limn/runtime)

;;; ── registries ─────────────────────────────────────────────────────────

(defvar *mode-buffers* (make-hash-table :test 'equal)
  "wire buffer-id (string) → limn/mode mode-buffer.")

(defvar *window-active-buffer* (make-hash-table :test 'equal)
  "win-id (string) → currently-focused buffer-id (string).")

(defvar *engine-default-modes* (make-hash-table :test 'equal)
  "engine name (string) → default major mode symbol for buffers loaded by
   that engine. e.g. \"mupdf\" → 'pdf-mode.")

(defun reset-all ()
  "Test helper: wipe every registry. Production code should never call this."
  (clrhash *mode-buffers*)
  (clrhash *window-active-buffer*)
  (clrhash *engine-default-modes*))

;;; ── buffer-id ↔ mode-buffer ────────────────────────────────────────────

(defun register-mode-buffer (buffer-id mode-buffer)
  (setf (gethash buffer-id *mode-buffers*) mode-buffer))

(defun find-mode-buffer (buffer-id)
  (gethash buffer-id *mode-buffers*))

(defun unregister-mode-buffer (buffer-id)
  (remhash buffer-id *mode-buffers*))

;;; ── window → active buffer ─────────────────────────────────────────────

(defun set-window-active-buffer (win-id buffer-id)
  (setf (gethash win-id *window-active-buffer*) buffer-id))

(defun window-active-buffer (win-id)
  (gethash win-id *window-active-buffer*))

;;; ── engine → default major mode ────────────────────────────────────────

(defun register-engine-default-mode (engine mode-symbol)
  (setf (gethash engine *engine-default-modes*) mode-symbol))

(defun engine-default-mode (engine)
  (gethash engine *engine-default-modes*))

;;; ── composed lookup ────────────────────────────────────────────────────

(defun mode-buffer-for-window (win-id)
  "Compose: win-id → active buffer-id → mode-buffer. NIL on any miss."
  (let ((bid (window-active-buffer win-id)))
    (and bid (find-mode-buffer bid))))

;;; ── dispatch walker ────────────────────────────────────────────────────

(defun dispatch-key-via-stack (mode-buffer global-keymap spec)
  "Walk the mode keymap stack for SPEC, falling back to GLOBAL-KEYMAP.

   Order (Emacs convention): minor modes (newest first) → major mode →
   global. Returns the bound action (function, keyword, anything truthy
   limn/keys stores), or NIL if no level binds SPEC.

   MODE-BUFFER may be NIL (no buffer focused, or chrome not initialised);
   in that case we just consult GLOBAL-KEYMAP."
  (or (and mode-buffer (limn/mode:lookup-key mode-buffer spec))
      (and global-keymap (limn/keys:lookup global-keymap spec))))

;;; ── chrome bootstrap ───────────────────────────────────────────────────

(defparameter *chrome-buffer-modes*
  '(("*minibuffer*" . minibuffer-mode)
    ("*messages*"   . fundamental-mode)
    ("*echo-area*"  . fundamental-mode))
  "Mapping of reserved chrome buffer-id → default major mode symbol.
   These mode-buffers are created at runtime startup so chrome buffers
   can have their own keymap stack (e.g. *minibuffer* uses minibuffer-mode
   bindings for RET / ESC / printable chars).")

(defun init-chrome-buffers ()
  "Create a mode-buffer for each chrome buffer-id and activate its
   default mode. Idempotent — re-running just re-activates the same mode
   on existing mode-buffers."
  (dolist (entry *chrome-buffer-modes*)
    (let* ((bid       (car entry))
           (mode-name (cdr entry))
           (mb        (or (find-mode-buffer bid)
                          (let ((new (limn/mode:make-mode-buffer)))
                            (register-mode-buffer bid new)
                            new))))
      ;; Only activate if the mode is defined; harmless to skip otherwise
      ;; (init-chrome-buffers may be called before user init.lisp defines
      ;; custom modes).
      (when (limn/mode:find-mode mode-name)
        (limn/mode:activate mb mode-name)))))

;;; ── minibuffer round-trip ──────────────────────────────────────────────
;;;
;;; defcommand with an "s" interactive spec gathers its string argument
;;; via limn/cmd:*minibuffer-read*. Until batch 7, that was a stub that
;;; errored. Now we ship a real reader:
;;;
;;;   1. send minibuffer/open with prompt
;;;   2. block on wait-for-event until minibuffer-submit or
;;;      minibuffer-cancel fires
;;;   3. send minibuffer/close (always, per SPEC §5.4)
;;;   4. return the submitted text, or signal MINIBUFFER-CANCELLED
;;;
;;; Returned as a closure over SESSION so tests can use mock sessions
;;; without depending on limn:*session*.

(define-condition minibuffer-cancelled (error)
  ()
  (:report (lambda (c s) (declare (ignore c))
             (format s "minibuffer input cancelled"))))

(defvar *active-minibuffer-canceller* nil
  "Dynamic var: while make-minibuffer-reader is blocked in wait-for-event,
   bound to a zero-arg thunk that flips the wait's predicate to :cancel.

   keyboard-quit (the C-g command) consults this — if non-NIL, it calls
   it, aborting the read as if the user had hit ESC. NIL outside a read,
   so C-g is a harmless no-op when nothing is waiting.")

(defun make-minibuffer-reader (session)
  "Build a (function (prompt) → text) bound to SESSION. Install it as
   limn/cmd:*minibuffer-read* so interactive commands can prompt.

   While blocked, dynamically binds *active-minibuffer-canceller* so a
   C-g binding (keyboard-quit) can abort the wait without the reader
   knowing anything about key dispatch."
  (lambda (prompt)
    (let ((submitted nil)   ; :submit / :cancel / nil
          (text      nil))
      (labels ((on-submit (ev)
                 (setf text (getf ev :|text|) submitted :submit))
               (on-cancel (ev)
                 (declare (ignore ev))
                 (setf submitted :cancel)))
        (let ((sub-hook (limn/dispatch:event-hook-name "minibuffer-submit"))
              (can-hook (limn/dispatch:event-hook-name "minibuffer-cancel"))
              ;; Expose a canceller for keyboard-quit. Reading from the
              ;; same dynamic scope is safe — the pump thread runs hook
              ;; handlers (including keyboard-quit) inside this thread
              ;; while wait-for-event drains the socket.
              (*active-minibuffer-canceller*
                (lambda () (setf submitted :cancel))))
          (unwind-protect
               (progn
                 (limn/hooks:add-hook sub-hook #'on-submit)
                 (limn/hooks:add-hook can-hook #'on-cancel)
                 (limn/dispatch:call session "minibuffer/open"
                                     :|prompt| prompt)
                 (limn/dispatch:wait-for-event
                  session (lambda () submitted)
                  ;; Generous default: 5 min lets a user pause to think.
                  :timeout 300.0))
            (limn/hooks:remove-hook sub-hook #'on-submit)
            (limn/hooks:remove-hook can-hook #'on-cancel)
            ;; Always close — frontend keeps the widget open otherwise.
            (handler-case (limn/dispatch:call session "minibuffer/close")
              (error () nil)))
          (case submitted
            (:submit text)
            (:cancel (error 'minibuffer-cancelled))
            (t       (error "minibuffer-read: wait returned without flag"))))))))

;;; ── keyboard-quit + default C-g binding ────────────────────────────────
;;;
;;; Design (per discussion): C-g is deliberately NOT a hardcoded case in
;;; %dispatch-key. We register keyboard-quit as a regular defcommand and
;;; bind C-g to it in the default global keymap. User init.lisp can
;;; replace either side — define-command, or rebind C-g to something
;;; else entirely. Mirrors Emacs: keyboard-quit is interactive (callable
;;; via M-x), C-g is the default convenience binding.

(defun install-default-commands ()
  "Register the framework's built-in commands. Idempotent — defcommand
   re-registration just replaces the existing entry."
  (limn/cmd:defcommand keyboard-quit ()
    (lambda ()
      ;; Abort any blocked minibuffer-read. The reader has bound the
      ;; canceller dynamically, so we're modifying its local state.
      (when *active-minibuffer-canceller*
        (funcall *active-minibuffer-canceller*))
      ;; Note: clearing the global key-prefix accumulator (limn::*key-prefix*)
      ;; isn't visible here — the wire glue does it from the binding
      ;; lambda installed by install-default-bindings. Keeps this module
      ;; free of an upward dep on limn::.
      nil)))

(defun install-default-bindings (keymap)
  "Install the default global bindings on KEYMAP. Currently:
     C-g  → keyboard-quit (via call-interactively)

   This is a regular binding — `(limn/keys:define-key keymap \"C-g\" …)`
   afterwards (or limn:bind) will replace it."
  (limn/keys:define-key
   keymap "C-g"
   (lambda (ev)
     (declare (ignore ev))
     (handler-case (limn/cmd:call-interactively 'keyboard-quit)
       (minibuffer-cancelled () nil))))   ; cancel is the intended outcome
  keymap)

;; Register commands at LOAD time. The C-g binding is installed at
;; session start (limn.lisp:start calls install-default-bindings on the
;; lazy-created global keymap).
(install-default-commands)
