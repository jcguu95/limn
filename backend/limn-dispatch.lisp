;;;; limn-dispatch — protocol-level glue between client I/O and the rest.
;;;;
;;;; Owns:
;;;;   - JSON-decoding lines pulled from a limn/client
;;;;   - matching response messages to pending requests (id → response slot)
;;;;   - firing limn/hooks event-* handlers for unsolicited events
;;;;   - a synchronous `call` interface for one-shot request/response
;;;;
;;;; This module does NOT own the socket — it takes one. That lets tests
;;;; drive it with a fake client (anything that provides the four-function
;;;; surface: write-line!, try-read-line, read-line-blocking, connected-p).
;;;;
;;;; Threading model: single-threaded. `pump` drains whatever lines have
;;;; arrived and returns. `call` writes a request then loops pumping +
;;;; blocking-reading until the matching id shows up or timeout expires.

(defpackage #:limn/dispatch
  (:use #:cl)
  (:export #:make-session #:make-session-for
           #:session-p #:session-client
           #:pump #:call #:notify
           #:event-hook-name
           #:install-fd-handler #:remove-fd-handler
           #:start-pump-thread #:stop-pump-thread
           #:*request-timeout*))

(in-package #:limn/dispatch)

(defvar *request-timeout* 10.0
  "Default seconds to wait for a response.")

(defstruct (session (:conc-name session-) (:copier nil))
  client
  ;; I/O vtable — pulled from CLIENT at construction time, or supplied
  ;; directly by tests / alternative transports. Each is a function of
  ;; one argument (the client) except WRITE which takes (client line).
  write-fn        ; (client line) → t
  try-read-fn     ; (client)      → string | nil | :eof
  blocking-fn     ; (client)      → string | :eof
  (counter 0)
  ;; pending-id → :waiting (sentinel) or the decoded response plist
  (pending (make-hash-table :test 'equal))
  ;; threading: when running interactively we spawn a background pump
  ;; thread so events fire while the REPL is idle. Two mutexes serialise
  ;; the socket; the thread itself is recorded so STOP can join it.
  (write-mutex (sb-thread:make-mutex :name "limn-write"))
  pump-thread)

(defun %resolve-io (client)
  "If CLIENT is a real limn/client:client, look up the symbols. Returns
   (values write try-read blocking) or NIL if the package isn't loaded."
  (let ((pkg (find-package :limn/client)))
    (when pkg
      (values (find-symbol "WRITE-LINE!"        pkg)
              (find-symbol "TRY-READ-LINE"      pkg)
              (find-symbol "READ-LINE-BLOCKING" pkg)))))

(defun make-session-for (client &key write-fn try-read-fn blocking-fn)
  "Construct a session, defaulting the I/O vtable from limn/client if not
   supplied. Tests can pass explicit fns to mock the transport."
  (multiple-value-bind (w r b) (%resolve-io client)
    (make-session :client client
                  :write-fn    (or write-fn   w)
                  :try-read-fn (or try-read-fn r)
                  :blocking-fn (or blocking-fn b))))

;;; ── id allocation ───────────────────────────────────────────────────────

(defun next-id (sess)
  (format nil "r~d" (incf (session-counter sess))))

;;; ── encode/decode shims (defer to limn/bridge if loaded) ───────────────
;;;
;;; We don't (use) limn/bridge to avoid a hard dependency for unit tests of
;;; the dispatch logic itself; instead we look the symbols up at call time.

(defun %encode (v)
  (funcall (or (find-symbol "ENCODE-MESSAGE" :limn/bridge)
               (error "limn/bridge not loaded — cannot encode"))
           v))

(defun %decode (s)
  (funcall (or (find-symbol "DECODE-MESSAGE" :limn/bridge)
               (error "limn/bridge not loaded — cannot decode"))
           s))

;;; ── I/O via the session's vtable ────────────────────────────────────────

(defun client-write-line (sess line)
  (funcall (session-write-fn sess) (session-client sess) line))
(defun client-try-read (sess)
  (funcall (session-try-read-fn sess) (session-client sess)))
(defun client-blocking (sess)
  (funcall (session-blocking-fn sess) (session-client sess)))

;;; ── hook integration ────────────────────────────────────────────────────

(defun event-hook-name (event-type)
  "Hook name used to register handlers for an event of type EVENT-TYPE.
   Hooks are keyed by string so callers can register without interning."
  (concatenate 'string "event/" event-type))

(defun fire-event (ev)
  "Dispatch an event plist via limn/hooks. Silently no-ops if hooks isn't loaded."
  (let ((run (find-symbol "RUN-HOOK" :limn/hooks))
        (etype (getf ev :|event|)))
    (when (and run etype)
      (funcall run (event-hook-name etype) ev)
      ;; Hooks fire from a background thread; without an explicit flush,
      ;; their (format t ...) output sits in SBCL's stdout buffer until
      ;; the user types something at the REPL. Force-output so prints from
      ;; key bindings appear immediately.
      (handler-case (force-output *standard-output*) (error () nil)))))

;;; ── classify one incoming message ──────────────────────────────────────

(defun classify (sess parsed)
  "Stash a response in PENDING, or fire EVENT hooks, or drop."
  (cond
    ((null parsed) nil)
    ;; response: must have an id we're waiting for
    ((getf parsed :|id|)
     (let ((id (getf parsed :|id|)))
       (when (nth-value 1 (gethash id (session-pending sess)))
         (setf (gethash id (session-pending sess)) parsed))))
    ;; event: dispatch by type
    ((getf parsed :|event|)
     (fire-event parsed))))

;;; ── pump: drain any ready lines, returning count processed ────────────

(defun pump (sess)
  "Read & dispatch every line currently buffered on the socket. Non-blocking.
   Returns the number of messages processed (or :eof if peer closed)."
  (let ((n 0))
    (loop
      (let ((line (client-try-read sess)))
        (cond
          ((null line)       (return n))
          ((eq line :eof)    (return :eof))
          (t (let ((parsed (handler-case (%decode line)
                             (error () nil))))
               (classify sess parsed)
               (incf n))))))))

;;; ── synchronous call ───────────────────────────────────────────────────

(defun call (sess cmd &rest args &key (timeout *request-timeout*) &allow-other-keys)
  "Send CMD (a string like \"view/get\") with ARGS (a plist of keyword
   keys → values) and block until the matching response arrives.
   Returns the decoded response plist; signals on timeout."
  (let* ((clean-args (loop for (k v) on args by #'cddr
                           unless (eq k :timeout)
                             collect k and collect v))
         (id (next-id sess))
         (req (list* :|id| id :|cmd| cmd clean-args)))
    ;; Register pending BEFORE we send, so a fast reply can't race us.
    (setf (gethash id (session-pending sess)) :waiting)
    (sb-thread:with-mutex ((session-write-mutex sess))
      (client-write-line sess (%encode req)))
    (let ((deadline (+ (get-internal-real-time)
                       (* timeout internal-time-units-per-second)))
          (pump-thread (session-pump-thread sess))
          (i-am-pump   (and (session-pump-thread sess)
                            (eq sb-thread:*current-thread*
                                (session-pump-thread sess)))))
      (loop
        (let ((slot (gethash id (session-pending sess))))
          (unless (eq slot :waiting)
            (remhash id (session-pending sess))
            (return slot)))
        (when (> (get-internal-real-time) deadline)
          (remhash id (session-pending sess))
          (error "limn/dispatch: timeout (~as) waiting for response to ~a"
                 timeout cmd))
        (cond
          ;; Most common case: another thread is pumping the socket. Just
          ;; sleep briefly; it'll fill our pending entry.
          ((and pump-thread (not i-am-pump))
           (sleep 0.01))
          ;; We ARE the pump thread (a hook called us). The outer pump loop
          ;; is paused inside this stack frame, so nobody else is going to
          ;; drain the socket — we have to do it ourselves.
          (i-am-pump
           (let ((line (client-blocking sess)))
             (cond
               ((eq line :eof)
                (remhash id (session-pending sess))
                (error "limn/dispatch: peer closed while waiting for ~a" cmd))
               (t (classify sess
                            (handler-case (%decode line) (error () nil)))))))
          ;; No pump thread at all (unit tests with mock clients): inline
          ;; blocking read, same as the original single-threaded design.
          (t
           (pump sess)
           (let ((slot (gethash id (session-pending sess))))
             (when (eq slot :waiting)
               (let ((line (client-blocking sess)))
                 (cond
                   ((eq line :eof)
                    (remhash id (session-pending sess))
                    (error "limn/dispatch: peer closed while waiting for ~a" cmd))
                   (t (classify sess
                                (handler-case (%decode line) (error () nil))))))))))))))

;;; ── fd-handler: drain socket while the REPL is idle ───────────────────
;;;
;;; Without this, key events pushed by the frontend pile up in the socket
;;; buffer until the user manually calls PUMP. With it, SBCL's serve-event
;;; loop calls our handler whenever the fd is readable — which is exactly
;;; what we want: while at the REPL prompt, while inside CALL waiting for
;;; a response, anywhere serve-event runs.

(defvar *active-fd-handlers* (make-hash-table :test 'eql)
  "Map from session → SBCL fd-handler object, so we can uninstall.")

(defun install-fd-handler (sess)
  "Hook the session's socket into sb-sys:serve-event. Idempotent."
  (remove-fd-handler sess)
  (let* ((client (session-client sess))
         (stream (and client (find-symbol "CLIENT-STREAM" :limn/client)
                      (funcall (find-symbol "CLIENT-STREAM" :limn/client)
                               client))))
    (unless stream (return-from install-fd-handler nil))
    (let* ((fd (sb-sys:fd-stream-fd stream))
           (handler (sb-sys:add-fd-handler
                     fd :input
                     (lambda (descriptor)
                       (declare (ignore descriptor))
                       ;; Drain everything available without blocking.
                       (handler-case (pump sess)
                         (error (e)
                           (format *error-output*
                                   "[fd-handler] ~a~%" e)))))))
      (setf (gethash sess *active-fd-handlers*) handler)
      handler)))

(defun remove-fd-handler (sess)
  (let ((h (gethash sess *active-fd-handlers*)))
    (when h
      (handler-case (sb-sys:remove-fd-handler h) (error () nil))
      (remhash sess *active-fd-handlers*))))

;;; ── pump thread: drain socket continuously in the background ─────────
;;;
;;; In an interactive SBCL session, while the user is at the REPL prompt
;;; SBCL is blocked on stdin and does NOT run sb-sys:serve-event — so the
;;; fd-handler above never fires. Without a background thread to drain the
;;; socket, key events the user generates in the Qt window pile up until
;;; the next manual (pump). The pump thread fixes that.
;;;
;;; Threading rules:
;;;   - The pump thread is the only continuous reader.
;;;   - Writes happen anywhere, serialised by session-write-mutex.
;;;   - Hooks fire from the pump thread. If a hook calls CALL, that call
;;;     detects "I'm the pump thread" and inlines its own blocking read
;;;     (see CALL's i-am-pump branch above).

(defun start-pump-thread (sess)
  "Spawn a background thread that pumps SESS's socket. Idempotent."
  (when (and (session-pump-thread sess)
             (sb-thread:thread-alive-p (session-pump-thread sess)))
    (return-from start-pump-thread (session-pump-thread sess)))
  (setf (session-pump-thread sess)
        (sb-thread:make-thread
         (lambda ()
           (loop while (session-client sess) do
             (handler-case
                 (let ((r (pump sess)))
                   (when (eq r :eof) (return)))
               (error (e)
                 (format *error-output* "[pump-thread] ~a~%" e)))
             (sleep 0.03)))
         :name "limn-pump")))

(defun stop-pump-thread (sess)
  (let ((th (session-pump-thread sess)))
    (when th
      (setf (session-pump-thread sess) nil)
      (when (sb-thread:thread-alive-p th)
        (handler-case (sb-thread:terminate-thread th) (error () nil)))
      (handler-case (sb-thread:join-thread th :timeout 0.5) (error () nil)))))

;;; ── notify: fire-and-forget (no response expected) ─────────────────────

(defun notify (sess cmd &rest args)
  "Send a request without waiting for a response. Useful for events that
   the frontend doesn't ack."
  (let* ((id (next-id sess))
         (req (list* :|id| id :|cmd| cmd args)))
    (sb-thread:with-mutex ((session-write-mutex sess))
      (client-write-line sess (%encode req)))
    id))
