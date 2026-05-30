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
               nil)))))))

  ;; ── M-: eval-expression (Emacs convention) ──────────────────────
  ;; Read a Lisp form string from the minibuffer via the "s" interactive
  ;; spec (same path as all string-reading commands), eval it, and echo
  ;; the result.  Mirrors Emacs M-: (eval-expression).  Errors are caught
  ;; and shown so a bad expression never kills the session.
  (limn/cmd:defcommand cl-user::eval-expression (:interactive "sEval: ")
    (lambda (input)
      (when (and (stringp input) (plusp (length input)))
        (handler-case
            (let* ((form   (read-from-string input))
                   (result (eval form)))
              (format t "~&=> ~s~%" result)
              (let* ((limn-pkg (find-package '#:limn))
                     (call-sym (and limn-pkg (find-symbol "CALL" limn-pkg))))
                (when (and call-sym (fboundp call-sym))
                  (handler-case
                      (funcall (symbol-function call-sym)
                               "message/echo"
                               :|text| (format nil "=> ~s" result))
                    (error () nil)))))
          (error (e)
            (format *error-output* "~&eval-expression error: ~a~%" e)
            (let* ((limn-pkg (find-package '#:limn))
                   (call-sym (and limn-pkg (find-symbol "CALL" limn-pkg))))
              (when (and call-sym (fboundp call-sym))
                (handler-case
                    (funcall (symbol-function call-sym)
                             "message/echo"
                             :|text| (format nil "Error: ~a" e))
                  (error () nil)))))))))

  ;; ── v0.38 B15: edit commands discoverable via M-x ────────────────
  ;; query-replace + query-replace-regexp existed since v0.34/v0.36 but
  ;; weren't registered as defcommands, so M-x completion didn't see
  ;; them (W18/W19 dogfood finding).  The interactive wrappers live in
  ;; limn-query-replace; we just register them here so they survive
  ;; clear-commands cycles.
  (let ((qr-pkg (find-package '#:limn/query-replace)))
    (when qr-pkg
      (let ((qr-i  (find-symbol "%QR-INTERACTIVE"  qr-pkg))
            (qrr-i (find-symbol "%QRR-INTERACTIVE" qr-pkg)))
        (when (and qr-i (fboundp qr-i))
          (limn/cmd:defcommand cl-user::query-replace ()
            (lambda () (funcall (symbol-function qr-i)))))
        (when (and qrr-i (fboundp qrr-i))
          (limn/cmd:defcommand cl-user::query-replace-regexp ()
            (lambda () (funcall (symbol-function qrr-i))))))))

  ;; ── v0.40 §2.1: narrow-to-region / widen interactive commands ────
  ;;
  ;; Emacs convention: C-x n n (narrow to [mark, point)), C-x n w
  ;; (widen).  Both work on the focused text buffer.  PDF mode doesn't
  ;; have a single text-stream so narrow doesn't apply there (yet).
  ;;
  ;; narrow-to-region reads mark and point from limn/mark + the
  ;; focused buffer's cursor; if no mark is set, echoes a hint and
  ;; does nothing.  widen is unconditional.
  (limn/cmd:defcommand cl-user::narrow-to-region ()
    (lambda ()
      (let* ((tpkg  (find-package '#:limn/text))
             (fbf   (and tpkg (find-symbol "%FOCUSED-TEXT-BUFFER" tpkg)))
             (buf   (and fbf (fboundp fbf) (funcall fbf)))
             (cur-fn (and tpkg (find-symbol "%CURSOR" tpkg)))
             (cur   (and buf cur-fn (fboundp cur-fn) (funcall cur-fn buf)))
             (mpkg  (find-package '#:limn/mark))
             (mf    (and mpkg (find-symbol "MARK" mpkg)))
             (mk    (and buf mf (fboundp mf) (funcall mf buf)))
             (xpkg  (find-package '#:limn/excursion))
             (lpkg  (find-package '#:limn/local))
             (ntr   (and xpkg (find-symbol "NARROW-TO-REGION" xpkg)))
             (call-sym (and (find-package '#:limn)
                            (find-symbol "CALL" '#:limn))))
        (cond
          ((not (and buf (integerp cur) (integerp mk)))
           (when (and call-sym (fboundp call-sym))
             (ignore-errors
               (funcall call-sym "message/echo"
                        :|text| "narrow-to-region: no mark set"))))
          (t
           (let* ((start (min mk cur))
                  (end   (max mk cur))
                  (xsym  (and xpkg (find-symbol "*CURRENT-BUFFER*" xpkg)))
                  (lsym  (and lpkg (find-symbol "*CURRENT-BUFFER-ID*" lpkg)))
                  (idoy  (and xpkg (find-symbol "INSTALL-DIM-OVERLAYS" xpkg))))
             (progv
                 (remove nil (list xsym lsym))
                 (remove nil (list (and xsym buf) (and lsym buf)))
               (when (and ntr (fboundp ntr))
                 (funcall ntr start end)))
             ;; v0.40 §2.3 — visual feedback: dim the inaccessible region.
             (when (and idoy (fboundp idoy))
               (ignore-errors (funcall idoy buf)))
             (when (and call-sym (fboundp call-sym))
               (ignore-errors
                 (funcall call-sym "message/echo"
                          :|text| (format nil "Narrowed to [~a, ~a)"
                                          start end))))))))))

  ;; v0.40 §2.4: narrow-to-defun (Emacs C-x n d).  Reader-driven: walk
  ;; top-level forms of the focused buffer's text, find the one that
  ;; contains point, and narrow to its bounds.  Lisp-specific (uses
  ;; READ-FROM-STRING).  Other major modes can later override.
  (limn/cmd:defcommand cl-user::narrow-to-defun ()
    (lambda ()
      (let* ((tpkg  (find-package '#:limn/text))
             (fbf   (and tpkg (find-symbol "%FOCUSED-TEXT-BUFFER" tpkg)))
             (buf   (and fbf (fboundp fbf) (funcall fbf)))
             (cur-fn (and tpkg (find-symbol "%CURSOR" tpkg)))
             (txt-fn (and tpkg (find-symbol "%BUFFER-TEXT" tpkg)))
             (cur   (and buf cur-fn (fboundp cur-fn) (funcall cur-fn buf)))
             (txt   (and buf txt-fn (fboundp txt-fn) (funcall txt-fn buf)))
             (xpkg  (find-package '#:limn/excursion))
             (lpkg  (find-package '#:limn/local))
             (fdb   (and xpkg (find-symbol "FIND-DEFUN-BOUNDS" xpkg)))
             (ntr   (and xpkg (find-symbol "NARROW-TO-REGION" xpkg)))
             (idoy  (and xpkg (find-symbol "INSTALL-DIM-OVERLAYS" xpkg)))
             (call-sym (and (find-package '#:limn)
                            (find-symbol "CALL" '#:limn))))
        (cond
          ((not (and buf (integerp cur) (stringp txt) fdb (fboundp fdb)))
           (when (and call-sym (fboundp call-sym))
             (ignore-errors
               (funcall call-sym "message/echo"
                        :|text| "narrow-to-defun: no buffer"))))
          (t
           (multiple-value-bind (start end) (funcall fdb txt cur)
             (cond
               ((not (and start end))
                (when (and call-sym (fboundp call-sym))
                  (ignore-errors
                    (funcall call-sym "message/echo"
                             :|text| "Point is not in a defun"))))
               (t
                (let ((xsym (and xpkg (find-symbol "*CURRENT-BUFFER*" xpkg)))
                      (lsym (and lpkg (find-symbol "*CURRENT-BUFFER-ID*" lpkg))))
                  (progv
                      (remove nil (list xsym lsym))
                      (remove nil (list (and xsym buf) (and lsym buf)))
                    (when (and ntr (fboundp ntr))
                      (funcall ntr start end))))
                (when (and idoy (fboundp idoy))
                  (ignore-errors (funcall idoy buf)))
                (when (and call-sym (fboundp call-sym))
                  (ignore-errors
                    (funcall call-sym "message/echo"
                             :|text|
                             (format nil "Narrowed to defun [~a, ~a)"
                                     start end))))))))))))

  (limn/cmd:defcommand cl-user::widen ()
    (lambda ()
      (let* ((tpkg  (find-package '#:limn/text))
             (fbf   (and tpkg (find-symbol "%FOCUSED-TEXT-BUFFER" tpkg)))
             (buf   (and fbf (fboundp fbf) (funcall fbf)))
             (xpkg  (find-package '#:limn/excursion))
             (lpkg  (find-package '#:limn/local))
             (widen (and xpkg (find-symbol "WIDEN" xpkg)))
             (xsym  (and xpkg (find-symbol "*CURRENT-BUFFER*" xpkg)))
             (lsym  (and lpkg (find-symbol "*CURRENT-BUFFER-ID*" lpkg)))
             (call-sym (and (find-package '#:limn)
                            (find-symbol "CALL" '#:limn))))
        (when buf
          (progv (remove nil (list xsym lsym))
                 (remove nil (list (and xsym buf) (and lsym buf)))
            (when (and widen (fboundp widen)) (funcall widen)))
          ;; v0.40 §2.3 — clear the dim overlays installed by narrow.
          (let ((rdoy (and xpkg (find-symbol "REMOVE-DIM-OVERLAYS" xpkg))))
            (when (and rdoy (fboundp rdoy))
              (ignore-errors (funcall rdoy buf))))
          (when (and call-sym (fboundp call-sym))
            (ignore-errors
              (funcall call-sym "message/echo" :|text| "Widened"))))))))

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

  ;; M-: → eval-expression (Emacs convention: eval a Lisp form).
  (limn/keys:define-key
   global-keymap "M-:"
   (lambda (ev) (declare (ignore ev))
     (handler-case (limn/cmd:call-interactively (find-symbol "EVAL-EXPRESSION" :cl-user))
       (error (e)
         (format *error-output* ";; M-: errored: ~a~%" e)))))

  ;; M-r → reload-init-file (hot-reload).  Chose M-r rather than C-c
  ;; C-l (Emacs convention) because C-c is a prefix in most modes.
  (limn/keys:define-key
   global-keymap "M-r"
   (lambda (ev) (declare (ignore ev))
     (handler-case (limn/cmd:call-interactively (find-symbol "RELOAD-INIT-FILE" :cl-user))
       (error (e)
         (format *error-output* ";; M-r errored: ~a~%" e)))))

  ;; v0.40 §2.1: narrow-to-region / widen.  Emacs conventions:
  ;;   C-x n n  narrow-to-region
  ;;   C-x n w  widen
  ;; C-x n is a prefix; which-key shows the sub-bindings after idle.
  (limn/keys:define-key
   global-keymap "C-x n n"
   (lambda (ev) (declare (ignore ev))
     (handler-case (limn/cmd:call-interactively
                    (find-symbol "NARROW-TO-REGION" :cl-user))
       (error (e)
         (format *error-output* ";; C-x n n errored: ~a~%" e)))))

  (limn/keys:define-key
   global-keymap "C-x n w"
   (lambda (ev) (declare (ignore ev))
     (handler-case (limn/cmd:call-interactively
                    (find-symbol "WIDEN" :cl-user))
       (error (e)
         (format *error-output* ";; C-x n w errored: ~a~%" e)))))

  (limn/keys:define-key
   global-keymap "C-x n d"
   (lambda (ev) (declare (ignore ev))
     (handler-case (limn/cmd:call-interactively
                    (find-symbol "NARROW-TO-DEFUN" :cl-user))
       (error (e)
         (format *error-output* ";; C-x n d errored: ~a~%" e)))))

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
