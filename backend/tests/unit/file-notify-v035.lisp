;;;; v0.35 §A — file-notify RED tests (~32 tests)
;;;;
;;;; 覆蓋（SPEC v0.35 §A，對齊 Emacs filenotify.el）：
;;;;   limn/file-notify : file-notify-add-watch / file-notify-rm-watch
;;;;                      file-notify-valid-p
;;;;                      *file-notify-backend*  (= :inotify / :fswatch / :polling / auto)
;;;;                      *file-notify-helper-spawn-fn*  (vtable for mock subprocess)
;;;;                      *file-notify-stat-fn*          (vtable for polling fallback)
;;;;                      *file-notify-now-fn*           (fake clock for polling)
;;;;                      dispatch-poll-tick            (advance polling loop)
;;;;                      feed-helper-line              (inject mock helper output)
;;;;                      reset-file-notify             (test cleanup)
;;;;
;;;; Backend probe / helper selection：
;;;;   *file-notify-helper-probe-fn* — lambda → :inotify / :fswatch / nil
;;;;
;;;; CALLBACK 收 event plist：
;;;;   (:descriptor D :action ACTION :file PATH)
;;;;   ACTION ∈ {:created :deleted :modified :renamed :attribute-changed}
;;;;
;;;; 所有測試都 RED — limn-file-notify.lisp 尚未實作。

