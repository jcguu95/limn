;;;; v0.40 §W mark-ring: M-o (Alt+O) on Linux X11 reproduction.
;;;;
;;;; Question being answered: when a user dogfooding on macOS reports
;;;; that C-o (pdf-jump-back) works but M-o (pdf-jump-forward) does NOT,
;;;; is that:
;;;;   (a) a macOS-only issue (Option-key swallowed by macOS input layer)
;;;;   (b) a keymap/dispatch issue (Linux fires KeyPress but cmd doesn't run)
;;;;   (c) a Qt-level input-filter issue (Linux also doesn't fire KeyPress)
;;;;
;;;; This driver runs inside the Linux Xvfb container where no macOS
;;;; intercept exists.  It opens the test PDF, jumps to last page (G),
;;;; presses C-o to jump back, then M-o to jump forward, capturing:
;;;;
;;;;   - stderr [limn-input] KeyPress lines (proves Qt saw the event)
;;;;   - view/get :|page| before/after each press (proves command ran)
;;;;
;;;; Each step is then classified into (a)/(b)/(c).

(in-package :cl-user)
(require :sb-posix)
(require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(load (b/ "tests/e2e/load-limn-system.lisp"))

(defun xdotool (&rest args)
  (let ((p (sb-ext:run-program "xdotool" args :search t
                                :wait t :output t :error t)))
    (unless (zerop (sb-ext:process-exit-code p))
      (error "xdotool ~{~a~^ ~} exited non-zero" args))))

(defun wait-for-window-by-name (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((p (sb-ext:run-program "xdotool"
                                    (list "search" "--name" name)
                                    :search t :wait t :output nil)))
        (when (zerop (sb-ext:process-exit-code p))
          (return t)))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

(defparameter *log-path* "/tmp/limn-os-v040-mo.log")

(defun count-keypress-lines-since (offset)
  "Count [limn-input] KeyPress lines in the limn stderr log since OFFSET bytes,
   returning (new-count, new-offset, snippet-string)."
  (with-open-file (s *log-path* :direction :input
                                :if-does-not-exist nil)
    (if (null s)
        (values 0 offset "")
        (progn
          (file-position s offset)
          (let ((lines (loop for line = (read-line s nil nil)
                             while line collect line))
                (new-offset (file-position s)))
            (let ((kps (remove-if-not
                        (lambda (l) (search "[limn-input] KeyPress" l))
                        lines)))
              (values (length kps) new-offset
                      (format nil "~{    ~a~%~}" kps))))))))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "OK" "FAIL") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun current-page ()
  (let* ((r (limn:call "view/get" :|win-id| "w1"))
         (d (data r)))
    (getf d :|page|)))

(defun engine-load (path)
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "mupdf" :|path| path :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(let* ((sock (format nil "/tmp/limn-e2e-v040mo-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output *log-path*
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window-by-name "Limn" :timeout 5)

  (let ((b (engine-load (b/ "tests/fixtures/test.pdf"))))
    (check (format nil "buffer-id = ~a" b) (stringp b))
    (sleep 0.3)

    ;; Give X focus to the Limn window so xdotool keys land on it.
    ;; (windowfocus fails BadMatch on Xvfb sometimes; windowactivate
    ;; alone is enough — other drivers don't even do that.)
    (let ((p (sb-ext:run-program "xdotool"
                                  (list "search" "--name" "Limn")
                                  :search t :wait t :output :stream)))
      (let ((wid (read-line (sb-ext:process-output p) nil nil)))
        (when (and wid (not (string= wid "")))
          (handler-case (xdotool "windowactivate" "--sync" wid)
            (error (e) (format t "  (windowactivate failed: ~a)~%" e))))))
    (sleep 0.3)

    ;; Tap the raw key event hook so we can see what backend sees.
    (defparameter *key-events* nil)
    (limn:on-event "key" (lambda (ev) (push ev *key-events*)))

    ;; Probe what binding pdf-mode actually has for C-o and M-o.
    ;; install() uses (intern "PDF-MODE" :cl-user), so do the same here.
    (let* ((find-m (find-symbol "FIND-MODE" :limn/mode))
           (m-km   (find-symbol "MODE-KEYMAP" :limn/mode))
           (lookup (find-symbol "LOOKUP-SEQUENCE" :limn/keys))
           (sym-cl (intern "PDF-MODE" :cl-user))
           (sym-pm (intern "PDF-MODE" :limn/pdf-mode))
           (m-cl   (funcall find-m sym-cl))
           (m-pm   (funcall find-m sym-pm)))
      (format t "  pdf-mode (cl-user) mode-obj = ~a~%" m-cl)
      (format t "  pdf-mode (limn/pdf-mode) mode-obj = ~a~%" m-pm)
      (let ((km-cl (and m-cl (funcall m-km m-cl)))
            (km-pm (and m-pm (funcall m-km m-pm))))
        (format t "  km(cl) = ~a~%" km-cl)
        (format t "  km(pm) = ~a~%" km-pm)
        (let ((km (or km-cl km-pm)))
          (when km
            (format t "    C-o → ~a~%" (funcall lookup km '("C-o")))
            (format t "    M-o → ~a~%" (funcall lookup km '("M-o")))
            (format t "    o   → ~a~%" (funcall lookup km '("o")))))))

    (format t "~%── initial state ──~%")
    (format t "  current-page = ~a (expect 0)~%" (current-page))
    ;; Inspect active modes to see if pdf-mode actually got activated.
    (let* ((sym-mb (find-symbol "MODE-BUFFER-FOR-WINDOW" :limn/runtime))
           (mb (and sym-mb (funcall sym-mb "w1"))))
      (format t "  mode-buffer for w1 = ~a~%" mb)
      (when mb
        (let* ((maj-sym (find-symbol "MAJOR-MODE" :limn/mode))
               (min-sym (find-symbol "MINOR-MODES" :limn/mode)))
          (format t "    major-mode = ~a~%" (and maj-sym (funcall maj-sym mb)))
          (format t "    minor-modes = ~a~%" (and min-sym (funcall min-sym mb))))))

    (let ((page-count
            (let* ((r (limn:call "view/get" :|win-id| "w1"))
                   (d (data r)))
              (getf d :|page-count|))))
      (format t "  page-count   = ~a~%" page-count))

    ;; STEP 1: press G (Shift+g) → pdf-goto-page interactively defaults
    ;; to last page in this implementation? Actually the keymap binds G
    ;; to PDF-GOTO-PAGE which prompts.  Use Shift+End or just type G then
    ;; Enter.  But to keep things simple, use J (next-page) several
    ;; times — it's bound and pushes a mark on each big jump.  Actually
    ;; the mark-ring §W is intended for *big* jumps (G / search / TOC /
    ;; etc).  Looking at the keymap: "J" -> pdf-next-page (single-step,
    ;; no mark).  We need a *big-jump* command that pushes the mark.
    ;;
    ;; Look at line 660 ("v0.40 §W: record pre-jump position so C-o
    ;; (pdf-jump-back) can return.")  That likely wraps pdf-goto-page
    ;; and pdf-isearch and pdf-toc.  Simplest reproducible big-jump that
    ;; doesn't need a prompt: skip G, just directly call view/set to
    ;; move to a different page (the wire bypasses the keymap, but that
    ;; doesn't push a mark — so C-o would say "no previous position").
    ;;
    ;; To exercise the keymap path AND get a mark recorded, we need to
    ;; trigger a defcmd that records.  Easiest: use the wire
    ;; cmd/run-by-name to invoke pdf-goto-page with a numeric prefix arg
    ;; OR just push a fake mark via the lisp API for ring shape, then
    ;; test the *key-press dispatch* side independently with a
    ;; preloaded ring.
    ;;
    ;; For this diagnostic we only need to know: does Qt fire KeyPress
    ;; for alt+o on Linux?  Page change is a secondary signal.  So:
    ;;
    ;; STEP 1: capture the offset, press ctrl+o, observe page + log
    ;; STEP 2: capture the offset, press alt+o,  observe page + log
    ;; That alone disambiguates (a)/(b)/(c).

    ;; Helper: prime the mark-rings via a known-good code path so the
    ;; C-o and M-o keys have something to act on.  We just stuff a
    ;; couple of fake marks into the back-ring directly.  Each mark is
    ;; a plist with :buffer-id :page :y.
    (let ((fake-mark (list :|buffer-id| b :|page| 3 :|y| 0.0)))
      (eval `(let ((sym (find-symbol "%PDF-SET-BACK-RING" :limn/pdf-mode)))
               (when sym
                 (funcall sym (list ',fake-mark))))))
    (format t "~%  (primed back-ring with one fake mark @ page 3)~%")

    ;; PROBE: ring state after priming
    (let ((br (find-symbol "%PDF-BACK-RING" :limn/pdf-mode))
          (fr (find-symbol "%PDF-FORWARD-RING" :limn/pdf-mode))
          (cw (find-symbol "*CURRENT-WIN-ID*" :limn/pdf-mode)))
      (format t "  *current-win-id* = ~s~%" (and cw (symbol-value cw)))
      (format t "  back-ring = ~s~%" (and br (funcall br)))
      (format t "  forward-ring = ~s~%" (and fr (funcall fr))))

    ;; PROBE: call pdf-jump-back via limn/cmd:call-interactively.
    (format t "~%── PROBE: limn/cmd:call-interactively PDF-JUMP-BACK ──~%")
    (let ((before (current-page))
          (ci (find-symbol "CALL-INTERACTIVELY" :limn/cmd))
          (cmd (find-symbol "PDF-JUMP-BACK" :cl-user)))
      (format t "  call-interactively = ~a, cmd-sym = ~a~%" ci cmd)
      (when (and ci cmd)
        (handler-case (funcall ci cmd)
          (error (e) (format t "  ERROR from call-interactively: ~a~%" e))))
      (sleep 0.3)
      (let ((after (current-page)))
        (format t "  page before=~a → after=~a~%" before after)))

    ;; PROBE: can we actually move the page via wire at all?
    (format t "~%── PROBE: direct view/set page=3 over wire ──~%")
    (let ((before (current-page))
          (r (limn:call "view/set" :|win-id| "w1" :|page| 3)))
      (format t "  wire response: ~a~%" r)
      (sleep 0.3)
      (let ((after (current-page)))
        (format t "  page before=~a → after=~a~%" before after)))

    ;; PROBE: invoke the keymap binding lambda directly
    (format t "~%── PROBE: invoke keymap binding for C-o directly ──~%")
    (let* ((before (current-page))
           (find-m (find-symbol "FIND-MODE" :limn/mode))
           (m-km   (find-symbol "MODE-KEYMAP" :limn/mode))
           (lookup (find-symbol "LOOKUP-SEQUENCE" :limn/keys))
           (m (funcall find-m (intern "PDF-MODE" :cl-user)))
           (km (funcall m-km m))
           (binding (funcall lookup km '("C-o"))))
      (format t "  binding = ~a~%" binding)
      (when (functionp binding)
        (handler-case
            (funcall binding '(:|frame-id| "f1" :|win-id| "w1"
                                :|key| "o" :|mods| ("ctrl")))
          (error (e) (format t "  ERROR from binding: ~a~%" e))))
      (sleep 0.3)
      (let ((after (current-page)))
        (format t "  page before=~a → after=~a~%" before after)))

    ;; STEP 0: Directly invoke %dispatch-key with a synthetic C-o event.
    ;; This bypasses the wire/hook layer entirely so any failure isolates
    ;; into either dispatch logic OR command body.
    (format t "~%── STEP 0: direct (%dispatch-key '(:key \"o\" :mods (ctrl))) ──~%")
    (let ((before (current-page))
          (disp (find-symbol "%DISPATCH-KEY" :limn)))
      (format t "  %dispatch-key found = ~a~%" disp)
      (when disp
        (handler-case
            (funcall disp '(:|frame-id| "f1" :|key| "o" :|mods| ("ctrl")))
          (error (e) (format t "  dispatch error: ~a~%" e))))
      (sleep 0.3)
      (let ((after (current-page)))
        (format t "  page before=~a → after=~a~%" before after)))

    (format t "~%── STEP 0b: direct M-o ──~%")
    (let ((before (current-page))
          (disp (find-symbol "%DISPATCH-KEY" :limn)))
      (when disp
        (handler-case
            (funcall disp '(:|frame-id| "f1" :|key| "o" :|mods| ("alt")))
          (error (e) (format t "  dispatch error: ~a~%" e))))
      (sleep 0.3)
      (let ((after (current-page)))
        (format t "  page before=~a → after=~a~%" before after)))

    ;; ── STEP 1: ctrl+o ─────────────────────────────────────
    (format t "~%── STEP 1: xdotool key ctrl+o (C-o = pdf-jump-back) ──~%")
    (let ((before (current-page))
          (off (with-open-file (s *log-path* :direction :input)
                 (file-length s))))
      (setf *key-events* nil)
      (xdotool "key" "--clearmodifiers" "ctrl+o")
      (sleep 0.5)
      (multiple-value-bind (n new-off snippet)
          (count-keypress-lines-since off)
        (declare (ignore new-off))
        (let ((after (current-page)))
          (format t "  page before=~a → after=~a~%" before after)
          (format t "  [limn-input] KeyPress lines = ~a~%~a"
                  n snippet)
          (format t "  backend received key events: ~a~%" *key-events*)
          (check "C-o: Qt KeyPress fired" (>= n 1)
                 (format nil "n=~a" n))
          (check "C-o: backend received key event"
                 (>= (length *key-events*) 1)
                 (format nil "got ~a events" (length *key-events*)))
          (check "C-o: page changed (jump-back acted)"
                 (not (eql before after))
                 (format nil "before=~a after=~a" before after)))))

    ;; The C-o just moved us back to page 3; the forward-ring now has
    ;; the old position (page 0 if we hadn't moved yet, or whatever).
    ;; So M-o should be able to jump forward.

    ;; ── STEP 2: alt+o ─────────────────────────────────────
    (format t "~%── STEP 2: xdotool key alt+o (M-o = pdf-jump-forward) ──~%")
    (let ((before (current-page))
          (off (with-open-file (s *log-path* :direction :input)
                 (file-length s))))
      (setf *key-events* nil)
      (xdotool "key" "--clearmodifiers" "alt+o")
      (sleep 0.5)
      (multiple-value-bind (n new-off snippet)
          (count-keypress-lines-since off)
        (declare (ignore new-off))
        (let ((after (current-page)))
          (format t "  page before=~a → after=~a~%" before after)
          (format t "  [limn-input] KeyPress lines = ~a~%~a"
                  n snippet)
          (format t "  backend received key events: ~a~%" *key-events*)
          (check "M-o: Qt KeyPress fired (Linux has no Option-key swallow)"
                 (>= n 1)
                 (format nil "n=~a" n))
          (check "M-o: backend received key event"
                 (>= (length *key-events*) 1)
                 (format nil "got ~a events" (length *key-events*)))
          (check "M-o: page changed (jump-forward acted)"
                 (not (eql before after))
                 (format nil "before=~a after=~a" before after)))))

    ;; ── STEP 3: also try the bare alt+o with `meta` modifier to
    ;; cover the Qt::MetaModifier path that fires on macOS for real
    ;; Ctrl-o.  On Linux xdotool, `meta` is usually the windows key.
    (format t "~%── STEP 3: xdotool key meta+o (should also be M-o per wire) ──~%")
    (let ((before (current-page))
          (off (with-open-file (s *log-path* :direction :input)
                 (file-length s))))
      (handler-case
          (xdotool "key" "--clearmodifiers" "Meta_L+o")
        (error (e) (format t "  (Meta_L+o failed: ~a)~%" e)))
      (sleep 0.3)
      (multiple-value-bind (n new-off snippet)
          (count-keypress-lines-since off)
        (declare (ignore new-off))
        (let ((after (current-page)))
          (format t "  page before=~a → after=~a~%" before after)
          (format t "  [limn-input] KeyPress lines = ~a~%~a"
                  n snippet))))

    ;; Final verdict
    (format t "~%════════════════════════════════════════════════════════════~%")
    (format t "  VERDICT (on Linux X11):~%")
    (format t "    failures = ~a~%" *failures*)
    (format t "════════════════════════════════════════════════════════════~%~%")

    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (sleep 0.3)
    (sb-ext:exit :code (if (null *failures*) 0 1))))
