;;;; limn-bookmark-cmds — user-facing M-x commands + keymap bindings
;;;; for limn-bookmark (v0.37 "bookmark everywhere").
;;;;
;;;; Split from limn-bookmark.lisp so the core module stays free of
;;;; defcommand / runtime / completion dependencies and remains
;;;; unit-testable in pure isolation.
;;;;
;;;; Commands (all interned in :cl-user, M-x discoverable):
;;;;
;;;;   bookmark-set        — capture current location, prompt for name
;;;;   bookmark-jump       — completing-read over names, jump
;;;;   bookmark-delete     — completing-read over names, remove
;;;;   bookmark-rename     — old (completion) + new (free input)
;;;;   bookmark-list       — echo all names + handlers (P4 swaps in bmenu)
;;;;   bookmark-save       — flush in-memory store to ~/.limn/bookmarks.lisp
;;;;   bookmark-load       — reload from sidecar
;;;;
;;;; Keymap install (called from install-bookmark-bindings):
;;;;
;;;;   C-x r m   bookmark-set
;;;;   C-x r b   bookmark-jump
;;;;   C-x r l   bookmark-list
;;;;   C-x r d   bookmark-delete
;;;;   C-x r M   bookmark-rename
;;;;
;;;; (Matches Emacs's "register / rectangle / bookmark" C-x r prefix.
;;;;  Coexists with — and shadows nothing of — the per-PDF single-char
;;;;  bookmark UI in limn-pdf-mode §E, which uses `m a` / `' a` style
;;;;  Emacs-register bindings instead.)

