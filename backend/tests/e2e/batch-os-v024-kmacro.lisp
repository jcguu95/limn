;;;; v0.24 §D — keyboard macro (kmacro) OS-tier via Xvfb keypress
;;;;
;;;; kmacro's natural domain is real keystroke recording + replay. v0.24
;;;; ships the state machine + replay-fn vtable but does NOT wire
;;;; record-key to the dispatch loop automatically — that's user/init.lisp
;;;; territory. This test plays the role of init.lisp: install a hook on
;;;; event/key that calls record-key whenever *defining-kbd-macro* is t.
;;;;
;;;; The full pipeline tested:
;;;;   xdotool key → Qt event → bridge "key" → background pump →
;;;;   limn/hooks event/key fires → our hook calls limn/kmacro:record-key.
;;;;
;;;; On replay, we wire *kmacro-replay-fn* to a recorder lambda so we can
;;;; count + inspect the spec stream without needing a dispatcher
;;;; round-trip.
;;;;
;;;; Xvfb + xdotool required.
;;;;
;;;; Ω1   start-kbd-macro → *defining-kbd-macro* is t
;;;; Ω2   xdotool 3 keys → record-key called → *current-kbd-macro* len = 3
;;;; Ω3   end-kbd-macro → *defining-kbd-macro* nil; *last-kbd-macro*
;;;;        is a copy of *current-kbd-macro*
;;;; Ω4   call-last-kbd-macro → *kmacro-replay-fn* invoked per spec
;;;;        in recorded order
;;;; Ω5   call-last-kbd-macro count=3 → replay-fn called 3×len times
;;;;        and *kmacro-counter* incremented (once per call-last)
;;;; Ω6   *defining-kbd-macro* stays nil during replay (no re-record)
;;;; Ω7   *insert-at-point-fn* + kmacro-insert-counter → counter value
;;;;        appears in real C++ buffer via buffer/insert wire
;;;; Ω8   name-last-kbd-macro registers a no-arg command; calling it
;;;;        through limn/cmd replays the snapshot

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v024km"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-kmacro.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun buf-text (bid)
  (let ((r (limn:call "buffer/text" :|buffer-id| bid)))
    (and (ok? r) (getf (data r) :|text|))))

(defun xdotool (&rest args)
  (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool"
                                             '("search" "--name" "Limn")
                                             :search t :wait t
                                             :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
          do (return found)
        do (sleep 0.1)))

;;; helper to extract Emacs-style key spec from raw event plist
(defun event-key-spec (ev)
  (let ((key  (getf ev :|key|))
        (mods (getf ev :|mods|)))
    (if (null mods)
        key
        (format nil "~{~a-~}~a"
                (mapcar (lambda (m) (case (intern (string-upcase m) :keyword)
                                      (:ctrl  "C") (:alt "M")
                                      (:shift "S") (:meta "M")
                                      (t m)))
                        mods)
                key))))

