;;;; limn-text-mode — text-mode + find-file + self-insert / cursor /
;;;; save commands (SPEC v0.22 Phase B).
;;;;
;;;; Pure Lisp.  Depends on:
;;;;   limn/mode    — define-mode, mode-buffer, activate, lookup-key
;;;;   limn/keys    — make-keymap, define-key, lookup-sequence
;;;;   limn/cmd     — defcommand
;;;;   limn/runtime — register-engine-default-mode (optional, gated)
;;;;
;;;; Naming convention: text-mode AND its commands (self-insert-command,
;;;; delete-backward-char, find-file, save-buffer, ...) live in the
;;;; CL-USER package — matching the user-facing convention of init.lisp.
;;;; Users wanting to rebind / refer to these commands from their own
;;;; init.lisp can use plain symbols (no qualifier needed).

(in-package #:cl-user)

(defpackage #:limn/text
  (:use #:cl)
  (:export #:install                 ; called from limn.lisp bootstrap
           #:*last-key*
           #:*current-text-buffer*))

(in-package #:limn/text)

(defvar *last-key* nil
  "Bound by the keymap binding closure to the most recent key (1-char
   string) when it invokes self-insert-command. Lets self-insert work
   without threading the key event through call-interactively.")

(defvar *current-text-buffer* nil
  "Cached buffer-id of the focused text-engine buffer. Set by find-file
   when it opens a buffer and activates text-mode. Self-insert and
   friends use this instead of doing a view/get wire roundtrip per
   keystroke (which under high typing rates can race and reorder
   buffer/insert calls).")

;;; ── helpers ────────────────────────────────────────────────────────────

(defun %limn-call (cmd &rest kw)
  "Invoke limn:call when running inside a connected session; otherwise
   silently no-op (unit-tier context). Returns the response plist or NIL."
  (let* ((sym (find-symbol "CALL" :limn)))
    (when (and sym (fboundp sym))
      (apply (symbol-function sym) cmd kw))))

(defun %response-data (r)
  (let ((rd (find-symbol "RESPONSE-DATA" :limn/bridge)))
    (when (and rd (fboundp rd) r)
      (funcall (symbol-function rd) r))))

(defun %focused-text-buffer ()
  "Buffer-id of the currently-focused text-engine buffer. Prefers the
   cached *current-text-buffer* (set by find-file) to avoid a view/get
   wire roundtrip per keystroke — under fast typing the extra wire call
   races against subsequent buffer/insert events and reorders them."
  (or *current-text-buffer*
      (let* ((r (%limn-call "view/get" :|win-id| "w1"))
             (d (%response-data r))
             (b (getf d :|buffer-id|)))
        (when (and b (stringp b)) b))))

(defun %cursor (buf)
  (let* ((r (%limn-call "buffer/cursor-get" :|buffer-id| buf))
         (d (%response-data r)))
    (or (getf d :|offset|) 0)))

(defun %text-length (buf)
  (let* ((r (%limn-call "buffer/text" :|buffer-id| buf))
         (d (%response-data r)))
    (length (or (getf d :|text|) ""))))

;;; ── commands (defined in CL-USER per init.lisp convention) ─────────────

(in-package #:cl-user)

(limn/cmd:defcommand self-insert-command (:interactive nil)
  ;; The keymap wrapper dynamic-binds limn/text:*last-key* to the
  ;; originating key spec (1-char or named like "SPC") before calling.
  (lambda ()
    (let* ((sym (find-symbol "*LAST-KEY*" :limn/text))
           (ch  (and sym (boundp sym) (symbol-value sym)))
           (buf (limn/text::%focused-text-buffer))
           (text (cond ((null ch) nil)
                       ;; SPC → actual space character.
                       ((string= ch "SPC") " ")
                       ;; Any other single-char key spec is the literal char.
                       ((= 1 (length ch)) ch)
                       (t nil))))
      (when (and buf text)
        (limn/text::%limn-call "buffer/insert"
                                :|buffer-id| buf :|text| text)))))

(limn/cmd:defcommand delete-backward-char (:interactive nil)
  (lambda ()
    (let ((buf (limn/text::%focused-text-buffer)))
      (when buf
        (let ((cur (limn/text::%cursor buf)))
          (when (plusp cur)
            (limn/text::%limn-call "buffer/delete" :|buffer-id| buf
                                    :|from| (1- cur) :|to| cur)))))))

(limn/cmd:defcommand forward-char (:interactive nil)
  (lambda ()
    (let ((buf (limn/text::%focused-text-buffer)))
      (when buf
        (let ((cur (limn/text::%cursor buf))
              (len (limn/text::%text-length buf)))
          (when (< cur len)
            (limn/text::%limn-call "buffer/cursor-set"
                                    :|buffer-id| buf :|offset| (1+ cur))))))))

(limn/cmd:defcommand backward-char (:interactive nil)
  (lambda ()
    (let ((buf (limn/text::%focused-text-buffer)))
      (when buf
        (let ((cur (limn/text::%cursor buf)))
          (when (plusp cur)
            (limn/text::%limn-call "buffer/cursor-set"
                                    :|buffer-id| buf :|offset| (1- cur))))))))

(limn/cmd:defcommand move-beginning-of-line (:interactive nil)
  ;; v0.22 simplification: jump to buffer beginning. Full Emacs C-a
  ;; needs newline-scanning, deferred.
  (lambda ()
    (let ((buf (limn/text::%focused-text-buffer)))
      (when buf
        (limn/text::%limn-call "buffer/cursor-set"
                                :|buffer-id| buf :|offset| 0)))))

(limn/cmd:defcommand move-end-of-line (:interactive nil)
  (lambda ()
    (let ((buf (limn/text::%focused-text-buffer)))
      (when buf
        (limn/text::%limn-call "buffer/cursor-set"
                                :|buffer-id| buf
                                :|offset| (limn/text::%text-length buf))))))

(limn/cmd:defcommand save-buffer (:interactive nil)
  (lambda ()
    (let ((buf (limn/text::%focused-text-buffer)))
      (when buf
        (limn/text::%limn-call "buffer/save" :|buffer-id| buf)))))

(limn/cmd:defcommand find-file (:interactive "fFile: ")
  (lambda (path)
    ;; 1) Allocate a fresh text-engine buffer in w1.
    ;; 2) Try load-file; if it fails because the file doesn't exist,
    ;;    leave buffer empty and echo "New file".
    ;; 3) Activate text-mode on the buffer's window-buffer.
    (let* ((r (limn/text::%limn-call "bridge/engine-load"
                                      :|win-id| "w1" :|engine| "text"
                                      :|path| ""))
           (d (limn/text::%response-data r))
           (buf (getf d :|buffer-id|)))
      (when buf
        ;; Cache so self-insert / cursor-* commands don't view/get per keystroke.
        (setf limn/text:*current-text-buffer* buf)
        (let* ((lr (limn/text::%limn-call "buffer/load-file"
                                           :|buffer-id| buf :|path| path))
               (ok (eq (getf lr :|ok|) t)))
          (unless ok
            (limn/text::%limn-call "message/echo" :|text| "New file")))
        ;; Activate text-mode on this window's mode-buffer.
        (let* ((rt (find-package :limn/runtime))
               (mb-fn (and rt (find-symbol "MODE-BUFFER-FOR-WINDOW" rt))))
          (when (and mb-fn (fboundp mb-fn))
            (let ((mb (funcall (symbol-function mb-fn) "w1")))
              (when mb
                (handler-case
                    (limn/mode:activate mb 'text-mode)
                  (error () nil))))))))))

;;; ── mode + keymap ──────────────────────────────────────────────────────

(in-package #:limn/text)

(defun %wrap-cmd (sym)
  "Wrap a defcommand symbol SYM as a key-binding lambda. The lambda
   captures the key-event plist EV, binds *last-key* dynamically (so
   self-insert can recover which char was typed), and dispatches via
   call-interactively. Mirrors what limn:bind does for global keys."
  (lambda (ev)
    (let ((*last-key* (getf ev :|key|)))
      (limn/cmd:call-interactively sym))))

(defun %def-cmd (km spec sym)
  (limn/keys:define-key km spec (%wrap-cmd sym)))

(defun %printable-ascii-chars ()
  ;; Skip space (32) — limn/keys:define-key splits multi-key sequences
  ;; on space, so " " can't be a single-key binding. Handled separately
  ;; below as "SPC" (Emacs convention, matches limn_input.cpp).
  (loop for code from 33 to 126
        collect (string (code-char code))))

(defun install ()
  "Idempotent setup: define text-mode (parent = fundamental-mode), build
   its keymap, and register it as the default mode for engine=text.
   Called from limn.lisp's bootstrap AFTER fundamental-mode is defined."
  ;; Resolve user-facing symbols (cl-user-interned).
  (let ((c-self  (intern "SELF-INSERT-COMMAND"      :cl-user))
        (c-bksp  (intern "DELETE-BACKWARD-CHAR"     :cl-user))
        (c-fwd   (intern "FORWARD-CHAR"             :cl-user))
        (c-bwd   (intern "BACKWARD-CHAR"            :cl-user))
        (c-bol   (intern "MOVE-BEGINNING-OF-LINE"   :cl-user))
        (c-eol   (intern "MOVE-END-OF-LINE"         :cl-user))
        (c-save  (intern "SAVE-BUFFER"              :cl-user))
        (c-find  (intern "FIND-FILE"                :cl-user))
        (sym-tm  (intern "TEXT-MODE"                :cl-user)))

    ;; Ensure fundamental-mode exists (limn.lisp bootstrap normally
    ;; does this, but tests load modules in isolation).
    (let ((fund (find-symbol "FUNDAMENTAL-MODE" :limn/runtime)))
      (when (and fund (not (limn/mode:find-mode fund)))
        (limn/mode:define-mode fund :type :major :modeline "Fund")))

    ;; Build the keymap. Key names match what limn_input.cpp's
    ;; key_to_string emits (Emacs convention: SPC, BS, <left>, ...).
    ;; ASCII space (0x20) can't be a single-key spec in limn/keys
    ;; because define-key splits on space — bind "SPC" instead, which
    ;; is what Qt::Key_Space resolves to on the wire.
    (let* ((km (limn/keys:make-keymap)))
      (dolist (ch (%printable-ascii-chars))
        (%def-cmd km ch c-self))
      (%def-cmd km "SPC"     c-self)            ; space char
      (%def-cmd km "BS"      c-bksp)
      (%def-cmd km "<left>"  c-bwd)
      (%def-cmd km "<right>" c-fwd)
      (%def-cmd km "<home>"  c-bol)
      (%def-cmd km "<end>"   c-eol)
      (%def-cmd km "C-x C-s" c-save)
      (%def-cmd km "C-x C-f" c-find)

      ;; Register the mode.
      (let ((fund (find-symbol "FUNDAMENTAL-MODE" :limn/runtime)))
        (limn/mode:define-mode sym-tm
                                :type :major
                                :parent fund
                                :modeline "Text")
        (setf (limn/mode:mode-keymap (limn/mode:find-mode sym-tm)) km)
        (limn/mode:define-mode sym-tm
                                :type :major
                                :parent fund
                                :modeline "Text")))

    ;; Register engine-default-mode "text" → text-mode.
    (let ((reg (find-symbol "REGISTER-ENGINE-DEFAULT-MODE" :limn/runtime)))
      (when (and reg (fboundp reg))
        (funcall (symbol-function reg) "text" sym-tm)))

    ;; Subscribe to event/buffer-opened: cache the buffer-id whenever a
    ;; text-engine buffer is opened. Without this cache, self-insert
    ;; does a view/get per keystroke and fast typing races (chars get
    ;; reordered, e.g. "abc" → "acb"). Idempotent: hook is idempotent
    ;; via add-hook's name-based dedup behavior.
    (let ((add (find-symbol "ADD-HOOK" :limn/hooks)))
      (when (and add (fboundp add))
        (funcall (symbol-function add) "event/buffer-opened"
                 (lambda (ev)
                   (when (equal (getf ev :|engine|) "text")
                     (let ((bid (getf ev :|buffer-id|)))
                       (when (and bid (stringp bid))
                         (setf *current-text-buffer* bid))))))))

    sym-tm))

;;; Auto-install at load time. Idempotent — re-loading is safe.
(install)
