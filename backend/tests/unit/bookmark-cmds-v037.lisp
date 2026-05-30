;;;; v0.37 — limn/bookmark-cmds RED tests (unit-tier)
;;;;
;;;; Covers:
;;;;   - cl-user::bookmark-* defcommands registered after
;;;;     install-bookmark-commands
;;;;   - install-bookmark-bindings binds C-x r m/b/l/d/M on a keymap
;;;;   - bookmark-set captures current-mode record via record-fn
;;;;     dispatch (full M-x → minibuffer-read path, mocked)
;;;;   - bookmark-jump dispatches the right handler
;;;;
;;;; The runtime *minibuffer-read* and limn/runtime helpers are mocked
;;;; — no live bridge, no live Limn process.

(in-package #:limn/unit-test)

;;; ── helpers ─────────────────────────────────────────────────────────

(defun %ensure-bookmark-cmds-loaded ()
  "Re-run install (idempotent) so tests that come after a
   clear-commands tear-down still see the registrations."
  (let* ((pkg (find-package '#:limn/bookmark-cmds))
         (fn  (and pkg (find-symbol "INSTALL-BOOKMARK-COMMANDS" pkg))))
    (when (and fn (fboundp fn)) (funcall (symbol-function fn)))))

(defmacro with-mock-minibuffer ((return-value) &body body)
  "Bind *minibuffer-read* to a thunk that returns RETURN-VALUE
   (closed over so tests can assert it was the prompted-for input)."
  `(let ((limn/cmd:*minibuffer-read* (lambda (prompt)
                                       (declare (ignore prompt))
                                       ,return-value)))
     ,@body))

(defmacro with-mock-focused-mode ((mode-symbol) &body body)
  "Mock limn/runtime so current-handler-symbol returns MODE-SYMBOL
   (passed in unquoted; quoted at expansion time).

   Registers a one-shot win-id=w1 → buf-id=BX → mode-buffer mapping
   through the real registry; cleans up after.  Ensures MODE-SYMBOL
   is a defined major mode and activated on the mock mode-buffer."
  (let ((mb-var (gensym)) (bid "test-bm-bid"))
    `(let ((,mb-var (limn/mode:make-mode-buffer)))
       (unless (limn/mode:find-mode ',mode-symbol)
         (limn/mode:define-mode ',mode-symbol :type :major
                                 :modeline ,(symbol-name mode-symbol)))
       (limn/mode:activate ,mb-var ',mode-symbol)
       (limn/runtime:register-mode-buffer ,bid ,mb-var)
       (limn/runtime:set-window-active-buffer "w1" ,bid)
       (unwind-protect (progn ,@body)
         (limn/runtime:unregister-mode-buffer ,bid)
         (limn/runtime:set-window-active-buffer "w1" nil)))))

;;; ── C1. command registration ────────────────────────────────────────

(deftest bookmark-cmds-c1-set-registered
  (%ensure-bookmark-cmds-loaded)
  (assert-true (limn/cmd:find-command (find-symbol "BOOKMARK-SET" :cl-user))
               "cl-user::bookmark-set defcommand exists"))

(deftest bookmark-cmds-c1-all-registered
  (%ensure-bookmark-cmds-loaded)
  (dolist (n '("BOOKMARK-SET" "BOOKMARK-JUMP" "BOOKMARK-DELETE"
               "BOOKMARK-RENAME" "BOOKMARK-LIST"
               "BOOKMARK-SAVE" "BOOKMARK-LOAD"))
    (let ((sym (find-symbol n :cl-user)))
      (check (and sym (limn/cmd:find-command sym))
             (format nil "cl-user::~a registered" (string-downcase n))
             "command ~a missing" n))))

;;; ── C2. keymap install ──────────────────────────────────────────────

(deftest bookmark-cmds-c2-binds-c-x-r-prefix
  (%ensure-bookmark-cmds-loaded)
  (let ((km (limn/keys:make-keymap)))
    (limn/bookmark-cmds:install-bookmark-bindings km)
    (dolist (pair '(("m" . "BOOKMARK-SET")
                    ("b" . "BOOKMARK-JUMP")
                    ("l" . "BOOKMARK-LIST")
                    ("d" . "BOOKMARK-DELETE")
                    ("M" . "BOOKMARK-RENAME")))
      (let* ((last  (car pair))
             (cname (cdr pair))
             (seq   (list "C-x" "r" last))
             (action (limn/keys:lookup-sequence km seq)))
        (check (functionp action)
               (format nil "C-x r ~a bound to a callable for ~a" last cname)
               "expected function, got ~s" action)))))

;;; ── C3. bookmark-set end-to-end (mocked minibuffer + mocked mode) ──

(deftest bookmark-cmds-c3-set-captures-via-record-fn
  "Full M-x flow: mock minibuffer returns the name, current-mode
   has a registered record-fn, the new bookmark lands with the
   correct handler + record.

   The sidecar write goes to a per-test tmp path so we don't touch
   the user's real ~/.limn/bookmarks.lisp."
  (%ensure-bookmark-cmds-loaded)
  (limn/bookmark:bookmark-clear)
  (limn/mode:define-mode 'unit-test-mode :type :major :modeline "ut")
  (limn/bookmark:register-record-fn
   'unit-test-mode
   (lambda () '(:file "/mock/here.txt" :position 7 :line 1)))
  (let ((tmp-home (format nil "/tmp/limn-bm-c3-home-~a" (random 1000000)))
        (orig-home (sb-posix:getenv "HOME")))
    (ensure-directories-exist (format nil "~a/.limn/" tmp-home))
    (sb-posix:setenv "HOME" tmp-home 1)
    (unwind-protect
         (with-mock-focused-mode (unit-test-mode)
           (with-mock-minibuffer ("set-via-cmd")
             (limn/cmd:call-interactively
              (find-symbol "BOOKMARK-SET" :cl-user)))
           (let ((b (limn/bookmark:bookmark-find "set-via-cmd")))
             (assert-true b "new bookmark exists after M-x bookmark-set")
             (when b
               (assert-equal 'unit-test-mode
                             (limn/bookmark:bookmark-handler b)
                             "handler = current major mode")
               (assert-equal "/mock/here.txt"
                             (getf (limn/bookmark:bookmark-record b) :file)
                             "record :file comes from record-fn"))))
      (when orig-home (sb-posix:setenv "HOME" orig-home 1))
      (limn/bookmark:unregister-record-fn 'unit-test-mode))))

(deftest bookmark-cmds-c3-set-without-record-fn-noops
  "If the focused mode has no record-fn, bookmark-set must not
   add anything to the store (logs a message instead)."
  (%ensure-bookmark-cmds-loaded)
  (limn/bookmark:bookmark-clear)
  (limn/mode:define-mode 'no-record-mode :type :major :modeline "nr")
  (limn/bookmark:unregister-record-fn 'no-record-mode)
  (with-mock-focused-mode (no-record-mode)
    (with-mock-minibuffer ("ghost")
      (handler-case
          (limn/cmd:call-interactively (find-symbol "BOOKMARK-SET" :cl-user))
        (error () nil))
      (assert-false (limn/bookmark:bookmark-find "ghost")
                    "no record-fn → no bookmark added"))))

;;; ── C4. bookmark-jump dispatches the handler ───────────────────────

(deftest bookmark-cmds-c4-jump-calls-handler-fn
  "bookmark-jump via the command flow ends up calling the handler's
   jump-fn with the bookmark's record."
  (%ensure-bookmark-cmds-loaded)
  (limn/bookmark:bookmark-clear)
  (let ((received nil))
    (limn/bookmark:register-handler
     'unit-jumpable
     (lambda (rec) (setf received rec)))
    (limn/bookmark:bookmark-add
     (limn/bookmark:make-bookmark :name "only"
                                  :handler 'unit-jumpable
                                  :record '(:beacon "pong")))
    ;; In unit-tier with no live minibuffer, completing-read returns
    ;; the first candidate ("only") via its batch-mode fallback.
    (with-mock-minibuffer ("only")
      (limn/cmd:call-interactively (find-symbol "BOOKMARK-JUMP" :cl-user)))
    (assert-equal "pong" (getf received :beacon)
                  "handler received the record on jump")
    (limn/bookmark:unregister-handler 'unit-jumpable)))

;;; ── C3b. bookmark-set messaging branches (v0.37 ship-readiness) ───

(deftest bookmark-cmds-c3b-no-record-fn-doesnt-add
  "When the focused mode has NO record-fn at all, bookmark-set
   echoes 'isn't a bookmarkable mode yet' and adds nothing.
   (Distinguishable from c3-set-without-record-fn-noops because
   that fires the OLD message; we now distinguish 'no fn' from
   'fn returned nil'.)"
  (%ensure-bookmark-cmds-loaded)
  (limn/bookmark:bookmark-clear)
  (limn/mode:define-mode 'totally-unbookmarkable :type :major :modeline "ub")
  (limn/bookmark:unregister-record-fn 'totally-unbookmarkable)
  (with-mock-focused-mode (totally-unbookmarkable)
    (with-mock-minibuffer ("ghost")
      (handler-case
          (limn/cmd:call-interactively (find-symbol "BOOKMARK-SET" :cl-user))
        (error () nil))
      (assert-false (limn/bookmark:bookmark-find "ghost")
                    "no record-fn → no bookmark added")))
  (assert-false (gethash 'totally-unbookmarkable
                         limn/bookmark:*record-fn-registry*)
                "registry confirms no fn"))

(deftest bookmark-cmds-c3b-record-fn-returns-nil-doesnt-add
  "When the record-fn IS registered but returns NIL (e.g. an
   unsaved scratch buffer with no path), bookmark-set echoes
   'nothing to capture here' and adds nothing — different branch
   from 'no record-fn' above."
  (%ensure-bookmark-cmds-loaded)
  (limn/bookmark:bookmark-clear)
  (limn/mode:define-mode 'returns-nil-mode :type :major :modeline "rn")
  (limn/bookmark:register-record-fn 'returns-nil-mode (lambda () nil))
  (with-mock-focused-mode (returns-nil-mode)
    (with-mock-minibuffer ("ghost")
      (handler-case
          (limn/cmd:call-interactively (find-symbol "BOOKMARK-SET" :cl-user))
        (error () nil))
      (assert-false (limn/bookmark:bookmark-find "ghost")
                    "record-fn returned nil → no bookmark added")))
  (limn/bookmark:unregister-record-fn 'returns-nil-mode))

;;; ── C5. delete + rename via M-x ────────────────────────────────────

(deftest bookmark-cmds-c5-delete-via-cmd
  (%ensure-bookmark-cmds-loaded)
  (limn/bookmark:bookmark-clear)
  (limn/bookmark:bookmark-add
   (limn/bookmark:make-bookmark :name "to-delete"
                                :handler 'text-mode
                                :record '(:file "/x" :position 0)))
  (with-mock-minibuffer ("to-delete")
    (limn/cmd:call-interactively (find-symbol "BOOKMARK-DELETE" :cl-user)))
  (assert-false (limn/bookmark:bookmark-find "to-delete")
                "removed via M-x bookmark-delete"))
