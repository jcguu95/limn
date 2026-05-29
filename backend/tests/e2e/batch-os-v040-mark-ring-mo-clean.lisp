;;;; CLEAN reproducer — v0.40 §W mark-ring on Linux X11.
;;;;
;;;; No prime/probe side-effects.  Just:
;;;;
;;;;   1. open the test PDF
;;;;   2. wire-jump to page 3 (this leaves *current-page* = 3, but does
;;;;      NOT touch the mark-ring — mark-ring is only populated by
;;;;      big-jump *commands* (pdf-goto-page / pdf-isearch-forward /
;;;;      pdf-toc / pdf-jump-bookmark), per v0.40 §W contract).
;;;;
;;;;   3. invoke pdf-goto-page via cmd registry with prefix-arg 5 —
;;;;      that records the pre-jump position on the back-ring AND jumps.
;;;;      (Same as user typing `5 G`.)
;;;;
;;;;   4. xdotool key ctrl+o  → expect page to change back to 3.
;;;;   5. xdotool key alt+o   → expect page to change back to 5.
;;;;
;;;; Each step prints:
;;;;   - current page before / after
;;;;   - any new [limn-input] KeyPress lines in the binary's stderr log
;;;;   - any new wire key events seen by the backend

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

(defparameter *log-path* "/tmp/limn-os-v040-mo-clean.log")
(defparameter *key-events* nil)

(defun snapshot-new-keypresses (offset)
  (with-open-file (s *log-path* :direction :input :if-does-not-exist nil)
    (if (null s)
        (values 0 offset "")
        (progn
          (file-position s offset)
          (let* ((lines (loop for ln = (read-line s nil nil)
                              while ln collect ln))
                 (new-off (file-position s))
                 (kps (remove-if-not
                       (lambda (l) (search "[limn-input] KeyPress" l))
                       lines)))
            (values (length kps) new-off
                    (format nil "~{      ~a~%~}" kps)))))))

(defun current-page ()
  (let* ((r (limn:call "view/get" :|win-id| "w1"))
         (d (getf r :|data|)))
    (getf d :|page|)))

(defun engine-load (path)
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "mupdf" :|path| path :|win-id| "w1")))
    (getf (getf r :|data|) :|buffer-id|)))

(let* ((sock (format nil "/tmp/limn-e2e-v040moc-~a" (sb-posix:getpid)))
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

  (limn:on-event "key" (lambda (ev) (push ev *key-events*)))

  (let ((b (engine-load (b/ "tests/fixtures/test.pdf"))))
    (format t "── setup ──~%")
    (format t "  buffer-id = ~a, current-page = ~a~%" b (current-page))
    (sleep 0.3)

    ;; Setup: invoke pdf-goto-page with prefix=5 via cmd registry
    ;; (mimics the user typing `5 G`).  This is a big-jump command
    ;; wrapped to record the back-ring entry per §W.
    (format t "~%── arrange: call PDF-GOTO-PAGE with prefix-arg 5 ──~%")
    (let* ((ci (find-symbol "CALL-INTERACTIVELY" :limn/cmd))
           (pa (find-symbol "*PREFIX-ARG*"     :limn/cmd))
           (cmd (find-symbol "PDF-GOTO-PAGE" :cl-user)))
      (progv (list pa) (list 5)
        (handler-case (funcall ci cmd)
          (error (e) (format t "  ERROR: ~a~%" e))))
      (sleep 0.4))
    (format t "  current-page after goto = ~a~%" (current-page))

    (let* ((br (find-symbol "%PDF-BACK-RING" :limn/pdf-mode))
           (fr (find-symbol "%PDF-FORWARD-RING" :limn/pdf-mode)))
      (format t "  back-ring    = ~s~%" (and br (funcall br)))
      (format t "  forward-ring = ~s~%" (and fr (funcall fr))))

    ;; ── ACT 1: xdotool key ctrl+o ─────────────────────────
    (format t "~%════════════════════════════════════════════════════════════~%")
    (format t "  ACT 1: xdotool key --clearmodifiers ctrl+o (= C-o)~%")
    (format t "════════════════════════════════════════════════════════════~%")
    (let* ((before (current-page))
           (off (with-open-file (s *log-path*) (file-length s))))
      (setf *key-events* nil)
      (xdotool "key" "--clearmodifiers" "ctrl+o")
      (sleep 0.5)
      (multiple-value-bind (n new-off snippet)
          (snapshot-new-keypresses off)
        (declare (ignore new-off))
        (let ((after (current-page)))
          (format t "    page before = ~a~%" before)
          (format t "    page after  = ~a~%" after)
          (format t "    [limn-input] KeyPress lines fired = ~a~%~a"
                  n snippet)
          (format t "    backend received key events = ~a~%" *key-events*))))

    ;; ── ACT 2: xdotool key alt+o ──────────────────────────
    (format t "~%════════════════════════════════════════════════════════════~%")
    (format t "  ACT 2: xdotool key --clearmodifiers alt+o (= M-o)~%")
    (format t "════════════════════════════════════════════════════════════~%")
    (let* ((before (current-page))
           (off (with-open-file (s *log-path*) (file-length s))))
      (setf *key-events* nil)
      (xdotool "key" "--clearmodifiers" "alt+o")
      (sleep 0.5)
      (multiple-value-bind (n new-off snippet)
          (snapshot-new-keypresses off)
        (declare (ignore new-off))
        (let ((after (current-page)))
          (format t "    page before = ~a~%" before)
          (format t "    page after  = ~a~%" after)
          (format t "    [limn-input] KeyPress lines fired = ~a~%~a"
                  n snippet)
          (format t "    backend received key events = ~a~%" *key-events*))))

    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (sleep 0.3)
    (sb-ext:exit :code 0)))