(format t "~%=== batch-os-v024-kmacro ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v024km-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v024km.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  ;;; ── install record-key on event/key (init.lisp role) ────────────────
  ;; Important: this hook fires for EVERY key from the bridge, including
  ;; replayed ones unless *defining-kbd-macro* is bound to nil during
  ;; replay — call-last-kbd-macro does that (line 77 of limn-kmacro.lisp).
  (limn/hooks:add-hook "event/key"
    (lambda (ev)
      (when limn/kmacro:*defining-kbd-macro*
        (limn/kmacro:record-key (event-key-spec ev)))))

  ;;; ── Ω1: start-kbd-macro ──────────────────────────────────────────────
  (format t "~%── Ω1: start-kbd-macro ──~%")
  (limn/kmacro:start-kbd-macro)
  (check (format nil "Ω1 *defining-kbd-macro* is t (got ~s)"
                 limn/kmacro:*defining-kbd-macro*)
         (eq limn/kmacro:*defining-kbd-macro* t))

  ;;; ── Ω2: keys recorded ────────────────────────────────────────────────
  (format t "~%── Ω2: xdotool 3 keys → record-key ──~%")
  (xdotool "key" "--clearmodifiers" "a")
  (sleep 0.1)
  (xdotool "key" "--clearmodifiers" "b")
  (sleep 0.1)
  (xdotool "key" "--clearmodifiers" "c")
  (sleep 0.2)  ; let the pump thread process all three events
  (check (format nil "Ω2 current macro has 3 specs (got ~a; vec=~s)"
                 (length limn/kmacro:*current-kbd-macro*)
                 limn/kmacro:*current-kbd-macro*)
         (= (length limn/kmacro:*current-kbd-macro*) 3))

  ;;; ── Ω3: end-kbd-macro ────────────────────────────────────────────────
  (format t "~%── Ω3: end-kbd-macro ──~%")
  (limn/kmacro:end-kbd-macro)
  (check (format nil "Ω3a *defining-kbd-macro* is nil (got ~s)"
                 limn/kmacro:*defining-kbd-macro*)
         (null limn/kmacro:*defining-kbd-macro*))
  (check (format nil "Ω3b *last-kbd-macro* len = 3 (got ~a)"
                 (length limn/kmacro:*last-kbd-macro*))
         (= (length limn/kmacro:*last-kbd-macro*) 3))

  ;;; ── Ω4: replay invokes *kmacro-replay-fn* per spec ───────────────────
  (format t "~%── Ω4: call-last-kbd-macro → replay-fn ──~%")
  (let ((replay-log nil))
    (setf limn/kmacro:*kmacro-replay-fn*
          (lambda (spec) (push spec replay-log)))
    (limn/kmacro:call-last-kbd-macro)
    (let ((log (reverse replay-log)))
      (check (format nil "Ω4a replay-fn called 3 times (got ~a)" (length log))
             (= (length log) 3))
      ;; specs should appear in recorded order (a, b, c)
      (check (format nil "Ω4b replay order matches recording (got ~s)" log)
             (and (equal (nth 0 log) "a")
                  (equal (nth 1 log) "b")
                  (equal (nth 2 log) "c"))))

    ;;; ── Ω5: count multiplier + counter increment ───────────────────────
    (format t "~%── Ω5: call-last count=3 ──~%")
    (setf replay-log nil)
    (let ((counter-before limn/kmacro:*kmacro-counter*))
      (limn/kmacro:call-last-kbd-macro 3)
      (let ((after-count (length replay-log))
            (counter-delta (- limn/kmacro:*kmacro-counter* counter-before)))
        (check (format nil "Ω5a replay-fn called 9 times (3 specs × 3 counts; got ~a)"
                       after-count)
               (= after-count 9))
        ;; call-last-kbd-macro increments *kmacro-counter* once per
        ;; invocation (not per spec).
        (check (format nil "Ω5b counter +1 per call-last (delta=~a)" counter-delta)
               (= counter-delta 1))))

    ;;; ── Ω6: *defining-kbd-macro* nil during replay ─────────────────────
    ;; Subtle: call-last-kbd-macro internally rebinds *defining-kbd-macro*
    ;; to nil so replayed keys don't re-record themselves. We probe by
    ;; checking the var inside the replay-fn.
    (format t "~%── Ω6: defining-flag suppressed during replay ──~%")
    (let ((seen-defining nil))
      (setf limn/kmacro:*kmacro-replay-fn*
            (lambda (spec)
              (declare (ignore spec))
              (when limn/kmacro:*defining-kbd-macro*
                (setf seen-defining t))))
      ;; Simulate user being "in recording" at outer scope, then call replay.
      (let ((limn/kmacro:*defining-kbd-macro* t))
        (limn/kmacro:call-last-kbd-macro))
      (check (format nil "Ω6 *defining-kbd-macro* never t inside replay (seen=~s)"
                     seen-defining)
             (null seen-defining)))

    ;;; ── Ω7: kmacro-insert-counter via real buffer ─────────────────────
    (format t "~%── Ω7: kmacro-insert-counter into buffer ──~%")
    (let* ((r   (limn:call "bridge/engine-load"
                            :|engine| "text" :|path| "" :|win-id| "w1"))
           (bid (and (ok? r) (getf (data r) :|buffer-id|))))
      (when bid
        (setf limn/kmacro:*kmacro-counter* 42)
        (setf limn/kmacro:*insert-at-point-fn*
              (lambda (text)
                (limn:call "buffer/insert"
                            :|buffer-id| bid :|at| 0 :|text| text)))
        (limn/kmacro:kmacro-insert-counter)
        (let ((txt (buf-text bid)))
          (check (format nil "Ω7 buffer has counter string \"42\" (got ~s)" txt)
                 (equal txt "42")))))

    ;;; ── Ω8: name-last-kbd-macro ─────────────────────────────────────────
    (format t "~%── Ω8: name-last-kbd-macro ──~%")
    ;; Re-seed: record a simple sequence, end, then name it.
    (setf replay-log nil)
    (limn/kmacro:start-kbd-macro)
    (xdotool "key" "--clearmodifiers" "x")
    (sleep 0.1)
    (xdotool "key" "--clearmodifiers" "y")
    (sleep 0.2)
    (limn/kmacro:end-kbd-macro)
    (setf limn/kmacro:*kmacro-replay-fn*
          (lambda (spec) (push spec replay-log)))
    (limn/kmacro:name-last-kbd-macro 'v024-saved-macro)
    ;; limn/cmd:find-command returns the registered command struct.
    (let* ((cmd (limn/cmd:find-command 'v024-saved-macro)))
      (check (format nil "Ω8a command registered (got ~s)" cmd)
             (not (null cmd)))
      (when cmd
        ;; Invoke via call-interactively (the same path dispatch uses).
        (limn/cmd:call-interactively cmd)
        (let ((log (reverse replay-log)))
          (check (format nil "Ω8b named macro replays the snapshot (log=~s)" log)
                 (and (>= (length log) 2)
                      (equal (nth 0 log) "x")
                      (equal (nth 1 log) "y")))))))

  (ignore-errors (limn:stop))
  (sleep 0.1)
  (handler-case (sb-ext:process-kill proc 15) (error () nil))
  (handler-case (sb-ext:process-wait proc) (error () nil)))

(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failure(s))~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
