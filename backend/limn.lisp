;;;; limn — top-level control layer.
;;;;
;;;; Composition root. Loads the supporting modules, wires a key-event
;;;; handler into limn/hooks that translates Frontend `key` events into
;;;; keymap lookups, and exposes a small public surface for embedders.
;;;;
;;;; Typical usage:
;;;;
;;;;   (load "limn.lisp")
;;;;   (limn:start "/tmp/limn-12345")
;;;;   (limn:bind "C-x C-f"  (lambda (_ev) (limn:open-buffer "/tmp/x.pdf")))
;;;;   (limn:run)            ; blocks, pumping events forever
;;;;
;;;; The control layer is intentionally thin — most "editor behaviour" lives
;;;; in user code that calls limn:bind / limn:on-event.

(defpackage #:limn
  (:use #:cl)
  (:export #:start #:stop #:running-p
           #:call #:notify #:run #:pump
           #:bind #:unbind #:on-event #:off-event
           ;; convenience wrappers over common bridge commands
           #:open-buffer #:close-buffer #:view-set #:view-get
           #:win-list #:capabilities
           ;; introspection
           #:*session* #:*global-keymap*))

(in-package #:limn)

;;; ── module surface lookups ─────────────────────────────────────────────

(defun %sym (pkg name) (find-symbol (string name) pkg))
(defun %call (pkg name &rest args)
  (let ((s (%sym pkg name)))
    (unless s (error "limn: ~a missing in ~a" name pkg))
    (apply s args)))

;;; ── session state ──────────────────────────────────────────────────────

(defvar *session* nil
  "Current limn/dispatch session, or NIL if not started.")

(defvar *global-keymap* nil
  "Top-level keymap. Created lazily on first START.")

;; v0.19 β: *key-prefix* lives in limn/keys: now (was limn:: internal).
;; All reads/writes routed through limn/keys:*key-prefix* / set-key-prefix
;; so user-land which-key can subscribe to event/key-prefix-changed.

(defvar *prefix-arg-acc* ""
  "Accumulator for numeric prefix arg. e.g. user typing '5g' sees:
     '5' → *prefix-arg-acc* = \"5\"
     'g' → parse \"5\", bind limn/cmd:*prefix-arg* to 5, dispatch 'g',
           reset accumulator.")

(defvar *running* nil)

(declaim (ftype (function () t) stop))

(defun running-p () (and *session* *running* t))

;;; ── key-event handler ──────────────────────────────────────────────────

(defun %mod-letter (m)
  "Map a wire-format modifier name to its Emacs-style single-letter form."
  (let ((s (string-downcase m)))
    (cond ((or (string= s "ctrl") (string= s "control")) "C")
          ((or (string= s "alt")  (string= s "meta"))    "M")
          ((string= s "shift")                            "S")
          ((string= s "super")                            "s")
          (t s))))

(defun %strip-redundant-shift (mods key)
  "v0.38 B12: drop \"shift\" from MODS when KEY is already an uppercase
   single letter — the case already encodes the shift in Emacs conv.
     {key:\"G\", mods:[\"shift\"]}        → mods = ()   (lookup is \"G\")
     {key:\"G\", mods:[\"ctrl\",\"shift\"]} → (ctrl)    (lookup is \"C-G\")
     {key:\"5\", mods:[\"shift\"]}        → keep shift (non-letter)"
  (if (and mods key
           (stringp key) (= (length key) 1)
           (let ((c (char key 0))) (and (alpha-char-p c) (upper-case-p c))))
      (remove "shift" mods :test #'string-equal)
      mods))

(defun %event-key-spec (ev)
  "Turn a `key` event plist (key + mods array) into an Emacs-style spec.
   Modifiers are mapped: ctrl → C, alt/meta → M, shift → S, super → s.
   e.g. {key:\"d\", mods:[\"ctrl\"]} → \"C-d\".

   v0.38 B12: when KEY is an uppercase letter, Shift is redundant and
   gets stripped from MODS before formatting.  Otherwise Shift+G on
   the wire becomes \"S-G\" which fails to match the keymap binding
   \"G\" (which is the Emacs canonical form for uppercase letters)."
  (let* ((key  (getf ev :|key|))
         (mods (%strip-redundant-shift (getf ev :|mods|) key)))
    (cond
      ((null mods) key)
      (t (format nil "~{~a-~}~a"
                 (mapcar #'%mod-letter mods) key)))))

(defvar *log-keys* t
  "When non-NIL, every dispatched key event prints to *standard-output*
   in the SBCL REPL: spec, win-id, and what (if anything) resolved.
   Default is T during the dogfood cycle so the user sees every dispatch
   without remembering to toggle.  Turn off before shipping:
     (setf limn::*log-keys* nil)")

(defun %dispatch-key (ev)
  "Hook handler: receive a key event, walk the active mode-buffer's keymap
   stack (minor → major) then fall back to *global-keymap*, invoke action
   when matched.

   v0.8 batch 6: previously consulted *global-keymap* only. Now resolves
   the focused mode-buffer via limn/runtime (win-id → buffer-id →
   mode-buffer) so per-buffer modes get a chance to handle the key
   first. Prefix-key state (multi-step sequences like C-x C-f) is still
   global — making it per-buffer is v0.9 territory.

   Multi-key sequences are walked via lookup-sequence on EACH level
   independently: if the active buffer's keymap has a partial match
   (`:prefix`), we commit to that level for the duration of the prefix.
   This matches Emacs (you don't \"fall through\" mid-sequence)."
  (let* ((spec       (%event-key-spec ev))
         (mods       (getf ev :|mods|))
         (km         *global-keymap*)
         (lookup-seq (%sym :limn/keys '#:lookup-sequence)))
    (when *log-keys*
      (format *standard-output*
              "~&[limn:key] spec=~S win=~A mods=~A~%"
              spec (getf ev :|win-id|) mods)
      (force-output *standard-output*))
    (unless lookup-seq (return-from %dispatch-key nil))

    ;; A5 numeric prefix arg accumulation: a digit pressed with no
    ;; modifier AND no multi-key prefix in progress is treated as a
    ;; prefix-arg digit (just like Emacs C-u 5 g, but without C-u).
    ;; First non-digit ends accumulation, value goes into
    ;; limn/cmd:*prefix-arg* dynamic binding for that dispatch.
    ;;
    ;; v0.37 Phase F: BUT — if the active mode-buffer has an explicit
    ;; binding for the digit (e.g. pdf-mode binds "0" to pdf-zoom-reset),
    ;; honour the binding instead of swallowing the key as a prefix arg.
    ;; Otherwise pdf users can never reset zoom with "0" (v027-nav Ω6c).
    (when (and (null mods)
               (null limn/keys:*key-prefix*)
               (= 1 (length spec))
               (let ((c (char spec 0)))
                 (and (char>= c #\0) (char<= c #\9)))
               ;; No mode-buffer binding for this digit?  Then it's a
               ;; prefix-arg accumulation.
               (let* ((win-id (or (getf ev :|win-id|) "w1"))
                      (rt     (find-package :limn/runtime))
                      (mb-fn  (and rt (find-symbol "MODE-BUFFER-FOR-WINDOW" rt)))
                      (mb     (and mb-fn (funcall mb-fn win-id))))
                 (null (%mode-stack-lookup mb (list spec) lookup-seq))))
      ;; accumulate digit, do NOT dispatch the digit itself
      (setf *prefix-arg-acc* (concatenate 'string *prefix-arg-acc* spec))
      (return-from %dispatch-key nil))

    (let* ((sequence   (append limn/keys:*key-prefix* (list spec)))
           (win-id  (or (getf ev :|win-id|) "w1"))
           (rt      (find-package :limn/runtime))
           (mb-fn   (and rt (find-symbol "MODE-BUFFER-FOR-WINDOW" rt)))
           (mb      (and mb-fn (funcall mb-fn win-id)))
           (mode-result (%mode-stack-lookup mb sequence lookup-seq))
           (global-result (and km (funcall lookup-seq km sequence)))
           ;; v0.38 B7-leader fix: when sequence starts with *leader-key*
           ;; (default "SPC"), consult *leader-keymap* with the remainder.
           ;; Pre-v0.38 *leader-keymap* was populated by (map! :leader ...)
           ;; but NOTHING ever looked at it — so user's leader bindings
           ;; silently no-op'd at runtime.
           (leader-result
             (when (and (boundp 'limn/keys:*leader-key*)
                        limn/keys:*leader-key*
                        (boundp 'limn/keys:*leader-keymap*)
                        sequence
                        (string= (first sequence) limn/keys:*leader-key*))
               (let ((rest-seq (rest sequence)))
                 (if (null rest-seq)
                     ;; SPC alone: act as prefix if *leader-keymap* has
                     ;; any entries.  keymap-bindings is unexported;
                     ;; use ::-internal access.
                     (let* ((kbf (find-symbol "KEYMAP-BINDINGS" '#:limn/keys))
                            (kb  (and kbf limn/keys:*leader-keymap*
                                      (funcall (symbol-function kbf)
                                                limn/keys:*leader-keymap*))))
                       (when (and kb (plusp (hash-table-count kb))) :prefix))
                     (funcall lookup-seq
                              limn/keys:*leader-keymap* rest-seq)))))
           (result        (or mode-result global-result leader-result))
           ;; Bind prefix-arg if accumulated; gather-args reads it
           ;; via :interactive "p". Reset accumulator regardless.
           (acc-int (when (plusp (length *prefix-arg-acc*))
                      (parse-integer *prefix-arg-acc* :junk-allowed t))))
      (when *log-keys*
        (format *standard-output*
                "[limn:key]   → resolved=~A mode=~A global=~A leader=~A~%"
                (cond ((eq result :prefix) :prefix)
                      ((functionp result) (or (multiple-value-bind (n)
                                                  (ignore-errors
                                                    (nth-value
                                                     2 (function-lambda-expression
                                                        result)))
                                                n)
                                              :unnamed-fn))
                      ((null result) :unbound)
                      (t result))
                (and mode-result t) (and global-result t) (and leader-result t))
        (force-output *standard-output*))
      (setf *prefix-arg-acc* "")
      (cond
        ((eq result :prefix)
         (limn/keys:set-key-prefix sequence))
        ((functionp result)
         (limn/keys:set-key-prefix '())
         (let* ((cmd-pkg (find-package :limn/cmd))
                (slot    (and cmd-pkg (find-symbol "*PREFIX-ARG*" cmd-pkg))))
           ;; v0.38: always progv *prefix-arg*, whether or not user typed
           ;; a prefix.  acc-int = typed value or NIL.  Commands using
           ;; "p" spec that expect numeric default (e.g. scroll 1×) write
           ;; (or prefix 1).  Commands wanting vim-style "no prefix →
           ;; sentinel" (e.g. pdf-goto-page → last) write (or prefix end).
           ;; Pre-v0.38 only progv'd when acc-int was set, leaving NO-prefix
           ;; calls to see *prefix-arg*'s default of 1 — which made
           ;; pdf-goto-page mis-route bare 'G' to page 1 (B11 follow-up).
           (if slot
               (progv (list slot) (list acc-int)
                 (handler-case (funcall result ev)
                   (error (e) (format *error-output*
                                      "limn: binding for ~{~a~^ ~} errored: ~a~%"
                                      sequence e))))
               (handler-case (funcall result ev)
                 (error (e) (format *error-output*
                                    "limn: binding for ~{~a~^ ~} errored: ~a~%"
                                    sequence e))))))
        (t
         (limn/keys:set-key-prefix '()))))))

(defun %mode-stack-lookup (mode-buffer sequence lookup-seq)
  "Walk SEQUENCE through MODE-BUFFER's keymap stack (minor newest first →
   major). Returns the same kinds of result as limn/keys:lookup-sequence
   (action / :prefix / nil). NIL mode-buffer → NIL."
  (unless mode-buffer (return-from %mode-stack-lookup nil))
  (let* ((mode-pkg (find-package :limn/mode)))
    (unless mode-pkg (return-from %mode-stack-lookup nil))
    (let* ((minors (funcall (find-symbol "MINOR-MODES" mode-pkg) mode-buffer))
           (major  (funcall (find-symbol "MAJOR-MODE" mode-pkg) mode-buffer))
           (find-m (find-symbol "FIND-MODE" mode-pkg))
           (m-km   (find-symbol "MODE-KEYMAP" mode-pkg)))
      (flet ((try (mode-name)
               (let* ((m  (and mode-name (funcall find-m mode-name)))
                      (km (and m (funcall m-km m))))
                 (and km (funcall lookup-seq km sequence)))))
        ;; Minors newest first, then major. First non-nil wins.
        (or (some (lambda (mn) (try mn)) minors)
            (try major))))))

(defun %install-key-handler ()
  "Register %dispatch-key on the 'event/key' hook (idempotent)."
  (let ((add    (%sym :limn/hooks '#:add-hook))
        (remove (%sym :limn/hooks '#:remove-hook))
        (hook-of (%sym :limn/dispatch '#:event-hook-name)))
    (when (and add remove hook-of)
      (let ((name (funcall hook-of "key")))
        ;; remove any previous binding so re-START doesn't double-fire
        (funcall remove name #'%dispatch-key)
        (funcall add name #'%dispatch-key)))))

;;; ── buffer ↔ mode-buffer wiring ────────────────────────────────────────
;;;
;;; The frontend doesn't know about modes. Backend convention (SPEC §9.1):
;;; when a wire-level buffer comes into existence (engine-load response,
;;; or chrome bootstrap), we create a mode-buffer for it. When it goes
;;; away (buffer/close response), we drop the mapping.
;;;
;;; We listen on `buffer-opened` and `buffer-closed` events. The frontend
;;; emits these from bridge/engine-load + buffer/close — already
;;; established in v0.6.

(defun %on-buffer-opened (ev)
  "Create a mode-buffer for the newly-opened wire buffer and activate the
   engine-default major mode (e.g. mupdf → pdf-mode). Also marks the
   buffer as the active one for its window so the next key event routes
   to it."
  (let* ((rt    (find-package :limn/runtime))
         (mode  (find-package :limn/mode))
         (bid   (getf ev :|buffer-id|))
         (wid   (or (getf ev :|win-id|) "w1"))
         (engine (getf ev :|engine|)))
    (when (and rt mode bid)
      (let* ((find-mb     (find-symbol "FIND-MODE-BUFFER"     rt))
             (reg-mb      (find-symbol "REGISTER-MODE-BUFFER" rt))
             (set-active  (find-symbol "SET-WINDOW-ACTIVE-BUFFER" rt))
             (default-of  (find-symbol "ENGINE-DEFAULT-MODE"  rt))
             (make-mb     (find-symbol "MAKE-MODE-BUFFER"     mode))
             (activate    (find-symbol "ACTIVATE"             mode))
             (find-mode   (find-symbol "FIND-MODE"            mode))
             (existing    (and find-mb (funcall find-mb bid)))
             (mb          (or existing
                              (let ((new (funcall make-mb)))
                                (funcall reg-mb bid new)
                                new)))
             (mode-name   (and engine default-of
                               (funcall default-of engine))))
        (when (and activate find-mode mode-name
                   (funcall find-mode mode-name))
          (handler-case (funcall activate mb mode-name)
            (error (e) (format *error-output*
                               "limn: activate ~a on ~a errored: ~a~%"
                               mode-name bid e))))
        (when set-active
          (funcall set-active wid bid))))))

(defun %on-buffer-closed (ev)
  (let ((rt  (find-package :limn/runtime))
        (bid (getf ev :|buffer-id|)))
    (when (and rt bid)
      (let ((un (find-symbol "UNREGISTER-MODE-BUFFER" rt)))
        (when un (funcall un bid))))))

(defun %install-buffer-handlers ()
  (let ((add    (%sym :limn/hooks '#:add-hook))
        (remove (%sym :limn/hooks '#:remove-hook))
        (hook-of (%sym :limn/dispatch '#:event-hook-name)))
    (when (and add remove hook-of)
      (let ((open  (funcall hook-of "buffer-opened"))
            (close (funcall hook-of "buffer-closed")))
        (funcall remove open  #'%on-buffer-opened)
        (funcall add    open  #'%on-buffer-opened)
        (funcall remove close #'%on-buffer-closed)
        (funcall add    close #'%on-buffer-closed)))))

;;; ── ime-commit / ime-preedit notes (v0.16) ────────────────────────────
;;;
;;; SPEC §6 events ime-preedit / ime-commit. Dispatch into the
;;; minibuffer happens *server-side* in cmd_test_inject_ime_commit
;;; (and any future real IME commit path) — same vanilla-Emacs C-core
;;; pattern: the C-level commit_text path mutates the buffer at point,
;;; Lisp observers get the event but the mutation is automatic.
;;;
;;; This means user Lisp doesn't have to register a dispatcher to get
;;; CJK typing in the minibuffer working — it Just Works. User code
;;; that wants to OBSERVE ime-commit (e.g. log every committed string)
;;; can still add-hook event/ime-commit normally.
;;;
;;; ime-preedit is purely informational at the C level (no buffer
;;; mutation — it's a composition preview, not committed text). User
;;; code can add-hook event/ime-preedit to render a composition
;;; underline / candidate window if they want.

;;; ── start / stop ───────────────────────────────────────────────────────

(defun %bootstrap-runtime ()
  "One-time runtime config: declare engine→mode defaults + init chrome
   mode-buffers. Idempotent — safe to call on every START.

   Defined before START so the compiler doesn't warn about a forward
   reference when compiling START."
  (let ((rt   (find-package :limn/runtime))
        (mode (find-package :limn/mode)))
    (unless (and rt mode) (return-from %bootstrap-runtime nil))
    (let ((reg-default (find-symbol "REGISTER-ENGINE-DEFAULT-MODE" rt))
          (init-chrome (find-symbol "INIT-CHROME-BUFFERS"          rt))
          (define-mode (find-symbol "DEFINE-MODE"                  mode))
          (fund-sym    (find-symbol "FUNDAMENTAL-MODE"             rt))
          (mini-sym    (find-symbol "MINIBUFFER-MODE"              rt)))
      ;; Define the bare-bones default modes if user init.lisp hasn't
      ;; already. They start with empty keymaps; user code or future
      ;; engine code adds bindings.
      (when (and define-mode fund-sym)
        (funcall define-mode fund-sym :type :major :modeline "Fund"))
      (when (and define-mode mini-sym)
        (funcall define-mode mini-sym :type :major :modeline "Mini"))
      ;; mupdf engine: v0.27 ships limn-pdf-mode as the default. If the
      ;; pdf-mode module is loaded, its install function registers itself
      ;; as engine-default-mode for "mupdf" (overrides our fundamental-mode
      ;; fallback) and rebuilds its keymap idempotently. If not loaded,
      ;; we keep the fundamental-mode fallback so the binary still works.
      (when (and reg-default fund-sym)
        (funcall reg-default "mupdf" fund-sym))
      (let* ((pdf-pkg (find-package '#:limn/pdf-mode))
             (pdf-install (and pdf-pkg (find-symbol "INSTALL" pdf-pkg))))
        (when (and pdf-install (fboundp pdf-install))
          (handler-case (funcall (symbol-function pdf-install))
            (error (e)
              (format *error-output*
                      "limn: pdf-mode install failed: ~a~%" e)))))
      ;; Same idea for text-mode (v0.22).
      (let* ((tpkg (find-package '#:limn/text))
             (tinstall (and tpkg (find-symbol "INSTALL" tpkg))))
        (when (and tinstall (fboundp tinstall))
          (handler-case (funcall (symbol-function tinstall))
            (error () nil))))
      ;; v0.30: wire buffer-modified events → marker fixup engine.
      ;; Idempotent. If limn/marker isn't loaded, silently skip — the
      ;; module is optional for binaries that don't track marker state.
      (let* ((mpkg (find-package '#:limn/marker))
             (minstall (and mpkg (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER"
                                              mpkg))))
        (when (and minstall (fboundp minstall))
          (handler-case (funcall (symbol-function minstall))
            (error (e)
              (format *error-output*
                      "limn: marker handler install failed: ~a~%" e)))))
      ;; v0.37 Phase F: wire buffer-modified → deactivate-mark so the
      ;; region drops automatically when text-widget input edits the
      ;; buffer (xdotool type, IME commit, paste — anything that
      ;; bypasses the dispatch layer's note-command callback).
      ;; Idempotent; harmless if limn/mark isn't loaded.
      (let* ((mkpkg (find-package '#:limn/mark))
             (mkinstall (and mkpkg
                             (find-symbol "INSTALL-AUTO-DEACTIVATE-HANDLER"
                                          mkpkg))))
        (when (and mkinstall (fboundp mkinstall))
          (handler-case (funcall (symbol-function mkinstall))
            (error (e)
              (format *error-output*
                      "limn: mark auto-deactivate install failed: ~a~%" e)))))
      ;; v0.36: wire indent + query-replace vtables to live wire commands.
      (dolist (pkg-name '(#:limn/indent #:limn/query-replace))
        (let* ((pkg (find-package pkg-name))
               (fn (and pkg (find-symbol "INSTALL-WIRE-VTABLE" pkg))))
          (when (and fn (fboundp fn))
            (handler-case (funcall (symbol-function fn))
              (error (e)
                (format *error-output*
                        "limn: ~a install-wire-vtable failed: ~a~%"
                        pkg-name e))))))
      (when init-chrome (funcall init-chrome)))))

(defun start (socket-path)
  "Open a connection to SOCKET-PATH and create a session."
  (when *session* (stop))
  (let* ((c (%call :limn/client '#:connect socket-path))
         (s (%call :limn/dispatch '#:make-session-for c)))
    (setf *session* s)
    (unless *global-keymap*
      (setf *global-keymap* (%call :limn/keys '#:make-keymap)))
    ;; Install default global bindings (C-g → keyboard-quit). User
    ;; init.lisp running later can override any of them with limn:bind.
    (let ((install (and (find-package :limn/runtime)
                        (find-symbol "INSTALL-DEFAULT-BINDINGS"
                                     :limn/runtime))))
      (when install (funcall install *global-keymap*)))
    ;; v0.38 B5 fix: install M-x / M-r / which-key defaults.  This was
    ;; exported by limn/default-config since v0.37 Phase B but never
    ;; called from start, so M-letter keystrokes never had bindings to
    ;; dispatch into (W27/W28 dogfood finding).
    (let ((install-defaults (and (find-package :limn/default-config)
                                   (find-symbol "INSTALL-DEFAULTS"
                                                :limn/default-config))))
      (when (and install-defaults (fboundp install-defaults))
        (funcall (symbol-function install-defaults) *global-keymap*)))
    (%install-key-handler)
    (%install-buffer-handlers)
    ;; Register the default engine→mode mapping and bootstrap mode-buffers
    ;; for the three chrome buffer-ids so they have keymap stacks from
    ;; the moment the session is up. User init.lisp can override either.
    (%bootstrap-runtime)
    ;; Install the real minibuffer reader so defcommand "s" specs do a
    ;; live bridge round-trip instead of erroring. Bound to THIS session.
    (let ((mk (and (find-package :limn/runtime)
                   (find-symbol "MAKE-MINIBUFFER-READER" :limn/runtime)))
          (slot (and (find-package :limn/cmd)
                     (find-symbol "*MINIBUFFER-READ*" :limn/cmd))))
      (when (and mk slot)
        (setf (symbol-value slot) (funcall mk s))))
    ;; Load user init.lisp (SPEC §9.3) AFTER the framework's defaults
    ;; are in place — so user bindings / commands override, rather than
    ;; being clobbered by them. Errors propagate: a broken init.lisp
    ;; should not silently leave the user with a half-configured session
    ;; (multi-pdf-and-init G6 pins this contract).  Drivers that
    ;; intentionally write broken init files must wrap start-session
    ;; with handler-case themselves.
    (let ((load-init (and (find-package :limn/runtime)
                          (find-symbol "LOAD-INIT-FILE" :limn/runtime))))
      (when load-init
        (let ((loaded (funcall load-init)))
          (when loaded
            (format t "~&;; loaded init: ~a~%" loaded)))))
    ;; v0.33b: wire-backed cursor I/O. Modules like limn/mark, limn/region,
    ;; limn/kill, limn/isearch declare *buffer-cursor-fn* / *buffer-set-
    ;; cursor-fn* vtables defaulting to no-ops; their real wire path is
    ;; buffer/cursor-get / buffer/cursor-set. Install live bindings now so
    ;; downstream callers (update-region-overlay, deactivate-mark, etc.)
    ;; see actual cursor positions.
    (%install-cursor-vtables)
    ;; v0.37 §E v2 — mirror limn/log:message into the C++ *messages*
    ;; GapBuffer per-message so `buffer/text :buffer-id "*messages*"`
    ;; stays in sync with the Lisp ring. Installed AFTER cursor vtables
    ;; (no dependency, but groups with other wire installers).
    (%install-log-wire-sender)
    ;; v0.39 B10 — install limn/file text-engine bridge.  Pre-v0.39 the
    ;; text path of find-file never told C++ anything, so xdotool keys
    ;; routed to the wrong widget and self-insert vanished.  See
    ;; backend/limn-file.lisp commentary above the hook defvars.
    (%install-file-text-bridge)
    ;; Spawn a background pump thread so events the user generates in the
    ;; Qt window fire their bindings while the REPL is at the prompt. Tests
    ;; with mock clients can call STOP-PUMP-THREAD if they don't want it.
    (%call :limn/dispatch '#:start-pump-thread s)
    *session*))

(defun %install-log-wire-sender ()
  "Mirror every limn/log:message into the C++ *messages* GapBuffer via
   the message/log wire command, so `buffer/text :buffer-id \"*messages*\"`
   stays in sync with the Lisp ring.

   Per-message, fire-and-forget (notify, not call): no round-trip wait;
   no log entry should ever block. NIL'd on STOP so post-stop log calls
   don't try to use a dead session.

   Re-entrancy guard: the sender NILs *log-wire-sender* for its own
   duration, so if dispatch internals were ever to log, we wouldn't
   recurse. The message handler also swallows sender errors, so a wire
   failure cannot corrupt the ring."
  (setf limn/log:*log-wire-sender*
        (lambda (rec)
          (let* ((time  (limn/log:log-record-time  rec))
                 (level (limn/log:log-record-level rec))
                 (ns    (limn/log:log-record-ns    rec))
                 (text  (limn/log:log-record-text  rec)))
            (when (and text (plusp (length text)))
              (multiple-value-bind (s m h) (decode-universal-time time)
                (let* ((lv-str (case level
                                 (:debug "DEBUG")
                                 (:info  "INFO ")
                                 (:warn  "WARN ")
                                 (:error "ERROR")
                                 (t      (string level))))
                       (ns-str (cond ((null ns)        "default")
                                     ((stringp ns)     ns)
                                     ((symbolp ns)     (string-downcase
                                                        (symbol-name ns)))
                                     (t                (princ-to-string ns))))
                       (formatted (format nil "[~2,'0D:~2,'0D:~2,'0D ~A ~A] ~A"
                                          h m s lv-str ns-str text))
                       (limn/log:*log-wire-sender* nil))
                  (handler-case (notify "message/log" :|text| formatted)
                    (error () nil)))))))))

(defun %install-cursor-vtables ()
  "Bind every package's *buffer-cursor-fn* / *buffer-set-cursor-fn* to a
   wire round-trip via buffer/cursor-get / buffer/cursor-set. Modules that
   declare these vtables: limn/mark, limn/region, limn/kill, limn/isearch.
   Safe to call repeatedly — idempotent."
  (let ((get-fn (lambda (bid)
                  (or (ignore-errors
                        (let ((r (call "buffer/cursor-get" :|buffer-id| bid)))
                          (and (eq (getf r :|ok|) t)
                               (getf (getf r :|data|) :|offset|))))
                      0)))
        (set-fn (lambda (bid off)
                  (ignore-errors
                    (call "buffer/cursor-set" :|buffer-id| bid :|offset| off))
                  off)))
    (dolist (pkg '(#:limn/mark #:limn/region #:limn/kill #:limn/isearch))
      (let ((p (find-package pkg)))
        (when p
          (let ((g (find-symbol "*BUFFER-CURSOR-FN*"     p))
                (s (find-symbol "*BUFFER-SET-CURSOR-FN*" p)))
            (when (and g (boundp g)) (set g get-fn))
            (when (and s (boundp s)) (set s set-fn))))))))

(defun %install-file-text-bridge ()
  "Bind limn/file:*open-text-engine-fn* / *fetch-wire-content-fn* to
   real-wire implementations.  Decoupled from limn/file so unit tests
   keep their no-op defaults (which the with-file-env fixture
   re-binds).  Idempotent — safe to call from every limn:start.

   *open-text-engine-fn* path content
     1. bridge/engine-load engine=text → fresh C++ text_buffers tid
     2. if PATH names an existing file: buffer/load-file to populate
        the GapBuffer and register buffer_paths[tid] for buffer/save
     3. cache tid in limn/text:*current-text-buffer* (the self-insert
        hot path uses this; the buffer-opened pump-thread event also
        sets it, but synchronously now avoids a race window)
     4. activate text-mode on w1's mode-buffer so %dispatch-key
        routes printable keys into self-insert-command
     5. return tid (or NIL on any wire failure — caller stays usable
        as a pure-Lisp fbuf even without C++)"
  (let ((open-fn
          (lambda (path content)
            (declare (ignore content))
            (ignore-errors
              (let* ((r (call "bridge/engine-load"
                              :|win-id| "w1" :|engine| "text"
                              :|path| (or path "")))
                     (ok (eq (getf r :|ok|) t))
                     (tid (and ok (getf (getf r :|data|) :|buffer-id|))))
                (when (and tid (stringp path) (plusp (length path)))
                  ;; buffer/load-file fails on non-existent files; B8
                  ;; lets find-file proceed for new files, so swallow.
                  (ignore-errors
                    (call "buffer/load-file"
                          :|buffer-id| tid :|path| path)))
                (when tid
                  ;; Sync limn/text cache up-front; the async
                  ;; event/buffer-opened hook does the same but the
                  ;; pump thread may not have processed it yet by the
                  ;; time the driver fires its first xdotool key.
                  (let* ((tpkg (find-package '#:limn/text))
                         (sym  (and tpkg (find-symbol "*CURRENT-TEXT-BUFFER*"
                                                       tpkg))))
                    (when (and sym (boundp sym))
                      (set sym tid)))
                  ;; Activate text-mode on w1's mode-buffer.
                  (let* ((rt (find-package '#:limn/runtime))
                         (mb-fn (and rt (find-symbol "MODE-BUFFER-FOR-WINDOW"
                                                      rt))))
                    (when (and mb-fn (fboundp mb-fn))
                      (let ((mb (funcall (symbol-function mb-fn) "w1"))
                            (sym-tm (find-symbol "TEXT-MODE" :cl-user)))
                        (when (and mb sym-tm)
                          (ignore-errors
                            (limn/mode:activate mb sym-tm)))))))
                tid))))
        (fetch-fn
          (lambda (wire-id)
            (ignore-errors
              (let* ((r (call "buffer/text" :|buffer-id| wire-id))
                     (ok (eq (getf r :|ok|) t)))
                (and ok (getf (getf r :|data|) :|text|))))))
        ;; v0.39 W17 — switch the visible window to an already-open
        ;; buffer.  Called by limn/file:find-file when the path is
        ;; already cached in *by-path*.  Also activates text-mode on
        ;; the mode-buffer + caches *current-text-buffer* so the
        ;; next keystroke routes self-insert/yank/kill to this buf.
        (show-fn
          (lambda (wire-id)
            (ignore-errors
              (call "buffer/show" :|buffer-id| wire-id :|win-id| "w1")
              (let* ((tpkg (find-package '#:limn/text))
                     (sym  (and tpkg (find-symbol "*CURRENT-TEXT-BUFFER*"
                                                   tpkg))))
                (when (and sym (boundp sym))
                  (set sym wire-id)))
              (let* ((rt (find-package '#:limn/runtime))
                     (mb-fn (and rt (find-symbol "MODE-BUFFER-FOR-WINDOW"
                                                  rt))))
                (when (and mb-fn (fboundp mb-fn))
                  (let ((mb (funcall (symbol-function mb-fn) "w1"))
                        (sym-tm (find-symbol "TEXT-MODE" :cl-user)))
                    (when (and mb sym-tm)
                      (ignore-errors
                        (limn/mode:activate mb sym-tm))))))))))
    (setf limn/file:*open-text-engine-fn*   open-fn
          limn/file:*fetch-wire-content-fn* fetch-fn
          limn/file:*show-buffer-fn*        show-fn)))

(defun stop ()
  (when *session*
    (ignore-errors (%call :limn/dispatch '#:stop-pump-thread *session*))
    (let ((c (%call :limn/dispatch '#:session-client *session*)))
      (ignore-errors (%call :limn/client '#:disconnect c)))
    (setf *session* nil *running* nil)
    ;; Drop the log wire sender — without a session, notify would error.
    ;; Post-stop log calls fall back to ring-only (NIL sender = no-op).
    (setf limn/log:*log-wire-sender* nil)
    (limn/keys:set-key-prefix '()))
  t)

;;; ── public messaging API ───────────────────────────────────────────────

(defun call (cmd &rest args)
  "Synchronous call. Returns the decoded response plist."
  (unless *session* (error "limn: not started"))
  (let ((resp (apply (%sym :limn/dispatch '#:call) *session* cmd args)))
    ;; v0.33b: synchronous-registration shim. limn/overlays' default
    ;; *buffer-kind-fn* queries limn/buffer to route text-buffer overlays
    ;; through the "text-range" wire type. The buffer-opened event handler
    ;; populates limn/buffer too but fires async — by the time callers
    ;; chain view/overlays after bridge/engine-load, the registration may
    ;; not have happened yet. Mirror it here from the response.
    (when (and (equal cmd "bridge/engine-load")
               (eq (getf resp :|ok|) t))
      (let* ((data   (getf resp :|data|))
             (bid    (and data (getf data :|buffer-id|)))
             (engine (getf args :|engine|))
             (path   (getf args :|path|))
             (pkg    (find-package '#:limn/buffer))
             (reg    (and pkg (find-symbol "REGISTER" pkg))))
        (when (and bid engine reg (fboundp reg))
          (ignore-errors (funcall reg bid (or path "") engine)))))
    resp))

(defun notify (cmd &rest args)
  "Fire-and-forget."
  (unless *session* (error "limn: not started"))
  (apply (%sym :limn/dispatch '#:notify) *session* cmd args))

(defun pump ()
  "Drain available messages without blocking."
  (unless *session* (error "limn: not started"))
  (funcall (%sym :limn/dispatch '#:pump) *session*))

(defun run ()
  "Block forever, dispatching incoming events. Returns when the peer closes."
  (unless *session* (error "limn: not started"))
  (setf *running* t)
  (let ((blocking (%sym :limn/client '#:read-line-blocking))
        (client   (%call :limn/dispatch '#:session-client *session*))
        (classify (%sym :limn/dispatch '#:classify)))
    ;; classify isn't exported — use pump-style read via decode helpers
    (declare (ignore classify))
    (loop while *running* do
      (let ((line (funcall blocking client)))
        (when (eq line :eof) (setf *running* nil) (return))
        ;; Feed the line back through dispatch by re-injecting: we re-use
        ;; pump's machinery by writing into a tiny replay buffer. Simpler:
        ;; let pump drain whatever else is buffered now.
        (let* ((decode (%sym :limn/bridge '#:decode-message))
               (parsed (handler-case (funcall decode line) (error () nil))))
          (when parsed
            (cond
              ((getf parsed :|event|)
               (let ((hook-of (%sym :limn/dispatch '#:event-hook-name))
                     (run-hook (%sym :limn/hooks '#:run-hook)))
                 (when (and hook-of run-hook)
                   (funcall run-hook
                            (funcall hook-of (getf parsed :|event|))
                            parsed))))
              ((getf parsed :|id|)
               ;; Stranded response (nobody waiting). Drop quietly.
               nil))))
        (pump)))))

;;; ── keymap helpers ─────────────────────────────────────────────────────

(defun bind (spec action)
  "Bind a key sequence (e.g. \"C-x C-f\") to ACTION.

   ACTION can be:
     - a function of one argument (the originating key-event plist),
       bound directly
     - a command-name SYMBOL — wrapped in a call-interactively closure
       AND registered in limn/introspect's reverse table so
       (where-is-command sym) can find this binding. The command must
       already be defined (defcommand) — error otherwise.

   Lambda bindings are invisible to where-is-command (same limit as
   Emacs). Bind a symbol when you want discoverability."
  (unless *global-keymap*
    (setf *global-keymap* (%call :limn/keys '#:make-keymap)))
  (let ((final-action
          (cond
            ((symbolp action)
             (let* ((cmd-pkg (find-package :limn/cmd))
                    (find-cmd (and cmd-pkg (find-symbol "FIND-COMMAND" cmd-pkg)))
                    (call-int (and cmd-pkg (find-symbol "CALL-INTERACTIVELY"
                                                          cmd-pkg))))
               (unless (and find-cmd (funcall find-cmd action))
                 (error "limn:bind: ~s is not a defined command" action))
               ;; Register the binding for where-is-command.
               (let* ((isp-pkg (find-package :limn/introspect))
                      (register (and isp-pkg
                                     (find-symbol "REGISTER-BINDING"
                                                  isp-pkg))))
                 (when register
                   (funcall register action *global-keymap* spec)))
               ;; Wrap so the key-event signature still matches.
               (lambda (ev) (declare (ignore ev))
                 (handler-case (funcall call-int action)
                   ;; minibuffer-cancelled is the intended outcome of a
                   ;; user-pressed C-g — don't let it propagate out of
                   ;; the binding and pollute *error-output*.
                   (error (e)
                     (let ((mc (and (find-package :limn/runtime)
                                    (find-symbol "MINIBUFFER-CANCELLED"
                                                 :limn/runtime))))
                       (if (and mc (typep e mc))
                           nil
                           (signal e))))))))
            (t action))))
    (%call :limn/keys '#:define-key *global-keymap* spec final-action)))

(defun unbind (spec)
  (when *global-keymap*
    (%call :limn/keys '#:undefine-key *global-keymap* spec)))

;;; ── event hook helpers ─────────────────────────────────────────────────

(defun on-event (event-type fn)
  "Register FN as a handler for events of EVENT-TYPE (a string like
   \"buffer-opened\"). FN receives the event plist."
  (let ((add (%sym :limn/hooks '#:add-hook))
        (hook-of (%sym :limn/dispatch '#:event-hook-name)))
    (funcall add (funcall hook-of event-type) fn)))

(defun off-event (event-type fn)
  (let ((remove (%sym :limn/hooks '#:remove-hook))
        (hook-of (%sym :limn/dispatch '#:event-hook-name)))
    (funcall remove (funcall hook-of event-type) fn)))

;;; ── convenience wrappers ───────────────────────────────────────────────

(defun open-buffer (path &key (engine "mupdf") (win-id "w1"))
  "Load a buffer into a window via bridge/engine-load. WIN-ID defaults to
   \"w1\", the always-present default window created on startup."
  (call "bridge/engine-load"
        :|engine| engine :|path| path :|win-id| win-id))

(defun close-buffer (buffer-id)
  (call "buffer/close" :|buffer-id| buffer-id))

(defun view-set (win-id &rest fields)
  (apply #'call "view/set" :|win-id| win-id fields))

(defun view-get (win-id)
  (call "view/get" :|win-id| win-id))

(defun win-list ()
  (call "bridge/win-list"))

(defun capabilities ()
  (call "bridge/capabilities"))
