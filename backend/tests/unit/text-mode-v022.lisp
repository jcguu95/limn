;;;; v0.22 text-mode + find-file — pure-Lisp RED tests
;;;;
;;;; SPEC §12 v0.22 Phase B：在 =backend/text-mode.lisp= 定義
;;;;
;;;;   text-mode (major)             繼承 fundamental-mode
;;;;     - printable char  →  self-insert-command
;;;;     - Backspace       →  delete-backward-char
;;;;     - Left/Right/...  →  forward-char/backward-char/move-bol/move-eol
;;;;     - C-x C-s         →  save-buffer
;;;;     - C-x C-f         →  find-file
;;;;
;;;;   self-insert-command           defcommand → buffer/insert
;;;;   delete-backward-char          defcommand → buffer/delete
;;;;   forward-char / backward-char / move-bol / move-eol
;;;;   save-buffer                   defcommand → buffer/save
;;;;   find-file                     defcommand → engine-load text + load-file
;;;;
;;;;   engine-default-mode "text" 註冊為 text-mode
;;;;
;;;; 純 Lisp、沒有 running Limn process。所有測試 v0.22 Phase B 實作前全紅。

(in-package #:limn/unit-test)

;; v0.22 framework names (text-mode + its commands) live in CL-USER per
;; init.lisp convention. Shadowing-import them so 'self-insert-command
;; etc. read correctly here without explicit cl-user:: prefix.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :limn/runtime) (defpackage :limn/runtime (:use :cl)))
  (unless (find-package :limn/cmd)     (defpackage :limn/cmd     (:use :cl)))
  (unless (find-package :limn/mode)    (defpackage :limn/mode    (:use :cl)))
  (dolist (name '("TEXT-MODE"
                  "SELF-INSERT-COMMAND" "DELETE-BACKWARD-CHAR"
                  "FORWARD-CHAR" "BACKWARD-CHAR"
                  "MOVE-BEGINNING-OF-LINE" "MOVE-END-OF-LINE"
                  "SAVE-BUFFER" "FIND-FILE"))
    (shadowing-import (intern name :cl-user) :limn/unit-test)))

;;; ── B1. text-mode is defined ──────────────────────────────────────────

;; Each test ensures text-mode is installed: v019 tests call clear-modes
;; which wipes mode definitions, so we re-install here to be self-contained.
(defun %install-text-mode ()
  (let ((install (find-symbol "INSTALL" :limn/text)))
    (when install (funcall install))))

