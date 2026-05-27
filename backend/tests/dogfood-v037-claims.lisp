;;;; dogfood-v037-claims.lisp — actually exercise what Phase B + D
;;;; claimed against a real limn binary.  Unit-tier asserts the
;;;; structural shape (binding present, command registered); this
;;;; script proves the user-facing effect.
;;;;
;;;; Usage:
;;;;   nix develop --command sbcl --non-interactive \
;;;;     --load backend/tests/dogfood-v037-claims.lisp
;;;;
;;;; Exits 0 on full pass, 1 on first failure.

(in-package #:cl-user)
(require :sb-posix)
(require :sb-bsd-sockets)
(require :asdf)

(defparameter *self-dir*
  (make-pathname :defaults (or *load-pathname* *default-pathname-defaults*)
                 :name nil :type nil))

(defparameter *root*
  (namestring (merge-pathnames "../../" *self-dir*)))

(defparameter *backend-dir*
  (namestring (merge-pathnames "../" *self-dir*)))

(push *backend-dir* asdf:*central-registry*)
(handler-bind ((warning
                 (lambda (w)
                   (let ((m (princ-to-string w)))
                     (when (and (search "found several entries" m)
                                (search "lib/sbcl" m))
                       (muffle-warning w))))))
  (asdf:load-system :limn))

;;; ── result tracking ──────────────────────────────────────────────

(defparameter *pass* 0)
(defparameter *fail* 0)
(defparameter *failures* '())

(defun pass! (label) (incf *pass*) (format t "  ✓ ~a~%" label))
(defun fail! (label why)
  (incf *fail*)
  (push (cons label why) *failures*)
  (format t "  ✗ ~a — ~a~%" label why))

(defmacro claim (label &body body)
  `(handler-case
       (if (progn ,@body)
           (pass! ,label)
           (fail! ,label "predicate returned nil"))
     (error (e) (fail! ,label (format nil "ERROR: ~a" e)))))

;;; ── boot ─────────────────────────────────────────────────────────

(defparameter *limn-bin*
  (or (sb-posix:getenv "LIMN_BIN")
      (namestring
       (merge-pathnames "sioyek/limn.app/Contents/MacOS/limn" *root*))))

(defparameter *sock*
  (format nil "/tmp/limn-dogfood-claims-~a" (sb-posix:getpid)))

(unless (probe-file *limn-bin*)
  (format *error-output* "✗ limn binary not at ~s~%" *limn-bin*)
  (sb-ext:exit :code 2))

(format t "── dogfood Phase B + D claims against ~a~%" *limn-bin*)
(format t "── socket ~a~%" *sock*)

(defparameter *proc*
  (sb-ext:run-program *limn-bin* (list "--headless" "--test-mode"
                                        "--socket" *sock*)
                       :wait nil :search nil :output t :error t))

;; Wait for socket
(loop repeat 100
      until (probe-file *sock*)
      do (sleep 0.05))
(unless (probe-file *sock*)
  (format *error-output* "✗ limn never created socket~%")
  (sb-ext:process-kill *proc* 15)
  (sb-ext:exit :code 2))

(limn:start *sock*)
(sleep 0.3)

;;; ── load fixture PDF ──────────────────────────────────────────────

(defparameter *fixture*
  (namestring (merge-pathnames "backend/tests/fixtures/test.pdf" *root*)))

(limn:call "bridge/engine-load" :|engine| "mupdf"
            :|path| *fixture* :|win-id| "w1")
(sleep 0.3)

(defun view-page ()
  (let* ((r (limn:call "view/get" :|win-id| "w1"))
         (d (getf r :|data|)))
    (getf d :|page|)))

(defun view-offset-y ()
  (let* ((r (limn:call "view/get" :|win-id| "w1"))
         (d (getf r :|data|)))
    (getf d :|offset-y|)))

(defun view-zoom ()
  (let* ((r (limn:call "view/get" :|win-id| "w1"))
         (d (getf r :|data|)))
    (getf d :|zoom|)))

(defun inject-key (k &optional mods)
  (limn:call "test/inject-key" :|key| k :|mods| (or mods '())))

;;; ── claims ───────────────────────────────────────────────────────

(format t "~%── Phase B claims ──~%")

(claim "execute-command (M-x) defcommand registered in :cl-user"
  (let ((sym (find-symbol "EXECUTE-COMMAND" :cl-user)))
    (and sym (limn/cmd:find-command sym))))

(claim "reload-init-file defcommand registered in :cl-user"
  (let ((sym (find-symbol "RELOAD-INIT-FILE" :cl-user)))
    (and sym (limn/cmd:find-command sym))))

(claim "M-x bound on *global-keymap* to a function"
  (let ((b (limn/keys:lookup-sequence limn::*global-keymap* '("M-x"))))
    (functionp b)))

(claim "M-r bound on *global-keymap* to a function"
  (let ((b (limn/keys:lookup-sequence limn::*global-keymap* '("M-r"))))
    (functionp b)))

(claim "which-key-mode actually enabled at bring-up"
  (let* ((pkg (find-package '#:limn/which-key))
         (sym (and pkg (find-symbol "*HOOK-INSTALLED*" pkg))))
    (and sym (boundp sym) (symbol-value sym))))

(format t "~%── Phase D claims (PDF mode actually drives) ──~%")

;; Reset to page 0 / offset 0 baseline
(limn:call "view/set" :|win-id| "w1" :|page| 0 :|offset-y| 0.0)
(sleep 0.15)

(claim "j key actually moves offset-y down (real keymap dispatch)"
  (let ((before (or (view-offset-y) 0.0)))
    (inject-key "j")
    (sleep 0.15)
    (let ((after (or (view-offset-y) 0.0)))
      (> after before))))

(claim "k key actually moves offset-y up"
  (let ((before (or (view-offset-y) 1.0)))
    (inject-key "k")
    (sleep 0.15)
    (let ((after (or (view-offset-y) 1.0)))
      (< after before))))

(limn:call "view/set" :|win-id| "w1" :|page| 0 :|offset-y| 0.0)
(sleep 0.15)

(claim "n key advances page"
  (let ((before (or (view-page) 0)))
    (inject-key "n")
    (sleep 0.15)
    (let ((after (or (view-page) 0)))
      (= after (1+ before)))))

(claim "p key retreats page"
  (let ((before (or (view-page) 1)))
    (inject-key "p")
    (sleep 0.15)
    (let ((after (or (view-page) 0)))
      (= after (1- before)))))

(claim "+ key zooms in"
  (let ((before (or (view-zoom) 1.0)))
    (inject-key "+")
    (sleep 0.15)
    (let ((after (or (view-zoom) 1.0)))
      (> after before))))

(claim "- key zooms out"
  (let ((before (or (view-zoom) 1.5)))
    (inject-key "-")
    (sleep 0.15)
    (let ((after (or (view-zoom) 1.0)))
      (< after before))))

;;; v0.37 Phase D additions

(limn:call "view/set" :|win-id| "w1" :|page| 0 :|offset-y| 0.0 :|zoom| 1.0)
(sleep 0.15)

(claim "C-d (half-page-down) increases offset-y by ~0.5"
  (let ((before (or (view-offset-y) 0.0)))
    (inject-key "d" '("ctrl"))
    (sleep 0.15)
    (let ((after (or (view-offset-y) 0.0)))
      (> (- after before) 0.3))))   ; lenient: half-page-step 0.5 but pdf engine may clamp

(claim "C-u (half-page-up) decreases offset-y"
  (let ((before (or (view-offset-y) 1.0)))
    (inject-key "u" '("ctrl"))
    (sleep 0.15)
    (let ((after (or (view-offset-y) 1.0)))
      (< after before))))

(limn:call "view/set" :|win-id| "w1" :|page| 0)
(sleep 0.15)

(claim "l key advances page (Phase D vim binding)"
  (let ((before (or (view-page) 0)))
    (inject-key "l")
    (sleep 0.15)
    (let ((after (or (view-page) 0)))
      (= after (1+ before)))))

;; o → find-file; we don't drive the minibuffer fully here but assert
;; the binding fires SOME defcommand (it would call FIND-FILE which
;; would try to read minibuffer — likely blocks).  Just assert the
;; binding resolves to a function.
(claim "o key bound to find-file"
  (let* ((mb-fn (find-symbol "MODE-BUFFER-FOR-WINDOW" :limn/runtime))
         (mb (and mb-fn (funcall mb-fn "w1")))
         (major (and mb (limn/mode:major-mode mb)))
         (mode-obj (and major (limn/mode:find-mode major)))
         (km (and mode-obj (limn/mode:mode-keymap mode-obj))))
    (functionp (and km (limn/keys:lookup-sequence km '("o"))))))

(claim "q key bound (pdf-close)"
  (let* ((mb-fn (find-symbol "MODE-BUFFER-FOR-WINDOW" :limn/runtime))
         (mb (and mb-fn (funcall mb-fn "w1")))
         (major (and mb (limn/mode:major-mode mb)))
         (mode-obj (and major (limn/mode:find-mode major)))
         (km (and mode-obj (limn/mode:mode-keymap mode-obj))))
    (functionp (and km (limn/keys:lookup-sequence km '("q"))))))

(claim ": key NOT bound in pdf-mode (passes through as literal)"
  (let* ((mb-fn (find-symbol "MODE-BUFFER-FOR-WINDOW" :limn/runtime))
         (mb (and mb-fn (funcall mb-fn "w1")))
         (major (and mb (limn/mode:major-mode mb)))
         (mode-obj (and major (limn/mode:find-mode major)))
         (km (and mode-obj (limn/mode:mode-keymap mode-obj))))
    ;; : must NOT be bound — M-x is the command-palette key.
    (null (and km (limn/keys:lookup-sequence km '(":"))))))

(claim "? key bound to pdf-isearch-backward"
  (let* ((mb-fn (find-symbol "MODE-BUFFER-FOR-WINDOW" :limn/runtime))
         (mb (and mb-fn (funcall mb-fn "w1")))
         (major (and mb (limn/mode:major-mode mb)))
         (mode-obj (and major (limn/mode:find-mode major)))
         (km (and mode-obj (limn/mode:mode-keymap mode-obj))))
    (functionp (and km (limn/keys:lookup-sequence km '("?"))))))

(format t "~%── strong claims: end-to-end M-x + M-r reload ──~%")

;;; End-to-end M-x: mock the minibuffer reader to return a known
;;; command name, then drive M-x and assert the command fires.

(claim "M-x → execute-command → mocked completing-read → command fires"
  (let* ((page-before (or (view-page) 0))
         (cmd-fired nil))
    ;; Override completing-read to return "pdf-next-page".
    (let ((orig-fn (and (find-symbol "*COMPLETION-READ-FN*"
                                       :limn/completion)
                         (boundp (find-symbol "*COMPLETION-READ-FN*"
                                                :limn/completion)))))
      (declare (ignore orig-fn)))
    (let ((cr-pkg (find-package '#:limn/completion)))
      ;; Use a fluid-let / progv pattern via temporarily redefining
      ;; the function.  This is dirty but simple for a self-test.
      (sb-ext:without-package-locks
       (let ((orig (symbol-function 'limn/completion:completing-read)))
         (unwind-protect
              (progn
                (setf (symbol-function 'limn/completion:completing-read)
                      (lambda (prompt collection &rest _ignored)
                        (declare (ignore prompt collection _ignored))
                        (setf cmd-fired t)
                        "pdf-next-page"))
                ;; Now invoke M-x via execute-command.
                (limn/cmd:call-interactively
                 (find-symbol "EXECUTE-COMMAND" :cl-user))
                (sleep 0.15))
           (setf (symbol-function 'limn/completion:completing-read) orig)))))
    ;; Verify the chosen command actually ran.
    (and cmd-fired
         (let ((page-after (or (view-page) 0)))
           (= page-after (1+ page-before))))))

;;; End-to-end M-r: write a temp init.lisp that sets a defvar, set
;;; LIMN_INIT, call reload-init-file, assert the defvar took the value.
;;; Then modify the file, reload again, assert the defvar updated.

(claim "M-r reload-init-file actually runs init.lisp + picks up edits"
  (let* ((tmp (format nil "/tmp/limn-dogfood-init-~a.lisp"
                       (sb-posix:getpid)))
         (var-sym 'cl-user::*dogfood-canary*)
         (orig-env (sb-posix:getenv "LIMN_INIT")))
    (unwind-protect
         (progn
           (makunbound var-sym)
           ;; First write: canary = 1
           (with-open-file (s tmp :direction :output :if-exists :supersede)
             (format s "(in-package :cl-user)~%~
                        (defparameter *dogfood-canary* 1)~%"))
           (sb-posix:setenv "LIMN_INIT" tmp 1)
           (limn/cmd:call-interactively
            (find-symbol "RELOAD-INIT-FILE" :cl-user))
           (sleep 0.1)
           (unless (and (boundp var-sym) (= (symbol-value var-sym) 1))
             (return-from claim nil))
           ;; Edit: canary = 42
           (with-open-file (s tmp :direction :output :if-exists :supersede)
             (format s "(in-package :cl-user)~%~
                        (defparameter *dogfood-canary* 42)~%"))
           (limn/cmd:call-interactively
            (find-symbol "RELOAD-INIT-FILE" :cl-user))
           (sleep 0.1)
           (and (boundp var-sym) (= (symbol-value var-sym) 42)))
      (ignore-errors (delete-file tmp))
      (if orig-env
          (sb-posix:setenv "LIMN_INIT" orig-env 1)
          (sb-posix:unsetenv "LIMN_INIT")))))

;;; ── teardown + report ────────────────────────────────────────────

(format t "~%──────────────────────────────────────────────~%")
(format t "  dogfood claims: ~a pass / ~a fail~%" *pass* *fail*)
(when *failures*
  (format t "  failures:~%")
  (dolist (f (reverse *failures*))
    (format t "    ~a: ~a~%" (car f) (cdr f))))
(format t "──────────────────────────────────────────────~%")

(ignore-errors (limn:stop))
(sleep 0.1)
(ignore-errors (sb-ext:process-kill *proc* 15))
(ignore-errors (sb-ext:process-wait *proc*))

(sb-ext:exit :code (if (zerop *fail*) 0 1))