;; ── package stub ─────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/file-notify)
    (make-package '#:limn/file-notify :use '(#:cl)))
  (dolist (sym '(;; public API
                 "FILE-NOTIFY-ADD-WATCH"
                 "FILE-NOTIFY-RM-WATCH"
                 "FILE-NOTIFY-VALID-P"
                 "LIST-WATCHES"
                 ;; configuration / vtable
                 "*FILE-NOTIFY-BACKEND*"
                 "*FILE-NOTIFY-HELPER-SPAWN-FN*"
                 "*FILE-NOTIFY-HELPER-PROBE-FN*"
                 "*FILE-NOTIFY-STAT-FN*"
                 "*FILE-NOTIFY-EXISTS-P-FN*"
                 "*FILE-NOTIFY-NOW-FN*"
                 "*FILE-NOTIFY-POLLING-INTERVAL*"
                 ;; mock-driven dispatch
                 "FEED-HELPER-LINE"
                 "DISPATCH-POLL-TICK"
                 "SIMULATE-HELPER-EXIT"
                 ;; test cleanup
                 "RESET-FILE-NOTIFY"
                 "HELPER-RESPAWN-COUNT"))
    (export (intern sym '#:limn/file-notify) '#:limn/file-notify)))

(in-package #:limn/unit-test)

;;; ── helpers ──────────────────────────────────────────────────────────────

(defmacro with-fn-pkg (&body body)
  "Skip body when limn/file-notify hasn't been loaded yet."
  `(let ((pkg (find-package '#:limn/file-notify)))
     (if (null pkg)
         (format t "  (skipped: limn/file-notify not loaded)~%")
         (progn ,@body))))

(defmacro with-clean-fn (&body body)
  "Reset registry / counters before and after BODY."
  `(with-fn-pkg
     (let ((reset (find-symbol "RESET-FILE-NOTIFY" '#:limn/file-notify)))
       (when reset (funcall reset))
       (unwind-protect (progn ,@body)
         (when reset (funcall reset))))))

(defun %events ()
  "Allocate an event-accumulator: returns (values getter callback)."
  (let ((lst '()))
    (values (lambda () (reverse lst))
            (lambda (ev) (push ev lst)))))

(defmacro with-helper-fake ((&key (backend :inotify)) &body body)
  "Bind backend to BACKEND and install a mock helper-spawn-fn that records
   the spawn-count instead of forking a real subprocess. Also stubs the
   existence check so tests don't need real /tmp files."
  `(let* ((be-sym    (find-symbol "*FILE-NOTIFY-BACKEND*"
                                  '#:limn/file-notify))
          (probe-sym (find-symbol "*FILE-NOTIFY-HELPER-PROBE-FN*"
                                  '#:limn/file-notify))
          (spawn-sym (find-symbol "*FILE-NOTIFY-HELPER-SPAWN-FN*"
                                  '#:limn/file-notify))
          (exist-sym (find-symbol "*FILE-NOTIFY-EXISTS-P-FN*"
                                  '#:limn/file-notify)))
     (progv (list be-sym probe-sym spawn-sym exist-sym)
            (list ,backend
                  (lambda () ,backend)
                  (lambda (kind) (declare (ignore kind)) :fake-helper)
                  (lambda (path) (declare (ignore path)) t))
       ,@body)))

;;; ─── A1. add-watch / rm-watch basic ──────────────────────────────────────

(deftest file-notify-a1-add-returns-descriptor
  "add-watch returns an opaque descriptor (non-nil)."
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (declare (ignore getter))
        (let ((d (limn/file-notify:file-notify-add-watch
                  "/tmp/x" '(:change) cb)))
          (assert-true d "descriptor non-nil"))))))

(deftest file-notify-a1-descriptor-valid-after-add
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (declare (ignore getter))
        (let ((d (limn/file-notify:file-notify-add-watch
                  "/tmp/x" '(:change) cb)))
          (assert-true (limn/file-notify:file-notify-valid-p d)
                       "valid-p true after add"))))))

(deftest file-notify-a1-rm-watch-invalidates
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (declare (ignore getter))
        (let ((d (limn/file-notify:file-notify-add-watch
                  "/tmp/x" '(:change) cb)))
          (limn/file-notify:file-notify-rm-watch d)
          (assert-false (limn/file-notify:file-notify-valid-p d)
                        "valid-p false after rm"))))))

(deftest file-notify-a1-rm-watch-idempotent
  "rm twice does not signal."
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (declare (ignore getter))
        (let ((d (limn/file-notify:file-notify-add-watch
                  "/tmp/x" '(:change) cb)))
          (assert-no-error
            (progn (limn/file-notify:file-notify-rm-watch d)
                   (limn/file-notify:file-notify-rm-watch d))))))))

(deftest file-notify-a1-list-watches-tracks-additions
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (declare (ignore getter))
        (limn/file-notify:file-notify-add-watch "/tmp/a" '(:change) cb)
        (limn/file-notify:file-notify-add-watch "/tmp/b" '(:change) cb)
        (assert-eql 2 (length (limn/file-notify:list-watches)))))))

(deftest file-notify-a1-same-path-two-callbacks-both-fire
  "Two add-watch calls on same path → both callbacks fire on event."
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g1 cb1) (%events)
        (multiple-value-bind (g2 cb2) (%events)
          (limn/file-notify:file-notify-add-watch
           "/tmp/dual" '(:change) cb1)
          (limn/file-notify:file-notify-add-watch
           "/tmp/dual" '(:change) cb2)
          (limn/file-notify:feed-helper-line "MODIFY /tmp/dual")
          (assert-eql 1 (length (funcall g1)))
          (assert-eql 1 (length (funcall g2))))))))

;;; ─── A2. callback / event payload ────────────────────────────────────────

(deftest file-notify-a2-callback-receives-plist
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (limn/file-notify:file-notify-add-watch
         "/tmp/foo" '(:change) cb)
        (limn/file-notify:feed-helper-line "MODIFY /tmp/foo")
        (let ((evs (funcall getter)))
          (assert-eql 1 (length evs))
          (let ((ev (first evs)))
            (assert-true (getf ev :descriptor) "ev has :descriptor")
            (assert-eq :modified (getf ev :action) "action = :modified")
            (assert-equal "/tmp/foo" (getf ev :file)
                          "file path preserved")))))))

(deftest file-notify-a2-descriptor-in-event-matches-add-result
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (let ((d (limn/file-notify:file-notify-add-watch
                  "/tmp/match" '(:change) cb)))
          (limn/file-notify:feed-helper-line "MODIFY /tmp/match")
          (let ((ev (first (funcall getter))))
            (assert-true (eq d (getf ev :descriptor))
                         "descriptor in event = descriptor returned by add")))))))

(deftest file-notify-a2-no-event-before-feed
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (limn/file-notify:file-notify-add-watch
         "/tmp/silent" '(:change) cb)
        (assert-eql 0 (length (funcall getter)))))))

;;; ─── A3. action mapping ──────────────────────────────────────────────────

(deftest file-notify-a3-create-action
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (limn/file-notify:file-notify-add-watch "/tmp/c" '(:change) cb)
        (limn/file-notify:feed-helper-line "CREATE /tmp/c")
        (assert-eq :created (getf (first (funcall getter)) :action))))))

(deftest file-notify-a3-delete-action
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (limn/file-notify:file-notify-add-watch "/tmp/d" '(:change) cb)
        (limn/file-notify:feed-helper-line "DELETE /tmp/d")
        (assert-eq :deleted (getf (first (funcall getter)) :action))))))

(deftest file-notify-a3-modify-action
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (limn/file-notify:file-notify-add-watch "/tmp/m" '(:change) cb)
        (limn/file-notify:feed-helper-line "MODIFY /tmp/m")
        (assert-eq :modified (getf (first (funcall getter)) :action))))))

(deftest file-notify-a3-rename-action
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (limn/file-notify:file-notify-add-watch "/tmp/r" '(:change) cb)
        (limn/file-notify:feed-helper-line "MOVED_FROM /tmp/r")
        (assert-eq :renamed (getf (first (funcall getter)) :action))))))

(deftest file-notify-a3-attrib-action
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (limn/file-notify:file-notify-add-watch "/tmp/a" '(:attribute-change) cb)
        (limn/file-notify:feed-helper-line "ATTRIB /tmp/a")
        (assert-eq :attribute-changed
                   (getf (first (funcall getter)) :action))))))

(deftest file-notify-a3-attrib-flag-filters-modify
  "Watch only :attribute-change → MODIFY events not delivered."
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (getter cb) (%events)
        (limn/file-notify:file-notify-add-watch
         "/tmp/aa" '(:attribute-change) cb)
        (limn/file-notify:feed-helper-line "MODIFY /tmp/aa")
        (assert-eql 0 (length (funcall getter)))))))

;;; ─── A4. multiple watches / routing ──────────────────────────────────────

(deftest file-notify-a4-events-routed-by-path
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g-x cb-x) (%events)
        (multiple-value-bind (g-y cb-y) (%events)
          (limn/file-notify:file-notify-add-watch
           "/tmp/path-x" '(:change) cb-x)
          (limn/file-notify:file-notify-add-watch
           "/tmp/path-y" '(:change) cb-y)
          (limn/file-notify:feed-helper-line "MODIFY /tmp/path-x")
          (limn/file-notify:feed-helper-line "MODIFY /tmp/path-y")
          (limn/file-notify:feed-helper-line "MODIFY /tmp/path-y")
          (assert-eql 1 (length (funcall g-x)))
          (assert-eql 2 (length (funcall g-y))))))))

(deftest file-notify-a4-rm-one-does-not-affect-other
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g-x cb-x) (%events)
        (multiple-value-bind (g-y cb-y) (%events)
          (let ((dx (limn/file-notify:file-notify-add-watch
                     "/tmp/aa" '(:change) cb-x))
                (dy (limn/file-notify:file-notify-add-watch
                     "/tmp/bb" '(:change) cb-y)))
            (declare (ignore dy))
            (limn/file-notify:file-notify-rm-watch dx)
            (limn/file-notify:feed-helper-line "MODIFY /tmp/aa")
            (limn/file-notify:feed-helper-line "MODIFY /tmp/bb")
            (assert-eql 0 (length (funcall g-x)))
            (assert-eql 1 (length (funcall g-y)))))))))

(deftest file-notify-a4-many-watches-stress
  "20 watches × 5 events each: zero loss."
  (with-clean-fn
    (with-helper-fake ()
      (let ((getters '()))
        (dotimes (i 20)
          (multiple-value-bind (g cb) (%events)
            (push (cons i g) getters)
            (limn/file-notify:file-notify-add-watch
             (format nil "/tmp/stress-~D" i) '(:change) cb)))
        (dotimes (i 20)
          (dotimes (k 5)
            (declare (ignore k))
            (limn/file-notify:feed-helper-line
             (format nil "MODIFY /tmp/stress-~D" i))))
        (dolist (entry getters)
          (assert-eql 5 (length (funcall (cdr entry)))))))))

;;; ─── A5. helper death / reaper ───────────────────────────────────────────

(deftest file-notify-a5-helper-respawn-on-exit
  "If the helper subprocess dies, the reaper spawns a new one
   (visible via helper-respawn-count)."
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g cb) (%events)
        (declare (ignore g))
        (limn/file-notify:file-notify-add-watch "/tmp/r" '(:change) cb)
        (let ((count-before (limn/file-notify:helper-respawn-count)))
          (limn/file-notify:simulate-helper-exit)
          (assert-true (> (limn/file-notify:helper-respawn-count)
                          count-before)
                       "respawn count increased"))))))

(deftest file-notify-a5-watch-survives-helper-restart
  "After a helper restart, existing watches still deliver events."
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g cb) (%events)
        (limn/file-notify:file-notify-add-watch "/tmp/sv" '(:change) cb)
        (limn/file-notify:simulate-helper-exit)
        (limn/file-notify:feed-helper-line "MODIFY /tmp/sv")
        (assert-eql 1 (length (funcall g)))))))

;;; ─── A6. polling fallback ────────────────────────────────────────────────

(deftest file-notify-a6-polling-detects-mtime-change
  "*file-notify-backend* = :polling + stat mock → mtime change fires :modified."
  (with-clean-fn
    (let* ((be-sym   (find-symbol "*FILE-NOTIFY-BACKEND*"
                                  '#:limn/file-notify))
           (stat-sym (find-symbol "*FILE-NOTIFY-STAT-FN*"
                                  '#:limn/file-notify))
           (now-sym  (find-symbol "*FILE-NOTIFY-NOW-FN*"
                                  '#:limn/file-notify))
           (exist-sym (find-symbol "*FILE-NOTIFY-EXISTS-P-FN*"
                                   '#:limn/file-notify))
           (mtime    100))
      (progv (list be-sym stat-sym now-sym exist-sym)
             (list :polling
                   (lambda (path) (declare (ignore path))
                     (list :mtime mtime :size 0))
                   (lambda () 0)
                   (lambda (p) (declare (ignore p)) t))
        (multiple-value-bind (g cb) (%events)
          (limn/file-notify:file-notify-add-watch "/tmp/p" '(:change) cb)
          (limn/file-notify:dispatch-poll-tick)
          (assert-eql 0 (length (funcall g))
                      "no event before any change")
          (setf mtime 200)
          (limn/file-notify:dispatch-poll-tick)
          (let ((evs (funcall g)))
            (assert-eql 1 (length evs))
            (assert-eq :modified (getf (first evs) :action))))))))

(deftest file-notify-a6-polling-size-change-also-triggers
  (with-clean-fn
    (let* ((be-sym   (find-symbol "*FILE-NOTIFY-BACKEND*"
                                  '#:limn/file-notify))
           (stat-sym (find-symbol "*FILE-NOTIFY-STAT-FN*"
                                  '#:limn/file-notify))
           (exist-sym (find-symbol "*FILE-NOTIFY-EXISTS-P-FN*"
                                   '#:limn/file-notify))
           (size     0))
      (progv (list be-sym stat-sym exist-sym)
             (list :polling
                   (lambda (path) (declare (ignore path))
                     (list :mtime 100 :size size))
                   (lambda (p) (declare (ignore p)) t))
        (multiple-value-bind (g cb) (%events)
          (limn/file-notify:file-notify-add-watch "/tmp/q" '(:change) cb)
          (limn/file-notify:dispatch-poll-tick)
          (setf size 42)
          (limn/file-notify:dispatch-poll-tick)
          (assert-eql 1 (length (funcall g))))))))

(deftest file-notify-a6-polling-no-event-on-no-change
  (with-clean-fn
    (let* ((be-sym   (find-symbol "*FILE-NOTIFY-BACKEND*"
                                  '#:limn/file-notify))
           (stat-sym (find-symbol "*FILE-NOTIFY-STAT-FN*"
                                  '#:limn/file-notify))
           (exist-sym (find-symbol "*FILE-NOTIFY-EXISTS-P-FN*"
                                   '#:limn/file-notify)))
      (progv (list be-sym stat-sym exist-sym)
             (list :polling
                   (lambda (path) (declare (ignore path))
                     (list :mtime 100 :size 0))
                   (lambda (p) (declare (ignore p)) t))
        (multiple-value-bind (g cb) (%events)
          (limn/file-notify:file-notify-add-watch "/tmp/r" '(:change) cb)
          (limn/file-notify:dispatch-poll-tick)
          (limn/file-notify:dispatch-poll-tick)
          (limn/file-notify:dispatch-poll-tick)
          (assert-eql 0 (length (funcall g))))))))

;;; ─── A7. backend probe / auto-select ─────────────────────────────────────

(defmacro with-a7-progv ((backend-val probe-val spawn-val) &body body)
  "Helper for A7 tests: bind backend/probe/spawn/exists-fn together,
   with exists-fn defaulted to (constantly t)."
  (let ((be-sym    (gensym))
        (probe-sym (gensym))
        (spawn-sym (gensym))
        (exist-sym (gensym))
        (stat-sym  (gensym)))
    `(let* ((,be-sym    (find-symbol "*FILE-NOTIFY-BACKEND*"
                                     '#:limn/file-notify))
            (,probe-sym (find-symbol "*FILE-NOTIFY-HELPER-PROBE-FN*"
                                     '#:limn/file-notify))
            (,spawn-sym (find-symbol "*FILE-NOTIFY-HELPER-SPAWN-FN*"
                                     '#:limn/file-notify))
            (,exist-sym (find-symbol "*FILE-NOTIFY-EXISTS-P-FN*"
                                     '#:limn/file-notify))
            (,stat-sym  (find-symbol "*FILE-NOTIFY-STAT-FN*"
                                     '#:limn/file-notify)))
       (progv (list ,be-sym ,probe-sym ,spawn-sym ,exist-sym ,stat-sym)
              (list ,backend-val
                    ,probe-val
                    ,spawn-val
                    (lambda (p) (declare (ignore p)) t)
                    (lambda (p) (declare (ignore p))
                      (list :mtime 100 :size 0)))
         ,@body))))

(deftest file-notify-a7-prefers-inotify-when-available
  (with-clean-fn
    (let ((chosen nil))
      (with-a7-progv (:auto
                      (lambda () :inotify)
                      (lambda (kind) (setf chosen kind) :fake))
        (multiple-value-bind (g cb) (%events)
          (declare (ignore g))
          (limn/file-notify:file-notify-add-watch "/tmp/p7" '(:change) cb)
          (assert-eq :inotify chosen "spawned with inotify backend"))))))

(deftest file-notify-a7-prefers-fswatch-when-no-inotify
  (with-clean-fn
    (let ((chosen nil))
      (with-a7-progv (:auto
                      (lambda () :fswatch)
                      (lambda (kind) (setf chosen kind) :fake))
        (multiple-value-bind (g cb) (%events)
          (declare (ignore g))
          (limn/file-notify:file-notify-add-watch "/tmp/p7" '(:change) cb)
          (assert-eq :fswatch chosen))))))

(deftest file-notify-a7-falls-back-to-polling-when-no-helper
  (with-clean-fn
    (let ((mtime 0))
      (let* ((be-sym    (find-symbol "*FILE-NOTIFY-BACKEND*"
                                     '#:limn/file-notify))
             (probe-sym (find-symbol "*FILE-NOTIFY-HELPER-PROBE-FN*"
                                     '#:limn/file-notify))
             (stat-sym  (find-symbol "*FILE-NOTIFY-STAT-FN*"
                                     '#:limn/file-notify))
             (exist-sym (find-symbol "*FILE-NOTIFY-EXISTS-P-FN*"
                                     '#:limn/file-notify)))
        (progv (list be-sym probe-sym stat-sym exist-sym)
               (list :auto
                     (lambda () nil)
                     (lambda (path) (declare (ignore path))
                       (list :mtime mtime :size 0))
                     (lambda (p) (declare (ignore p)) t))
          (multiple-value-bind (g cb) (%events)
            (limn/file-notify:file-notify-add-watch "/tmp/p7" '(:change) cb)
            (setf mtime 1)
            (limn/file-notify:dispatch-poll-tick)
            (assert-eql 1 (length (funcall g))
                        "polling backend kicked in")))))))

(deftest file-notify-a7-override-backend-respected
  "*file-notify-backend* set explicitly → probe ignored."
  (with-clean-fn
    (let ((chosen nil) (probed 0))
      (with-a7-progv (:inotify
                      (lambda () (incf probed) :fswatch)
                      (lambda (kind) (setf chosen kind) :fake))
        (multiple-value-bind (g cb) (%events)
          (declare (ignore g))
          (limn/file-notify:file-notify-add-watch "/tmp/p7" '(:change) cb)
          (assert-eq :inotify chosen "explicit override honoured")
          (assert-eql 0 probed "probe-fn not called when explicit"))))))

;;; ─── A8. ordering / no-loss under burst ─────────────────────────────────

(deftest file-notify-a8-burst-preserves-order
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g cb) (%events)
        (limn/file-notify:file-notify-add-watch "/tmp/burst" '(:change) cb)
        (dotimes (i 50)
          (limn/file-notify:feed-helper-line
           (format nil "MODIFY /tmp/burst")))
        (let ((evs (funcall g)))
          (assert-eql 50 (length evs)
                      "all 50 events delivered, none dropped"))))))

(deftest file-notify-a8-helper-stdout-chunk-boundary
  "Real helpers may deliver multiple events in one read chunk, or split
   a single line across reads. The parser must reassemble correctly."
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g cb) (%events)
        (limn/file-notify:file-notify-add-watch "/tmp/chunk" '(:change) cb)
        ;; multiple lines in one chunk
        (limn/file-notify:feed-helper-line
         (format nil "MODIFY /tmp/chunk~%MODIFY /tmp/chunk~%MODIFY /tmp/chunk"))
        (assert-eql 3 (length (funcall g))
                    "3 lines in 1 chunk → 3 events")))))

;;; ─── A9. callback error containment ─────────────────────────────────────

(deftest file-notify-a9-callback-error-does-not-kill-dispatcher
  "If one callback throws, other watches still receive their events."
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g-good cb-good) (%events)
        (let ((cb-bad (lambda (ev)
                        (declare (ignore ev))
                        (error "boom!"))))
          (limn/file-notify:file-notify-add-watch
           "/tmp/bad"  '(:change) cb-bad)
          (limn/file-notify:file-notify-add-watch
           "/tmp/good" '(:change) cb-good)
          (assert-no-error
            (limn/file-notify:feed-helper-line "MODIFY /tmp/bad"))
          (limn/file-notify:feed-helper-line "MODIFY /tmp/good")
          (assert-eql 1 (length (funcall g-good))
                      "good cb still got its event"))))))

;;; ─── A10. unsubscribe → no further events ───────────────────────────────

(deftest file-notify-a10-rm-stops-future-events
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g cb) (%events)
        (let ((d (limn/file-notify:file-notify-add-watch
                  "/tmp/un" '(:change) cb)))
          (limn/file-notify:feed-helper-line "MODIFY /tmp/un")
          (limn/file-notify:file-notify-rm-watch d)
          (limn/file-notify:feed-helper-line "MODIFY /tmp/un")
          (assert-eql 1 (length (funcall g))
                      "only 1 event (before rm)"))))))

(deftest file-notify-a10-invalid-descriptor-rm-no-error
  (with-clean-fn
    (with-helper-fake ()
      (assert-no-error
        (limn/file-notify:file-notify-rm-watch :not-a-real-descriptor)))))

;;; ─── A11. extra extrapolation ────────────────────────────────────────────

(deftest file-notify-a11-directory-watch-receives-child-events
  "Watching a directory delivers events for files within it."
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g cb) (%events)
        (limn/file-notify:file-notify-add-watch "/tmp/dir" '(:change) cb)
        (limn/file-notify:feed-helper-line "CREATE /tmp/dir/newfile")
        (let ((evs (funcall g)))
          (assert-eql 1 (length evs))
          (assert-equal "/tmp/dir/newfile" (getf (first evs) :file)))))))

(deftest file-notify-a11-flags-must-be-list
  "Empty flags list is allowed (no watch flags = default :change)."
  (with-clean-fn
    (with-helper-fake ()
      (multiple-value-bind (g cb) (%events)
        (declare (ignore g))
        (assert-no-error
          (limn/file-notify:file-notify-add-watch "/tmp/f" '() cb))))))

(deftest file-notify-a11-callback-receives-only-one-arg
  "Emacs convention: callback takes exactly one arg (the event plist)."
  (with-clean-fn
    (with-helper-fake ()
      (let ((arity-got nil))
        (limn/file-notify:file-notify-add-watch
         "/tmp/arity" '(:change)
         (lambda (&rest args) (setf arity-got (length args))))
        (limn/file-notify:feed-helper-line "MODIFY /tmp/arity")
        (assert-eql 1 arity-got "callback called with 1 arg")))))

(deftest file-notify-a11-helper-not-spawned-until-first-add
  "Lazy spawn: no watches → no helper process."
  (with-clean-fn
    (let* ((be-sym    (find-symbol "*FILE-NOTIFY-BACKEND*"
                                   '#:limn/file-notify))
           (probe-sym (find-symbol "*FILE-NOTIFY-HELPER-PROBE-FN*"
                                   '#:limn/file-notify))
           (spawn-sym (find-symbol "*FILE-NOTIFY-HELPER-SPAWN-FN*"
                                   '#:limn/file-notify))
           (spawned   0))
      (progv (list be-sym probe-sym spawn-sym)
             (list :inotify
                   (lambda () :inotify)
                   (lambda (kind) (declare (ignore kind))
                     (incf spawned) :fake))
        (assert-eql 0 spawned "no spawn at install")))))

(deftest file-notify-a11-add-watch-nonexistent-path-signals
  "Emacs: file-notify-add-watch raises if path doesn't exist.
   Tests via *FILE-NOTIFY-EXISTS-P-FN* vtable returning nil."
  (with-clean-fn
    (let* ((be-sym    (find-symbol "*FILE-NOTIFY-BACKEND*"
                                   '#:limn/file-notify))
           (probe-sym (find-symbol "*FILE-NOTIFY-HELPER-PROBE-FN*"
                                   '#:limn/file-notify))
           (spawn-sym (find-symbol "*FILE-NOTIFY-HELPER-SPAWN-FN*"
                                   '#:limn/file-notify))
           (exist-sym (find-symbol "*FILE-NOTIFY-EXISTS-P-FN*"
                                   '#:limn/file-notify)))
      (progv (list be-sym probe-sym spawn-sym exist-sym)
             (list :inotify
                   (lambda () :inotify)
                   (lambda (kind) (declare (ignore kind)) :fake)
                   (lambda (path) (declare (ignore path)) nil)) ; never exists
        (multiple-value-bind (g cb) (%events)
          (declare (ignore g))
          (assert-error error
            (limn/file-notify:file-notify-add-watch
             "/tmp/missing-xyz" '(:change) cb)))))))