(defpackage #:limn/bookmark-cmds
  (:use #:cl)
  (:export #:install-bookmark-commands
           #:install-bookmark-bindings
           #:current-handler-symbol))

(in-package #:limn/bookmark-cmds)

;;; ── helpers ────────────────────────────────────────────────────────

(defun current-handler-symbol (&optional (win-id "w1"))
  "Major-mode symbol for the buffer currently focused in WIN-ID.
   Returns NIL if there's no active buffer or no mode-buffer record."
  (let* ((rt-pkg (find-package '#:limn/runtime))
         (wab    (and rt-pkg (find-symbol "WINDOW-ACTIVE-BUFFER" rt-pkg)))
         (fmb    (and rt-pkg (find-symbol "FIND-MODE-BUFFER" rt-pkg)))
         (mb-pkg (find-package '#:limn/mode))
         (major  (and mb-pkg (find-symbol "MODE-BUFFER-MAJOR" mb-pkg))))
    (when (and wab fmb major (fboundp wab) (fboundp fmb) (fboundp major))
      (let* ((bid (funcall (symbol-function wab) win-id))
             (mb  (and bid (funcall (symbol-function fmb) bid))))
        (and mb (funcall (symbol-function major) mb))))))

(defun %echo (fmt &rest args)
  "Show a one-line message to the user.  Uses limn:call message/echo
   when the bridge is live; otherwise just prints to stdout."
  (let* ((text (apply #'format nil fmt args))
         (limn-pkg (find-package '#:limn))
         (call (and limn-pkg (find-symbol "CALL" limn-pkg))))
    (if (and call (fboundp call))
        (handler-case
            (funcall (symbol-function call) "message/echo" :|text| text)
          (error () (format t "~&~a~%" text)))
        (format t "~&~a~%" text))
    text))

(defun %prompt-name (prompt)
  "Read a non-empty string from the minibuffer via the runtime's
   *minibuffer-read*.  Returns the string or NIL if cancelled / empty."
  (let* ((cmd-pkg (find-package '#:limn/cmd))
         (mb-sym  (and cmd-pkg (find-symbol "*MINIBUFFER-READ*" cmd-pkg)))
         (mb-fn   (and mb-sym (boundp mb-sym) (symbol-value mb-sym))))
    (when (and mb-fn (functionp mb-fn))
      (handler-case
          (let ((s (funcall mb-fn prompt)))
            (and (stringp s) (plusp (length s)) s))
        (error () nil)))))

(defun %completing-pick (prompt names)
  "Pick a string from NAMES via limn/completion:completing-read.
   When the live minibuffer is wired, this opens a real completion
   prompt.  When called from unit tests with no live minibuffer it
   returns the first name (matches completing-read's batch fallback)."
  (let ((compl-pkg (find-package '#:limn/completion)))
    (when compl-pkg
      (let ((cr (find-symbol "COMPLETING-READ" compl-pkg)))
        (when (and cr (fboundp cr))
          (handler-case
              (funcall (symbol-function cr) prompt names :require-match t)
            (error () nil)))))))

(defun %save-quiet ()
  "Persist the in-memory store; swallow IO errors so a sandboxed
   user (no ~/.limn write perm) still gets the in-memory bookmark."
  (handler-case (limn/bookmark:bookmarks-save)
    (error (e)
      (format *error-output*
              ";; limn/bookmark: save failed: ~a~%" e)
      nil)))

;;; ── command bodies ─────────────────────────────────────────────────

(defun cmd-bookmark-set (name)
  "Capture the current buffer's location, store under NAME, save.

   Distinguishes the three 'can't capture' cases so the user knows
   which branch fired:
     1. no focused buffer at all
     2. mode is focused but no record-fn registered for that mode
        (= bookmark feature not wired for this mode yet)
     3. record-fn registered but returned NIL (= buffer is unsaved
        / scratch / has no path to record)."
  (cond
    ((or (null name) (zerop (length name)))
     (%echo "bookmark-set: empty name"))
    (t
     (let* ((mode  (current-handler-symbol))
            (has-fn (and mode
                         (gethash mode limn/bookmark:*record-fn-registry*)))
            (record (and has-fn (limn/bookmark:make-current-record mode))))
       (cond
         ((null mode)
          (%echo "bookmark-set: no focused buffer"))
         ((null has-fn)
          (%echo "bookmark-set: ~s isn't a bookmarkable mode yet" mode))
         ((null record)
          (%echo "bookmark-set: nothing to capture here ~
                  (buffer probably unsaved / has no path)"))
         (t
          (limn/bookmark:bookmark-add
           (limn/bookmark:make-bookmark
            :name name :handler mode :record record))
          (%save-quiet)
          (%echo "bookmark set: ~a" name)))))))

(defun cmd-bookmark-jump ()
  (let ((names (mapcar #'limn/bookmark:bookmark-name
                       (limn/bookmark:bookmark-list))))
    (cond
      ((null names) (%echo "no bookmarks"))
      (t
       (let ((pick (%completing-pick "Jump to bookmark: " names)))
         (cond
           ((or (null pick) (zerop (length pick)))
            (%echo "bookmark-jump: cancelled"))
           ((null (limn/bookmark:bookmark-find pick))
            (%echo "bookmark-jump: no match for ~s" pick))
           (t
            (handler-case
                (progn (limn/bookmark:bookmark-jump pick)
                       (%echo "bookmark: ~a" pick))
              (error (e) (%echo "bookmark-jump: ~a" e))))))))))

(defun cmd-bookmark-delete ()
  (let ((names (mapcar #'limn/bookmark:bookmark-name
                       (limn/bookmark:bookmark-list))))
    (cond
      ((null names) (%echo "no bookmarks to delete"))
      (t
       (let ((pick (%completing-pick "Delete bookmark: " names)))
         (when (and pick (limn/bookmark:bookmark-find pick))
           (limn/bookmark:bookmark-remove pick)
           (%save-quiet)
           (%echo "bookmark deleted: ~a" pick)))))))

(defun cmd-bookmark-rename ()
  (let ((names (mapcar #'limn/bookmark:bookmark-name
                       (limn/bookmark:bookmark-list))))
    (cond
      ((null names) (%echo "no bookmarks to rename"))
      (t
       (let* ((old (%completing-pick "Rename bookmark: " names))
              (new (and old (%prompt-name (format nil "New name for ~a: " old)))))
         (cond
           ((or (null old) (null new)) (%echo "bookmark-rename: cancelled"))
           ((not (limn/bookmark:bookmark-rename old new))
            (%echo "bookmark-rename: refused (name ~a already taken?)" new))
           (t (%save-quiet)
              (%echo "bookmark renamed: ~a → ~a" old new))))))))

(defun cmd-bookmark-list ()
  (let ((bms (limn/bookmark:bookmark-list)))
    (cond
      ((null bms) (%echo "no bookmarks"))
      (t
       (let ((lines (mapcar (lambda (b)
                              (format nil "~a  [~a]"
                                      (limn/bookmark:bookmark-name b)
                                      (limn/bookmark:bookmark-handler b)))
                            bms)))
         (%echo "bookmarks (~a): ~{~a~^ | ~}" (length bms) lines))))))

(defun cmd-bookmark-save ()
  (let ((p (handler-case (limn/bookmark:bookmarks-save)
             (error (e) (%echo "bookmark-save: ~a" e) nil))))
    (when p (%echo "saved → ~a" p))))

(defun cmd-bookmark-load ()
  (let ((n (handler-case (limn/bookmark:bookmarks-load)
             (error (e) (%echo "bookmark-load: ~a" e) 0))))
    (%echo "loaded ~a bookmark~:p" n)))

;;; ── command registration (cl-user namespace) ───────────────────────
;;;
;;; Mirrors the convention in limn-default-config:install-default-
;;; commands — defcommand idempotent, names interned in :cl-user so
;;; users can rebind them from init.lisp without find-symbol gymnastics.

(defun install-bookmark-commands ()
  "Register all bookmark M-x commands in :cl-user.  Idempotent —
   defcommand re-registers in place."
  (limn/cmd:defcommand cl-user::bookmark-set (:interactive "sBookmark name: ")
    (lambda (name) (cmd-bookmark-set name)))
  (limn/cmd:defcommand cl-user::bookmark-jump ()
    (lambda () (cmd-bookmark-jump)))
  (limn/cmd:defcommand cl-user::bookmark-delete ()
    (lambda () (cmd-bookmark-delete)))
  (limn/cmd:defcommand cl-user::bookmark-rename ()
    (lambda () (cmd-bookmark-rename)))
  (limn/cmd:defcommand cl-user::bookmark-list ()
    (lambda () (cmd-bookmark-list)))
  (limn/cmd:defcommand cl-user::bookmark-save ()
    (lambda () (cmd-bookmark-save)))
  (limn/cmd:defcommand cl-user::bookmark-load ()
    (lambda () (cmd-bookmark-load)))
  t)

(install-bookmark-commands)

;;; ── keymap install ─────────────────────────────────────────────────
;;;
;;; Routes through limn/cmd:call-interactively so prefix-arg / spec
;;; gathering / history all work identically to M-x dispatch.

(defun %bind (km key cmd-sym)
  "Bind KEY in KM to a closure that runs CMD-SYM via call-interactively."
  (limn/keys:define-key
   km key
   (lambda (&optional ev) (declare (ignore ev))
     (handler-case (limn/cmd:call-interactively cmd-sym)
       (error (e)
         (format *error-output*
                 ";; ~a errored: ~a~%" cmd-sym e))))))

(defun install-bookmark-bindings (global-keymap)
  "Bind C-x r m/b/l/d/M on GLOBAL-KEYMAP.  Called from
   limn-default-config:install-defaults after install-bookmark-
   commands has registered the cl-user::bookmark-* commands.

   Returns GLOBAL-KEYMAP."
  (install-bookmark-commands)
  (%bind global-keymap "C-x r m"
         (find-symbol "BOOKMARK-SET"    :cl-user))
  (%bind global-keymap "C-x r b"
         (find-symbol "BOOKMARK-JUMP"   :cl-user))
  (%bind global-keymap "C-x r l"
         (find-symbol "BOOKMARK-LIST"   :cl-user))
  (%bind global-keymap "C-x r d"
         (find-symbol "BOOKMARK-DELETE" :cl-user))
  (%bind global-keymap "C-x r M"
         (find-symbol "BOOKMARK-RENAME" :cl-user))
  global-keymap)
