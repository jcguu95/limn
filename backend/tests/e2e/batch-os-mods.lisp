;;;; A12: modifier 組合 — verify modifiers come through bridge correctly.
;;;;
;;;; SPEC §6 key event 帶 mods array。當前 case_encodes_shift 約定（per
;;;; limn_input.cpp）：single printable char + shift → 大寫字 + 不帶 shift
;;;; mod；non-printable named key + shift → 帶 shift mod。這個 driver
;;;; pinning 該行為：
;;;;
;;;;   xdotool key ctrl+alt+x        → key="x" mods=["alt","ctrl"]
;;;;   xdotool key ctrl+alt+shift+x  → key="X" mods=["alt","ctrl"]
;;;;                                   (shift case-encoded、不在 mods)
;;;;   xdotool key ctrl+alt+shift+F1 → key=<key-...> mods=["alt","ctrl","shift"]
;;;;                                   (F1 非 printable、shift 不被吞)

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

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

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-mods"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details)
    (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defparameter *last-key-event* nil)

(defun drain-and-capture ()
  ;; Hook fires on event/key; reset before each shot.
  (setf *last-key-event* nil)
  (sleep 0.05))

(let* ((sock (format nil "/tmp/limn-e2e-mods-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-mods.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window-by-name "Limn" :timeout 5)

  (limn:on-event "key" (lambda (ev) (setf *last-key-event* ev)))

  (format t "~%── A12: modifier combinations ──~%")

  ;; Case 1: C-M-x (two non-shift modifiers, lowercase letter)
  (drain-and-capture)
  (xdotool "key" "--clearmodifiers" "ctrl+alt+x")
  (sleep 0.3)
  (let* ((ev *last-key-event*)
         (key (and ev (getf ev :|key|)))
         (mods (and ev (getf ev :|mods|))))
    (check "C-M-x → key=\"x\""
           (equal key "x") (format nil "got key=~s" key))
    (check "C-M-x → mods contains ctrl + alt (or meta)"
           (and (find "ctrl" mods :test #'string=)
                (or (find "alt"  mods :test #'string=)
                    (find "meta" mods :test #'string=)))
           (format nil "got mods=~s" mods))
    (check "C-M-x → shift NOT in mods"
           (not (find "shift" mods :test #'string=))
           (format nil "got mods=~s" mods)))

  ;; Case 2: C-M-S-x — shift should be case-encoded (X), NOT reported
  ;; in mods because the letter itself is already shifted.
  (drain-and-capture)
  (xdotool "key" "--clearmodifiers" "ctrl+alt+shift+x")
  (sleep 0.3)
  (let* ((ev *last-key-event*)
         (key (and ev (getf ev :|key|)))
         (mods (and ev (getf ev :|mods|))))
    (check "C-M-S-x → key=\"X\" (shift case-encoded)"
           (equal key "X") (format nil "got key=~s" key))
    (check "C-M-S-x → shift NOT in mods (case_encodes_shift)"
           (not (find "shift" mods :test #'string=))
           (format nil "got mods=~s" mods)))

  ;; Case 3: C-M-S-F1 — non-printable key, shift IS reported.
  (drain-and-capture)
  (xdotool "key" "--clearmodifiers" "ctrl+alt+shift+F1")
  (sleep 0.3)
  (let* ((ev *last-key-event*)
         (key (and ev (getf ev :|key|)))
         (mods (and ev (getf ev :|mods|))))
    (check "C-M-S-F1 → key event arrived"
           ev (format nil "ev=~s" ev))
    (check "C-M-S-F1 → shift IS in mods (non-printable)"
           (find "shift" mods :test #'string=)
           (format nil "got mods=~s key=~s" mods key)))

  (let ((ok (null *failures*)))
    (format t "~%── VERDICT: ~a ──~%"
            (if ok "✓ PASS — A12 modifier combos pin SPEC contract"
                   (format nil "✗ FAIL: ~{~%    ~a~}" *failures*)))
    (limn:stop)
    (handler-case (sb-ext:process-kill proc 15) (error () nil))
    (when (probe-file "/tmp/.limn/init.lisp.stash-mods")
      (rename-file "/tmp/.limn/init.lisp.stash-mods" "/tmp/.limn/init.lisp"))
    (sb-ext:exit :code (if ok 0 1))))
