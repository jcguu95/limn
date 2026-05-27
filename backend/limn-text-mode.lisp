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
                       ;; v0.39 B10 — RET / TAB are named keys but they
                       ;; insert literal whitespace characters. Without
                       ;; this, xdotool's `type "line1\nline2"` lost the
                       ;; newlines (RET key fell on the floor — W14).
                       ((string= ch "RET") (string #\newline))
                       ((string= ch "TAB") (string #\tab))
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

;;; v0.39 W17 — switch-to-buffer.  Emacs's C-x b: list every buffer
;;;  known to the wire (PDF + text), let the user pick one via
;;;  completing-read, then ask C++ to make it visible in w1.  Works
;;;  cross-engine (PDF ↔ text).  Re-uses buffer/list (W20) for the
;;;  collection so the names match exactly what M-x buffer-list
;;;  would show.
(limn/cmd:defcommand switch-to-buffer (:interactive nil)
  (lambda ()
    (let* ((r       (limn/text::%limn-call "buffer/list"))
           (entries (limn/text::%response-data r))
           ;; Format each entry as "<id>  <path>" so users can pick by
           ;; either path or id.  Empty path → just the id (chrome).
           (lines   (and (listp entries)
                          (mapcar
                           (lambda (e)
                             (let ((bid (getf e :|buffer-id|))
                                   (path (getf e :|path|)))
                               (if (and path (stringp path)
                                         (plusp (length path)))
                                   (format nil "~a  ~a" bid path)
                                   (format nil "~a" bid))))
                           entries)))
           (cr      (find-symbol "COMPLETING-READ" :limn/completion))
           (pick    (and cr (fboundp cr) lines
                          (funcall (symbol-function cr)
                                   "Switch to buffer: " lines
                                   :require-match t))))
      (when (and pick (stringp pick))
        ;; First whitespace-token is the buffer-id.
        (let* ((sp (position #\Space pick))
               (bid (if sp (subseq pick 0 sp) pick)))
          (when (plusp (length bid))
            (limn/text::%limn-call "buffer/show"
                                    :|buffer-id| bid :|win-id| "w1")
            ;; If we just switched to a text buffer, cache it so
            ;; the next self-insert/yank routes correctly.
            (when (or (char= (aref bid 0) #\t)
                       (char= (aref bid 0) #\*))
              (setf limn/text:*current-text-buffer* bid))))))))

;;; v0.39 W17 — set-mark-command pins POS=cursor in the focused buffer.
;;; Emacs C-SPC; the inverse half of kill-region.  Stores into
;;; limn/mark, which kill-region reads via limn/mark:mark on the same
;;; buf-id.  Idempotent — pressing C-SPC twice overwrites.
(limn/cmd:defcommand set-mark-command (:interactive nil)
  (lambda ()
    (let* ((buf  (limn/text::%focused-text-buffer))
           (cur  (and buf (limn/text::%cursor buf)))
           (mpkg (find-package '#:limn/mark))
           (sm   (and mpkg (find-symbol "SET-MARK" mpkg))))
      (when (and buf (integerp cur) sm (fboundp sm))
        (funcall (symbol-function sm) cur buf)
        ;; Echo so the user sees the mark landed.
        (ignore-errors
          (limn/text::%limn-call "message/echo" :|text| "Mark set"))))))

;;; v0.39 W17 — kill-region deletes [mark, point) and pushes the text
;;; onto *kill-ring*.  Symmetric: deletion via buffer/delete + read
;;; via buffer/text (substring locally — the wire returns full text
;;; for text-engine buffers).  No-op when mark unset or empty range.
(limn/cmd:defcommand kill-region (:interactive nil)
  (lambda ()
    (let* ((buf  (limn/text::%focused-text-buffer))
           (cur  (and buf (limn/text::%cursor buf)))
           (mpkg (find-package '#:limn/mark))
           (mf   (and mpkg (find-symbol "MARK" mpkg)))
           (mk   (and buf mf (fboundp mf)
                      (funcall (symbol-function mf) buf))))
      (when (and buf (integerp cur) (integerp mk))
        (let ((from (min mk cur))
              (to   (max mk cur)))
          (when (< from to)
            ;; Read full buffer text, slice the range.
            (let* ((tr  (limn/text::%limn-call "buffer/text"
                                                :|buffer-id| buf))
                   (td  (limn/text::%response-data tr))
                   (all (and td (getf td :|text|)))
                   (txt (and (stringp all)
                              (<= to (length all))
                              (subseq all from to))))
              (when (and txt (plusp (length txt)))
                (let* ((kpkg (find-package '#:limn/kill))
                       (kn   (and kpkg (find-symbol "KILL-NEW" kpkg))))
                  (when (and kn (fboundp kn))
                    (funcall (symbol-function kn) txt)))))
            ;; Delete the range.  buffer/delete uses [from, to) codepoints.
            (limn/text::%limn-call "buffer/delete"
                                    :|buffer-id| buf
                                    :|from| from :|to| to)))))))

;;; v0.39 W13 / W17 — yank inserts the head of limn/kill:*kill-ring* at
;;; point. Cross-engine: M-w in pdf-mode pushes a string onto the ring,
;;; C-y in text-mode pulls it back out into a buffer.  We bypass
;;; limn/kill:yank's vtable (*buffer-insert-fn* etc.) because text-mode
;;; already knows the focused buffer-id via *current-text-buffer* and
;;; can call buffer/insert directly — same shape as self-insert-command.
(limn/cmd:defcommand yank (:interactive nil)
  (lambda ()
    (let* ((buf  (limn/text::%focused-text-buffer))
           (kpkg (find-package '#:limn/kill))
           (ring-sym (and kpkg (find-symbol "*KILL-RING*" kpkg)))
           (text (and ring-sym (boundp ring-sym)
                       (car (symbol-value ring-sym)))))
      (when (and buf (stringp text) (plusp (length text)))
        (limn/text::%limn-call "buffer/insert"
                                :|buffer-id| buf :|text| text)
        ;; Mark *last-command* so a follow-up M-y can yank-pop.
        (let* ((cpkg (find-package '#:limn/cmd))
               (lc   (and cpkg (find-symbol "*LAST-COMMAND*" cpkg))))
          (when (and lc (boundp lc))
            (set lc 'yank)))))))

;;; v0.36 — TAB / C-j commands. Delegate to limn/indent; bind *current-buffer*
;;; (and limn/local's parallel slot) to the focused text buffer so the
;;; module's vtable picks up the right buf-id.

(limn/cmd:defcommand indent-for-tab-command (:interactive nil)
  (lambda ()
    (let ((buf (limn/text::%focused-text-buffer))
          (ipkg (find-package '#:limn/indent))
          (xpkg (find-package '#:limn/excursion))
          (lpkg (find-package '#:limn/local)))
      (when (and buf ipkg)
        (let* ((xsym (and xpkg (find-symbol "*CURRENT-BUFFER*" xpkg)))
               (lsym (and lpkg (find-symbol "*CURRENT-BUFFER-ID*" lpkg)))
               (live (remove-if (lambda (p) (null (car p)))
                                (list (and xsym (cons xsym buf))
                                      (and lsym (cons lsym buf))))))
          (progv (mapcar #'car live) (mapcar #'cdr live)
            (let ((fn (find-symbol "INDENT-FOR-TAB-COMMAND" ipkg)))
              (when (and fn (fboundp fn))
                (funcall fn)))))))))

(limn/cmd:defcommand newline-and-indent (:interactive nil)
  (lambda ()
    (let ((buf (limn/text::%focused-text-buffer))
          (ipkg (find-package '#:limn/indent))
          (xpkg (find-package '#:limn/excursion))
          (lpkg (find-package '#:limn/local)))
      (when (and buf ipkg)
        (let* ((xsym (and xpkg (find-symbol "*CURRENT-BUFFER*" xpkg)))
               (lsym (and lpkg (find-symbol "*CURRENT-BUFFER-ID*" lpkg)))
               (live (remove-if (lambda (p) (null (car p)))
                                (list (and xsym (cons xsym buf))
                                      (and lsym (cons lsym buf))))))
          (progv (mapcar #'car live) (mapcar #'cdr live)
            (let ((fn (find-symbol "NEWLINE-AND-INDENT" ipkg)))
              (when (and fn (fboundp fn))
                (funcall fn)))))))))

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
        (c-tab   (intern "INDENT-FOR-TAB-COMMAND"   :cl-user))
        (c-nl    (intern "NEWLINE-AND-INDENT"       :cl-user))
        (c-yank  (intern "YANK"                     :cl-user))   ; v0.39 W13
        (c-mark  (intern "SET-MARK-COMMAND"         :cl-user))   ; v0.39 W17
        (c-kill  (intern "KILL-REGION"              :cl-user))   ; v0.39 W17
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
      ;; v0.39 B10 — RET inserts a newline (Emacs convention is
      ;; `newline-and-indent` in some modes; for fundamental text we
      ;; treat it as self-insert with the literal #\newline).  Without
      ;; this, xdotool's multi-line `type` lost line breaks.
      (%def-cmd km "RET"     c-self)
      (%def-cmd km "BS"      c-bksp)
      (%def-cmd km "<left>"  c-bwd)
      (%def-cmd km "<right>" c-fwd)
      (%def-cmd km "<home>"  c-bol)
      (%def-cmd km "<end>"   c-eol)
      ;; v0.39 W17 — Emacs C-a / C-e mirror their <home>/<end> twins.
      ;; W17 driver hits C-e to extend mark→eol before C-w; without
      ;; these the cursor stayed at 0, kill-region grabbed zero chars.
      (%def-cmd km "C-a"     c-bol)
      (%def-cmd km "C-e"     c-eol)
      (%def-cmd km "C-x C-s" c-save)
      (%def-cmd km "C-x C-f" c-find)
      ;; v0.36: TAB → indent-for-tab-command, C-j → newline-and-indent.
      (%def-cmd km "TAB"     c-tab)
      (%def-cmd km "C-j"     c-nl)
      ;; v0.39 W13 / W17 — C-y yanks head of *kill-ring* at point.
      ;; The kill side is whoever called limn/kill:kill-new (pdf-mode's
      ;; M-w binding, future text-mode C-w kill-region, init.lisp user
      ;; bindings, ...).
      (%def-cmd km "C-y"     c-yank)
      ;; v0.39 W17 — set-mark / kill-region.  C-SPC pins the mark;
      ;; C-w deletes [mark, point) into *kill-ring* (then a follow-up
      ;; C-y in another buffer yanks it back).
      (%def-cmd km "C-SPC"   c-mark)
      (%def-cmd km "C-w"     c-kill)

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
