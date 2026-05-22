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

(defvar *key-prefix* '()
  "Accumulated key prefix while walking a multi-key sequence.")

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

(defun %event-key-spec (ev)
  "Turn a `key` event plist (key + mods array) into an Emacs-style spec.
   Modifiers are mapped: ctrl → C, alt/meta → M, shift → S, super → s.
   e.g. {key:\"d\", mods:[\"ctrl\"]} → \"C-d\"."
  (let* ((key  (getf ev :|key|))
         (mods (getf ev :|mods|)))
    (cond
      ((null mods) key)
      (t (format nil "~{~a-~}~a"
                 (mapcar #'%mod-letter mods) key)))))

(defun %dispatch-key (ev)
  "Hook handler: receive a key event, walk the keymap, invoke when matched."
  (let* ((spec (%event-key-spec ev))
         (km   *global-keymap*)
         (lookup-seq (%sym :limn/keys '#:lookup-sequence)))
    (unless (and km lookup-seq) (return-from %dispatch-key nil))
    (let* ((sequence (append *key-prefix* (list spec)))
           (result (funcall lookup-seq km sequence)))
      (cond
        ((eq result :prefix)
         (setf *key-prefix* sequence))
        ((functionp result)
         (setf *key-prefix* '())
         (handler-case (funcall result ev)
           (error (e) (format *error-output*
                              "limn: binding for ~{~a~^ ~} errored: ~a~%"
                              sequence e))))
        (t
         (setf *key-prefix* '()))))))

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

;;; ── start / stop ───────────────────────────────────────────────────────

(defun start (socket-path)
  "Open a connection to SOCKET-PATH and create a session."
  (when *session* (stop))
  (let* ((c (%call :limn/client '#:connect socket-path))
         (s (%call :limn/dispatch '#:make-session-for c)))
    (setf *session* s)
    (unless *global-keymap*
      (setf *global-keymap* (%call :limn/keys '#:make-keymap)))
    (%install-key-handler)
    ;; Spawn a background pump thread so events the user generates in the
    ;; Qt window fire their bindings while the REPL is at the prompt. Tests
    ;; with mock clients can call STOP-PUMP-THREAD if they don't want it.
    (%call :limn/dispatch '#:start-pump-thread s)
    *session*))

(defun stop ()
  (when *session*
    (ignore-errors (%call :limn/dispatch '#:stop-pump-thread *session*))
    (let ((c (%call :limn/dispatch '#:session-client *session*)))
      (ignore-errors (%call :limn/client '#:disconnect c)))
    (setf *session* nil *running* nil *key-prefix* '()))
  t)

;;; ── public messaging API ───────────────────────────────────────────────

(defun call (cmd &rest args)
  "Synchronous call. Returns the decoded response plist."
  (unless *session* (error "limn: not started"))
  (apply (%sym :limn/dispatch '#:call) *session* cmd args))

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
  "Bind a key sequence (e.g. \"C-x C-f\") to ACTION (a function of one
   argument: the originating key event plist)."
  (unless *global-keymap*
    (setf *global-keymap* (%call :limn/keys '#:make-keymap)))
  (%call :limn/keys '#:define-key *global-keymap* spec action))

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
