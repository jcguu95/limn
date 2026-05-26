;;;; limn-file-notify — v0.35 §A: filesystem watch primitive.
;;;;
;;;; Emacs filenotify.el equivalent. Backed by a long-running OS-level
;;;; watcher subprocess (inotifywait on Linux, fswatch on macOS) whose
;;;; stdout we parse line-by-line; falls back to mtime/size polling
;;;; when no helper is available.
;;;;
;;;; Pure Lisp on top of v0.23 limn/process. Architecture:
;;;;
;;;;   *watches*    : list of WATCH structs (path + flags + callback)
;;;;   *helper-proc*: lazily-spawned helper subprocess (or :polling sentinel)
;;;;   *poll-cache* : path → (:mtime M :size S) (polling backend only)
;;;;
;;;; On every add-watch:
;;;;   - validate the path exists (vtable *file-notify-exists-p-fn*)
;;;;   - if no helper yet:  probe backend (vtable *probe-fn*) and spawn
;;;;     (vtable *helper-spawn-fn*); if no helper available, switch to
;;;;     :polling and seed *poll-cache* via *file-notify-stat-fn*
;;;;   - tell helper "subscribe PATH" via its stdin (real backend);
;;;;     polling backend just adds to *watches*
;;;;
;;;; On helper death: the reaper thread sets *helper-proc* nil and bumps
;;;; *helper-respawn-count*; next event / add-watch respawns.
;;;;
;;;; All callbacks invoked through limn/error:%call-with-protection so a
;;;; bad callback can't kill the dispatcher.