(deftest v022-text-mode-defined
  "text-mode is registered as a major mode after backend/text-mode.lisp
   loads (which happens via limn.lisp bootstrap)."
  (%install-text-mode)
  (let ((m (limn/mode:find-mode 'text-mode)))
    (assert-true m "text-mode found via find-mode")
    (when m
      (assert-equal :major (limn/mode:mode-type m)
                    "text-mode is :major")
      (assert-true (limn/mode:mode-keymap m)
                   "text-mode has a keymap"))))

(deftest v022-text-mode-modeline-name
  "text-mode's modeline shortname is sensible (\"Text\" or similar)."
  (%install-text-mode)
  (let ((m (limn/mode:find-mode 'text-mode)))
    (assert-true m)
    (when m
      (assert-true (and (stringp (limn/mode:mode-modeline-name m))
                        (plusp (length (limn/mode:mode-modeline-name m))))
                   "modeline name is a non-empty string"))))

;;; ── B2. printable char handling ───────────────────────────────────────
;;;
;;; Implementation may either (a) bind every ASCII printable explicitly
;;; or (b) provide a fallback mechanism. Either way, the OBSERVABLE
;;; contract is: looking up a single printable char returns a non-nil
;;; action.

(deftest v022-text-mode-printable-bound
  "Looking up a printable character on a text-mode buffer returns
   a non-nil action (binds to self-insert-command or equivalent)."
  (%install-text-mode)
  (let ((m (limn/mode:find-mode 'text-mode)))
    (assert-true m)
    (when m
      (let ((buf (limn/mode:make-mode-buffer)))
        (limn/mode:activate buf 'text-mode)
        ;; Note: " " (space) cannot be a single-key binding in limn/keys
        ;; because define-key uses space as the multi-key separator.
        ;; Space typing in xdotool is handled at dispatch via a different
        ;; key name ("Space" / Qt::Key_Space) — out of v0.22 scope.
        (dolist (ch '("a" "Z" "0" "!" "~"))
          (assert-true (limn/mode:lookup-key buf ch)
                       (format nil "lookup-key ~s bound" ch)))))))

(deftest v022-self-insert-command-defined
  "self-insert-command is registered."
  (assert-true (limn/cmd:find-command 'self-insert-command)
               "self-insert-command findable"))

;;; ── B3. Backspace binding ─────────────────────────────────────────────

(deftest v022-text-mode-binds-backspace
  "Backspace is bound to delete-backward-char (or equivalent) on text-mode.
   Key name 'BS' matches Qt::Key_Backspace serialisation (Emacs style)."
  (%install-text-mode)
  (let ((m (limn/mode:find-mode 'text-mode)))
    (assert-true m)
    (when m
      (let ((buf (limn/mode:make-mode-buffer)))
        (limn/mode:activate buf 'text-mode)
        (assert-true (limn/mode:lookup-key buf "BS")
                     "BS (Backspace) bound")))))

(deftest v022-delete-backward-char-command-defined
  (assert-true (limn/cmd:find-command 'delete-backward-char)))

;;; ── B4. cursor movement bindings ──────────────────────────────────────

(deftest v022-text-mode-binds-arrow-keys
  "Left / Right / Home / End are bound on text-mode."
  (%install-text-mode)
  (let ((m (limn/mode:find-mode 'text-mode)))
    (assert-true m)
    (when m
      (let ((buf (limn/mode:make-mode-buffer)))
        (limn/mode:activate buf 'text-mode)
        ;; Names match limn_input.cpp's key_to_string output.
        (dolist (k '("<left>" "<right>" "<home>" "<end>"))
          (assert-true (limn/mode:lookup-key buf k)
                       (format nil "~s bound on text-mode" k)))))))

(deftest v022-cursor-movement-commands-defined
  "forward-char / backward-char / move-beginning-of-line /
   move-end-of-line all registered."
  (dolist (name '(forward-char backward-char
                  move-beginning-of-line move-end-of-line))
    (assert-true (limn/cmd:find-command name)
                 (format nil "~s findable" name))))

;;; ── B5. C-x C-s save binding ──────────────────────────────────────────

(deftest v022-text-mode-binds-save
  "C-x C-s on text-mode dispatches to save-buffer."
  (%install-text-mode)
  (let ((m (limn/mode:find-mode 'text-mode)))
    (assert-true m)
    (when m
      (let ((buf (limn/mode:make-mode-buffer)))
        (limn/mode:activate buf 'text-mode)
        ;; Multi-key lookup via lookup-sequence
        (let ((seq-fn (find-symbol "LOOKUP-SEQUENCE" :limn/keys))
              (km    (limn/mode:mode-keymap m)))
          (assert-true seq-fn)
          (when seq-fn
            (let ((r (funcall seq-fn km '("C-x" "C-s"))))
              (assert-true r "C-x C-s resolves on text-mode keymap"))))))))

(deftest v022-save-buffer-command-defined
  (assert-true (limn/cmd:find-command 'save-buffer)))

;;; ── B6. C-x C-f find-file binding ─────────────────────────────────────

(deftest v022-text-mode-binds-find-file
  "C-x C-f on text-mode (or global, accepted either way) → find-file."
  (%install-text-mode)
  (let ((m (limn/mode:find-mode 'text-mode)))
    (assert-true m)
    (when m
      (let ((seq-fn (find-symbol "LOOKUP-SEQUENCE" :limn/keys))
            (km    (limn/mode:mode-keymap m)))
        (when seq-fn
          (let ((r (funcall seq-fn km '("C-x" "C-f"))))
            (assert-true r "C-x C-f resolves on text-mode")))))))

(deftest v022-find-file-command-defined
  (let ((c (limn/cmd:find-command 'find-file)))
    (assert-true c "find-file findable")
    (when c
      ;; find-file uses :interactive "fFile: " (file-spec)
      (let ((spec (limn/cmd:command-spec c)))
        (assert-true (and spec (char= (char spec 0) #\f))
                     "find-file interactive spec starts with 'f'")))))

;;; ── B7. engine-default-mode for "text" ────────────────────────────────

(deftest v022-text-engine-default-mode
  "limn/runtime:engine-default-mode \"text\" → 'text-mode (so opening
   an engine=text buffer auto-activates text-mode)."
  (%install-text-mode)
  (let ((fn (find-symbol "ENGINE-DEFAULT-MODE" :limn/runtime)))
    (assert-true fn)
    (when fn
      (assert-eq 'text-mode (funcall fn "text")
                 "engine=text → text-mode"))))

;;; ── B8. text-mode keymap parent chain ─────────────────────────────────

(deftest v022-text-mode-parent-fundamental
  "text-mode :parent is fundamental-mode (so e.g. C-g is inherited)."
  (%install-text-mode)
  (let* ((fund-sym (find-symbol "FUNDAMENTAL-MODE" :limn/runtime))
         (tm (limn/mode:find-mode 'text-mode))
         (fm (and fund-sym (limn/mode:find-mode fund-sym))))
    (assert-true tm)
    (assert-true fm)
    (when (and tm fm)
      (let ((kp-fn (find-symbol "KEYMAP-PARENT" :limn/keys))
            (km    (limn/mode:mode-keymap tm)))
        (when (and kp-fn km)
          (assert-eq (limn/mode:mode-keymap fm)
                     (funcall kp-fn km)
                     "text-mode keymap parent === fundamental-mode keymap"))))))

;;; ── v0.39 W13 / W17 keybindings ──────────────────────────────────────
;;;
;;; The text-mode keymap learned five Emacs bindings in v0.39: C-a / C-e
;;; (mirror <home>/<end>; W17 driver needed C-e to move past EOL before
;;; C-w), C-SPC set-mark, C-w kill-region, C-y yank.  Without these the
;;; cross-buffer kill/yank dogfood was structurally broken.

(defun %binding (km spec)
  "Look up SPEC (space-separated key sequence) in keymap KM, returning
   the bound action or NIL."
  (let ((parts (loop for i = 0 then (1+ j)
                     for j = (position #\Space spec :start i)
                     collect (subseq spec i j)
                     while j)))
    (limn/keys:lookup-sequence km parts)))

(deftest v039-w17-text-mode-binds-c-a-c-e
  "C-a / C-e in text-mode invoke move-beginning-of-line / move-end-of-line
   (the W17 driver's C-e hit nothing pre-fix and cursor stayed at 0)."
  (%install-text-mode)
  (let ((km (limn/mode:mode-keymap (limn/mode:find-mode 'text-mode))))
    (assert-true km "text-mode keymap exists")
    (when km
      (assert-true (%binding km "C-a") "C-a is bound in text-mode")
      (assert-true (%binding km "C-e") "C-e is bound in text-mode"))))

(deftest v039-w17-text-mode-binds-mark-and-kill
  "C-SPC / C-w / C-y exist in text-mode."
  (%install-text-mode)
  (let ((km (limn/mode:mode-keymap (limn/mode:find-mode 'text-mode))))
    (when km
      (assert-true (%binding km "C-SPC") "C-SPC bound")
      (assert-true (%binding km "C-w")   "C-w bound")
      (assert-true (%binding km "C-y")   "C-y bound"))))

(deftest v039-w13-w17-defcommands-registered
  "set-mark-command / kill-region / yank are real defcommands so M-x
   discovers them and the dispatch wrapper resolves them."
  (let ((find-cmd (find-symbol "FIND-COMMAND" :limn/cmd)))
    (assert-true find-cmd)
    (when find-cmd
      (assert-true (funcall find-cmd (intern "SET-MARK-COMMAND" :cl-user))
                   "set-mark-command in defcommand registry")
      (assert-true (funcall find-cmd (intern "KILL-REGION" :cl-user))
                   "kill-region in defcommand registry")
      (assert-true (funcall find-cmd (intern "YANK" :cl-user))
                   "yank in defcommand registry"))))

(deftest v039-w13-pdf-mode-binds-m-w
  "pdf-mode's M-w invokes pdf-copy-region-as-kill (W13 dogfood — copy
   PDF selection text onto *kill-ring* for a subsequent C-y paste)."
  (%install-text-mode)
  (let* ((install (find-symbol "INSTALL" :limn/pdf-mode))
         (pm-sym  (intern "PDF-MODE" :cl-user)))
    (when install (funcall install))
    (let* ((pm (limn/mode:find-mode pm-sym))
           (km (and pm (limn/mode:mode-keymap pm))))
      (assert-true pm "pdf-mode found")
      (when km
        (assert-true (%binding km "M-w") "M-w bound in pdf-mode")
        (let ((cmd-sym (find-symbol "PDF-COPY-REGION-AS-KILL" :cl-user))
              (find-cmd (find-symbol "FIND-COMMAND" :limn/cmd)))
          (assert-true cmd-sym "pdf-copy-region-as-kill interned")
          (when (and cmd-sym find-cmd)
            (assert-true (funcall find-cmd cmd-sym)
                         "pdf-copy-region-as-kill is a defcommand")))))))

;;; ── B9. find-file wire behaviour ──────────────────────────────────────
;;;
;;; The "find-file does engine-load + load-file" contract requires a
;;; running Limn process. Covered at OS tier by batch-os-text-edit.lisp
;;; §B3 / §B4. We keep unit-tier focused on Lisp structure (mode,
;;; keymap, command registration).
