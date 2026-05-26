;;;; limn-default-config — Limn's built-in defaults loaded between
;;;; framework bootstrap and user init.lisp.
;;;;
;;;; Goal: a fresh Limn launch with NO user init file already feels
;;;; usable.  Provides:
;;;;
;;;;   - M-x command-palette (execute-command + completing-read over
;;;;     defcommand registry)
;;;;   - M-r reload-init-file (hot-reload user's ~/.limn/init.lisp)
;;;;   - which-key-mode enabled by default (popup after prefix idle)
;;;;
;;;; Loaded by limn.lisp's bootstrap RIGHT AFTER install-default-
;;;; bindings; user init.lisp loads AFTER us so it can override
;;;; anything here.
;;;;
;;;; This module sits late in the dependency chain so it can use
;;;; limn/completion + limn/which-key directly without find-symbol
;;;; gymnastics.

(defpackage #:limn/default-config
  (:use #:cl)
  (:export #:install-defaults
           #:install-default-commands
           #:execute-command
           #:reload-init-file))

(in-package #:limn/default-config)

;;; Mirror limn/runtime:install-default-commands pattern.  Wrapping the
;;; defcommand forms inside a defun lets tests call clear-commands and
;;; then re-register cleanly (tests that wipe the registry for isolation
;;; would otherwise leave our defcommands gone forever).
;;;
;;; defcommand names are interned in :cl-user so they're discoverable
;;; by users (M-x execute-command, not limn/default-config::execute-
;;; command).  Mirrors the text-mode / pdf-mode convention.

(defun install-default-commands ()
  "Register execute-command + reload-init-file in the :cl-user
   namespace.  Idempotent — defcommand re-registration replaces the
   existing entry.  Safe to call after limn/cmd:clear-commands."

  ;; ── M-x command palette ──────────────────────────────────────────
  (limn/cmd:defcommand cl-user::execute-command ()
    (lambda ()
      "Read a command name with completion and call it interactively.
       Emacs's M-x equivalent."
      (let* ((cmds  (limn/cmd:list-commands))
             (names (sort (mapcar (lambda (c)
                                    (string-downcase
                                     (symbol-name
                                      (limn/cmd:command-name c))))
                                  cmds)
                          #'string<))
             (chosen (limn/completion:completing-read
                      "M-x " names :require-match t)))
        (when (and chosen (not (zerop (length chosen))))
          (let ((sym (find-symbol (string-upcase chosen) :cl-user)))
            (when (and sym (limn/cmd:find-command sym))
              (limn/cmd:call-interactively sym)))))))

  ;; ── hot-reload user init.lisp ────────────────────────────────────
  (limn/cmd:defcommand cl-user::reload-init-file ()
    (lambda ()
      "Re-load the user's init.lisp without restarting Limn.  Errors
       are caught and reported to *error-output* — a syntax error in
       init.lisp won't kill the session.  Returns the loaded path or
       NIL."
      (let* ((rt-pkg (find-package '#:limn/runtime))
             (loader (and rt-pkg (find-symbol "LOAD-INIT-FILE" rt-pkg)))
             (resolver (and rt-pkg (find-symbol "RESOLVE-INIT-PATH" rt-pkg)))
             (path (and resolver (funcall (symbol-function resolver)))))
        (cond
          ((null path)
           (format t ";; reload-init-file: no init file found~%")
           nil)
          (t
           (handler-case
               (let ((loaded (funcall (symbol-function loader) :resilient t)))
                 (format t ";; reload-init-file: ~a~%" path)
                 loaded)
             (error (e)
               (format *error-output*
                       ";; reload-init-file: ~a ERRORED: ~a~%" path e)
               nil))))))))

;; Register at load time.  (install-defaults below re-calls this so any
;; clear-commands between bring-up + start gets undone.)
(install-default-commands)

;;; ── installation ────────────────────────────────────────────────────────

(defun install-defaults (global-keymap)
  "Install the framework's default user-facing bindings on GLOBAL-KEYMAP
   and enable opt-in defaults.  Idempotent.  Called from limn.lisp's
   bootstrap after install-default-bindings; user init.lisp loads
   AFTER and may override anything here."
  ;; Re-register the defcommands in case something cleared the registry
  ;; between load-time and now (unit tests do this for isolation).
  (install-default-commands)
  ;; M-x → execute-command.  Symbol is cl-user::execute-command since
  ;; that's where defcommand interned it (see comment at the top).
  (limn/keys:define-key
   global-keymap "M-x"
   (lambda (ev) (declare (ignore ev))
     (handler-case (limn/cmd:call-interactively (find-symbol "EXECUTE-COMMAND" :cl-user))
       (error (e)
         (format *error-output* ";; M-x errored: ~a~%" e)))))

  ;; M-r → reload-init-file (hot-reload).  Chose M-r rather than C-c
  ;; C-l (Emacs convention) because C-c is a prefix in most modes.
  (limn/keys:define-key
   global-keymap "M-r"
   (lambda (ev) (declare (ignore ev))
     (handler-case (limn/cmd:call-interactively (find-symbol "RELOAD-INIT-FILE" :cl-user))
       (error (e)
         (format *error-output* ";; M-r errored: ~a~%" e)))))

  ;; Enable which-key by default — popup hints after prefix-key idle.
  ;; Users wanting it off can call (limn/which-key:which-key-mode -1)
  ;; in their init.lisp.
  (let ((wk-pkg (find-package '#:limn/which-key)))
    (when wk-pkg
      (let ((wk-mode (find-symbol "WHICH-KEY-MODE" wk-pkg)))
        (when (and wk-mode (fboundp wk-mode))
          (handler-case (funcall (symbol-function wk-mode))
            (error (e)
              (format *error-output*
                      ";; which-key-mode failed to enable: ~a~%" e)))))))

  global-keymap)