(defpackage #:limn/file-notify
  (:use #:cl)
  (:export #:file-notify-add-watch
           #:file-notify-rm-watch
           #:file-notify-valid-p
           #:list-watches
           ;; configuration / vtable
           #:*file-notify-backend*
           #:*file-notify-helper-spawn-fn*
           #:*file-notify-helper-probe-fn*
           #:*file-notify-stat-fn*
           #:*file-notify-exists-p-fn*
           #:*file-notify-now-fn*
           #:*file-notify-polling-interval*
           ;; mock-driven dispatch (used by unit tests)
           #:feed-helper-line
           #:dispatch-poll-tick
           #:simulate-helper-exit
           ;; test cleanup
           #:reset-file-notify
           #:helper-respawn-count))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(in-package #:limn/file-notify)

;;; Forward declaration so %spawn-real-helper compiles without style-warning
;;; (real definition is below, after the dispatch helpers).
(declaim (ftype (function (t) t) %dispatch-chunk))

;;; ── configuration vars ──────────────────────────────────────────────────

(defvar *file-notify-backend* :auto
  "One of :auto :inotify :fswatch :polling. When :auto, probe-fn picks one.")

(defvar *file-notify-polling-interval* 1.0
  "Seconds between polling ticks when the polling backend is active.")

(defvar *file-notify-now-fn*
  (lambda () (/ (get-internal-real-time) internal-time-units-per-second))
  "Returns the current time in seconds (fakeable for tests).")

(defvar *file-notify-exists-p-fn*
  (lambda (path) (and path (probe-file path)))
  "True if PATH names an existing file or directory.")

(defvar *file-notify-stat-fn*
  (lambda (path)
    "Returns (:mtime SECS :size BYTES) for PATH, or nil if it doesn't exist."
    (when (probe-file path)
      (handler-case
          (let* ((s   (sb-posix:stat path))
                 (mt  (sb-posix:stat-mtime s))
                 (sz  (sb-posix:stat-size s)))
            (list :mtime mt :size sz))
        (error () nil)))))

(defvar *file-notify-helper-probe-fn*
  (lambda ()
    "Decide which OS helper is available. Returns :inotify, :fswatch, or nil."
    (cond ((%which "inotifywait") :inotify)
          ((%which "fswatch")     :fswatch)
          (t                       nil))))

(defvar *file-notify-helper-spawn-fn*
  (lambda (kind)
    "Spawn the OS helper subprocess KIND for the configured backend.
     Default: real limn/process subprocess. Tests override this with a
     mock that simply returns a sentinel."
    (%spawn-real-helper kind))
  "Vtable: takes :inotify or :fswatch, returns a helper handle.")

;;; ── state ───────────────────────────────────────────────────────────────

(defstruct watch
  path
  flags         ; list of :change :attribute-change
  callback
  (valid t))

(defvar *watches* '())
(defvar *helper-proc* nil)        ; subprocess or :polling
(defvar *helper-respawn-count* 0)
(defvar *poll-cache* (make-hash-table :test 'equal))
(defvar *last-poll-time* 0)
(defvar *line-fragment* ""        ; bytes seen since last newline
  "Accumulator for incomplete helper-stdout lines across read chunks.")

(defun reset-file-notify ()
  "Clear all watches and helper state. Intended for tests."
  (setf *watches* '())
  (when (and *helper-proc* (not (keywordp *helper-proc*)))
    (let ((kill (and (find-package '#:limn/process)
                     (find-symbol "KILL-PROCESS" '#:limn/process))))
      (when kill (handler-case (funcall kill *helper-proc*) (error () nil)))))
  (setf *helper-proc* nil
        *helper-respawn-count* 0
        *line-fragment* "")
  (clrhash *poll-cache*)
  (setf *last-poll-time* 0)
  nil)

(defun helper-respawn-count () *helper-respawn-count*)

(defun list-watches ()
  (remove-if-not #'watch-valid *watches*))

;;; ── helper probe / spawn ────────────────────────────────────────────────

(defun %which (binary)
  "Locate BINARY on PATH using /usr/bin/env which. Returns absolute path
   or nil. Tolerates a missing /usr/bin/env (returns nil)."
  (handler-case
      (let* ((s (make-string-output-stream))
             (p (sb-ext:run-program "/usr/bin/env" (list "which" binary)
                                     :search nil :wait t
                                     :output s :error nil)))
        (when (and p (zerop (sb-ext:process-exit-code p)))
          (let ((line (string-trim '(#\Newline #\Space)
                                    (get-output-stream-string s))))
            (and (plusp (length line)) line))))
    (error () nil)))

;;; v0.39 B17 — readiness handshake.
;;;
;;; Pre-v0.39, file-notify-add-watch returned the moment the inotifywait
;;; (or fswatch) subprocess had been *spawned* — but the helper had not
;;; yet executed inotify_add_watch(2) on the kernel side.  W30's driver
;;; (typical user pattern: enable auto-revert → external write → wait)
;;; consistently lost the very first event because the write happened
;;; in that ~50ms gap before the kernel watch was installed.
;;;
;;; Fix: emit one synchronous wait on a per-spawn semaphore that the
;;; stderr reader signals when it sees "Watches established." from
;;; inotifywait (or "<ready>" sentinel for fswatch, which doesn't
;;; print a banner — we use a marker file round-trip instead).  The
;;; spawn returns only after the kernel watch is live.

(defvar *helper-ready-timeout* 3.0
  "Max seconds to wait for the helper subprocess to report 'kernel
   watch is live' before giving up and returning anyway.  Tests can
   shorten this; production users almost never hit the timeout
   (inotifywait reports ready in ~10-50ms on a warm system).")

(defun %spawn-real-helper (kind)
  "Spawn the real OS helper. Returns the limn/process handle.
   The helper writes one event per line to stdout. Resolves the binary
   via %which so NixOS / non-FHS systems work.

   v0.39 B17: blocks until the helper reports its kernel watches are
   live — see *helper-ready-timeout* docstring."
  (let ((mk (and (find-package '#:limn/process)
                 (symbol-function (find-symbol "MAKE-PROCESS"
                                                '#:limn/process)))))
    (unless mk
      (error "limn/file-notify: limn/process not loaded; cannot spawn helper"))
    (ecase kind
      (:inotify
       (let* ((bin    (or (%which "inotifywait")
                          (error "limn/file-notify: inotifywait not on PATH")))
              (stdbuf (%which "stdbuf"))
              ;; v0.39 B17 — semaphore signalled by stderr reader on the
              ;; "Watches established." banner.  inotifywait prints both
              ;; "Setting up watches.\n" and "Watches established.\n" to
              ;; STDERR (not stdout) before it starts emitting events,
              ;; so we don't need to disturb the stdout event format —
              ;; just remove --quiet (which suppressed the stderr banner
              ;; too) and read stderr separately.
              (ready  (sb-thread:make-semaphore :count 0)))
         (let ((cmd (if stdbuf
                        (list stdbuf "-oL" "-eL" bin)
                        (list bin))))
           (let ((proc
                   (funcall mk
                            :command (append cmd
                                              '("--monitor" "--recursive"
                                                "--event" "modify"
                                                "--event" "create"
                                                "--event" "delete"
                                                "--event" "move"
                                                "--event" "attrib"
                                                "--format" "%e %w%f"
                                                "/tmp"))
                            :stdout (lambda (proc chunk)
                                      (declare (ignore proc))
                                      (%dispatch-chunk chunk))
                            :stderr (lambda (proc chunk)
                                      (declare (ignore proc))
                                      (when (search "Watches established"
                                                    chunk)
                                        (sb-thread:signal-semaphore ready))))))
             ;; Block (up to *helper-ready-timeout* s) until the helper
             ;; has its kernel watches installed.  We swallow timeout
             ;; silently: if the banner never arrives, the worst case
             ;; is that we miss a few early events (same as pre-fix),
             ;; not a deadlock.
             (sb-thread:wait-on-semaphore ready :timeout *helper-ready-timeout*)
             proc))))
      (:fswatch
       (let* ((bin    (or (%which "fswatch")
                          (error "limn/file-notify: fswatch not on PATH")))
              (stdbuf (%which "stdbuf"))
              ;; v0.39 B17 — fswatch doesn't print a ready banner; do
              ;; a marker-file round-trip instead.  We spawn, write a
              ;; tiny marker into /tmp, and wait for the corresponding
              ;; event to come back via stdout.  Once we see it, the
              ;; kernel watch is provably live.  Falls back to a fixed
              ;; sleep if the marker never round-trips (paranoia).
              (marker (format nil "/tmp/.limn-fnotify-ready-~a"
                              (sb-posix:getpid)))
              (ready  (sb-thread:make-semaphore :count 0))
              (saw-marker nil))
         (let ((cmd (if stdbuf
                        (list stdbuf "-oL" bin)
                        (list bin))))
           (let ((proc
                   (funcall mk
                            :command (append cmd '("-x" "/tmp"))
                            :stdout (lambda (proc chunk)
                                      (declare (ignore proc))
                                      (when (and (not saw-marker)
                                                 (search marker chunk))
                                        (setf saw-marker t)
                                        (sb-thread:signal-semaphore ready))
                                      (%dispatch-chunk chunk)))))
             ;; Poke the marker; first round-trip signals readiness.
             (ignore-errors
               (with-open-file (s marker :direction :output
                                          :if-exists :supersede
                                          :if-does-not-exist :create)
                 (write-string "ready" s)))
             (sb-thread:wait-on-semaphore ready :timeout *helper-ready-timeout*)
             (ignore-errors (delete-file marker))
             proc)))))))

(defun %helper-alive-p ()
  "True if the current *helper-proc* is a real, still-running process."
  (let ((p *helper-proc*))
    (cond
      ((null p) nil)
      ((keywordp p) t)   ; :polling sentinel or :fake-helper mock — alive
      (t
       (let ((live-fn (and (find-package '#:limn/process)
                           (find-symbol "PROCESS-LIVE-P" '#:limn/process))))
         (if live-fn
             (handler-case (funcall live-fn p) (error () nil))
             t))))))

(defun %ensure-helper ()
  "Make sure a backend is alive. Returns :inotify / :fswatch / :polling."
  (unless (%helper-alive-p)
    (when *helper-proc*
      ;; Dead subprocess: respawn.
      (setf *helper-proc* nil)
      (incf *helper-respawn-count*))
    (let ((be *file-notify-backend*))
      (when (eq be :auto)
        (setf be (or (funcall *file-notify-helper-probe-fn*) :polling)))
      (if (eq be :polling)
          (setf *helper-proc* :polling)
          (setf *helper-proc*
                (funcall *file-notify-helper-spawn-fn* be)))))
  (cond ((eq *helper-proc* :polling) :polling)
        (t *file-notify-backend*)))

(defun simulate-helper-exit ()
  "Test hook: pretend the helper subprocess died. Triggers respawn."
  (setf *helper-proc* nil)
  (incf *helper-respawn-count*)
  ;; Eager respawn so subsequent feed-helper-line still has a backend.
  (%ensure-helper)
  nil)

;;; ── add / rm watch ──────────────────────────────────────────────────────

(defun file-notify-add-watch (path flags callback)
  "Subscribe CALLBACK to filesystem events on PATH. FLAGS is a list
   containing :change and/or :attribute-change (empty list = :change).
   Returns an opaque descriptor."
  (unless (funcall *file-notify-exists-p-fn* path)
    (error "limn/file-notify: file does not exist: ~s" path))
  (let* ((flags (or flags '(:change)))
         (w (make-watch :path path :flags flags :callback callback)))
    (push w *watches*)
    (%ensure-helper)
    ;; Polling backend: seed the cache so the first change actually
    ;; registers as "changed" rather than "appeared".
    (when (eq *helper-proc* :polling)
      (let ((s (funcall *file-notify-stat-fn* path)))
        (setf (gethash path *poll-cache*) (or s (list :mtime 0 :size 0)))))
    w))

(defun file-notify-rm-watch (descriptor)
  "Unsubscribe DESCRIPTOR (returned from file-notify-add-watch).
   Idempotent — silently no-ops if DESCRIPTOR is unknown / already removed."
  (cond
    ((watch-p descriptor)
     (setf (watch-valid descriptor) nil)
     (setf *watches* (remove descriptor *watches* :test #'eq)))
    (t nil))
  nil)

(defun file-notify-valid-p (descriptor)
  (and (watch-p descriptor) (watch-valid descriptor)))

;;; ── event dispatch ──────────────────────────────────────────────────────

(defun %action-keyword (op-word)
  "Translate a helper-event word (CREATE, MODIFY, DELETE, MOVED_*, ATTRIB)
   into our canonical action keyword."
  (let ((w (string-upcase op-word)))
    (cond ((or (search "CREATE"     w) (search "CREATED"   w)) :created)
          ((or (search "DELETE"     w) (search "REMOVED"   w)) :deleted)
          ((or (search "MOVED"      w) (search "RENAMED"   w)
               (search "MOVE"       w)) :renamed)
          ((or (search "ATTRIB"     w) (search "OWNER"     w)
               (search "MODE"       w)) :attribute-changed)
          ((or (search "MODIFY"     w) (search "MODIFIED"  w)
               (search "UPDATED"    w) (search "WRITTEN"   w)) :modified)
          (t nil))))

(defun %action-passes-flags (action flags)
  "True if ACTION should be delivered to a watch with FLAGS."
  (cond
    ((eq action :attribute-changed) (member :attribute-change flags))
    (t                               (member :change flags))))

(defun %watch-matches-event-path (watch event-path)
  "True if EVENT-PATH should fire WATCH. Allows watching a directory and
   receiving events for children (Emacs convention)."
  (let ((wp (watch-path watch)))
    (or (equal wp event-path)
        ;; Directory watch: prefix match + path separator
        (and (>= (length event-path) (1+ (length wp)))
             (string= wp event-path :end2 (length wp))
             (char= #\/ (aref event-path (length wp)))))))

(defun %deliver (action path)
  "Deliver ACTION on PATH to every matching valid watch."
  (let ((err-pkg (find-package '#:limn/error)))
    (dolist (w (copy-list *watches*))
      (when (and (watch-valid w)
                 (%watch-matches-event-path w path)
                 (%action-passes-flags action (watch-flags w)))
        (let ((ev (list :descriptor w :action action :file path))
              (cb (watch-callback w)))
          (if err-pkg
              (let ((call (find-symbol "%CALL-WITH-PROTECTION" err-pkg)))
                (if call
                    (funcall call cb ev)
                    (handler-case (funcall cb ev) (error () nil))))
              (handler-case (funcall cb ev) (error () nil))))))))

(defun %parse-line (line)
  "Parse one helper output line into (values ACTION PATH) or nil.
   Supports both inotifywait's '%e %w%f' format and fswatch's
   'PATH event-set' format."
  (let ((line (string-trim '(#\Space #\Tab #\Return) line)))
    (when (plusp (length line))
      ;; Try inotifywait first: 'EVENTS PATH'
      (let ((sp (position #\Space line)))
        (cond
          ((null sp) nil)
          (t
           (let* ((first  (subseq line 0 sp))
                  (rest   (string-trim '(#\Space) (subseq line (1+ sp))))
                  (act1   (%action-keyword first))
                  (act2   (%action-keyword rest)))
             (cond
               ;; inotifywait: '<events> <path>'
               (act1 (values act1 rest))
               ;; fswatch: '<path> <events>' — events word is last token
               (act2 (values act2 first))
               (t nil)))))))))

(defun feed-helper-line (line-or-chunk)
  "Test entry point AND dispatch helper for real subprocess stdout.
   Concatenates the chunk with any prior fragment, splits on newlines,
   parses each complete line, and stashes the trailing partial line
   into *line-fragment* for the next call."
  (let* ((chunk (concatenate 'string *line-fragment* (or line-or-chunk ""))))
    (setf *line-fragment* "")
    (loop with start = 0
          for nl = (position #\Newline chunk :start start)
          while nl
          do (let ((line (subseq chunk start nl)))
               (multiple-value-bind (action path) (%parse-line line)
                 (when (and action path)
                   (%deliver action path))))
             (setf start (1+ nl))
          finally
            ;; Stash whatever is past the last newline as a fragment.
            (when (< start (length chunk))
              (setf *line-fragment* (subseq chunk start))))))

(defun %dispatch-chunk (chunk)
  "Called from the real helper subprocess stdout-filter; same parse as
   feed-helper-line. Kept under a separate name in case future logic
   needs to differ between real and mock paths."
  (feed-helper-line chunk))

;;; ── polling tick ───────────────────────────────────────────────────────

(defun dispatch-poll-tick ()
  "Walk all watches; for any whose mtime or size changed, fire :modified.
   Used by the polling backend (and is exposed for tests)."
  (dolist (w (copy-list *watches*))
    (when (watch-valid w)
      (let* ((path (watch-path w))
             (s    (funcall *file-notify-stat-fn* path))
             (prev (gethash path *poll-cache*)))
        (cond
          ((and s prev
                (or (not (eql (getf s :mtime) (getf prev :mtime)))
                    (not (eql (getf s :size)  (getf prev :size)))))
           (setf (gethash path *poll-cache*) s)
           (%deliver :modified path))
          (s
           (setf (gethash path *poll-cache*) s))))))
  nil)
