;;;; Batch 14: navigation keys — A8.
;;;;
;;;; PageUp / PageDown / Home / End / Insert / Delete / Tab / Backspace
;;;; 都應該透過 key_to_string 的 switch 案例回到一個可識別名稱、且能
;;;; 被 limn:bind 抓到。

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

(defun xdotool-stdout (&rest args)
  (with-output-to-string (s)
    (let ((p (sb-ext:run-program "xdotool" args :search t
                                  :wait t :output s :error t)))
      (unless (zerop (sb-ext:process-exit-code p))
        (error "xdotool ~{~a~^ ~} exited non-zero" args)))))

(defun wait-for-window-by-name (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((s (string-trim '(#\Space #\Newline #\Tab)
                             (handler-case
                                 (xdotool-stdout "search" "--name" name)
                               (error () "")))))
        (unless (zerop (length s))
          (return (parse-integer
                   (subseq s 0 (or (position #\Newline s) (length s)))))))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-nav"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defparameter *keys* nil)

(let* ((sock (format nil "/tmp/limn-e2e-nav-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-nav.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)

    (limn:on-event "key"
                   (lambda (ev) (push (getf ev :|key|) *keys*)))
    (sleep 0.2)

    (format t "~%── A8: named keys come through with documented names ──~%")

    (let ((cases '(("Page_Up"    "<pageup>")
                   ("Page_Down"  "<pagedown>")
                   ("Home"       "<home>")
                   ("End"        "<end>")
                   ("Up"         "<up>")
                   ("Down"       "<down>")
                   ("Left"       "<left>")
                   ("Right"      "<right>")
                   ("Insert"     "<insert>")
                   ("Delete"     "DEL")
                   ("BackSpace"  "BS")
                   ("Return"     "RET")
                   ("Escape"     "ESC")
                   ("Tab"        "TAB"))))
      (dolist (c cases)
        (let ((xkey (first c))
              (expected-name (second c)))
          (setf *keys* nil)
          (xdotool "key" "--clearmodifiers" xkey)
          (sleep 0.15)
          (check (format nil "A8 — xdotool ~a → key=~s (got ~s)"
                         xkey expected-name (first *keys*))
                 (equal (first *keys*) expected-name)))))

;;; ── A8 bonus: binding navigation key works ────────────────────────

    (format t "~%── A8 bonus: bind \"<pageup>\" → command fires ──~%")
    (defparameter cl-user::*pgup-fired* 0)
    (limn:bind "<pageup>"
               (lambda (ev) (declare (ignore ev))
                 (incf cl-user::*pgup-fired*)))
    (sleep 0.2)
    (xdotool "key" "--clearmodifiers" "Page_Up")
    (sleep 0.3)
    (check (format nil "A8 — PageUp binding fired (count=~a)"
                   cl-user::*pgup-fired*)
           (= cl-user::*pgup-fired* 1))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 14 nav keys green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-nav")
        (rename-file "/tmp/.limn/init.lisp.stash-nav" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
