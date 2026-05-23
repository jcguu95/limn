;;;; Batch 21: A5 numeric prefix arg — Emacs convention 5g goto page 5.
;;;;
;;;; %dispatch-key 在 v0.12 加了 prefix-arg accumulator：
;;;;   (digit + no mods + no key prefix) → 累進 accumulator、不 dispatch
;;;;   下個非 digit → 把 acc parse 成 int 作為 *prefix-arg* binding 進 dispatch
;;;;
;;;; defcommand :interactive \"p\" 從 *prefix-arg* 拿到該值。

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-pa"))

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

(let* ((sock (format nil "/tmp/limn-e2e-pa-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-pa.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

;;; ── Setup: defcommand 'goto-page-pa' uses prefix arg ─────────────

    (format t "~%── A5: numeric prefix arg + bound command ──~%")
    (defparameter cl-user::*pa-saw* nil)
    (limn/cmd:defcommand goto-page-pa (:interactive "p")
      (lambda (n) (setf cl-user::*pa-saw* n)))
    (limn:bind "g" 'goto-page-pa)
    (sleep 0.2)

    ;; Case 1: 'g' alone — prefix arg default (no acc) → :interactive "p"
    ;; returns *prefix-arg* default value which is 1.
    (setf cl-user::*pa-saw* nil)
    (xdotool "key" "--clearmodifiers" "g")
    (sleep 0.3)
    (check (format nil "A5 — 'g' alone → prefix arg = 1 (default; got ~s)"
                   cl-user::*pa-saw*)
           (= cl-user::*pa-saw* 1))

    ;; Case 2: '5' then 'g' — should produce prefix arg = 5
    (setf cl-user::*pa-saw* nil)
    (xdotool "key" "--clearmodifiers" "5")
    (xdotool "key" "--clearmodifiers" "g")
    (sleep 0.3)
    (check (format nil "A5 — '5g' → prefix arg = 5 (got ~s)"
                   cl-user::*pa-saw*)
           (= cl-user::*pa-saw* 5))

    ;; Case 3: '4' '2' 'g' — should produce 42
    (setf cl-user::*pa-saw* nil)
    (xdotool "key" "--clearmodifiers" "4")
    (xdotool "key" "--clearmodifiers" "2")
    (xdotool "key" "--clearmodifiers" "g")
    (sleep 0.3)
    (check (format nil "A5 — '42g' → prefix arg = 42 (got ~s)"
                   cl-user::*pa-saw*)
           (= cl-user::*pa-saw* 42))

    ;; Case 4: '5' alone (no following bound key) — should NOT dispatch
    ;; just accumulate then reset on something. Test indirectly: after
    ;; '5' alone + 5 second sleep + 'g' (no other key in between), the
    ;; '5' still counts (since accumulator only resets on dispatch).
    ;; Actually that's a design call. Current impl: acc persists until
    ;; another (non-digit, non-prefix) dispatch.
    (setf cl-user::*pa-saw* nil)
    (xdotool "key" "--clearmodifiers" "3")
    (sleep 0.3)
    (xdotool "key" "--clearmodifiers" "g")
    (sleep 0.3)
    (check (format nil "A5 — '3' + later 'g' → prefix arg = 3 (got ~s)"
                   cl-user::*pa-saw*)
           (= cl-user::*pa-saw* 3))

    ;; Case 5: digit-only acc followed by unbound key — acc resets
    (setf cl-user::*pa-saw* nil)
    (xdotool "key" "--clearmodifiers" "7")
    (xdotool "key" "--clearmodifiers" "z")  ; z unbound — resets *key-prefix*
                                             ; AND accumulator (already reset on dispatch attempt)
    (sleep 0.3)
    ;; Now 'g' should see fresh default 1
    (xdotool "key" "--clearmodifiers" "g")
    (sleep 0.3)
    (check (format nil "A5 — after '7' + unbound 'z' → next 'g' = default 1 (got ~s)"
                   cl-user::*pa-saw*)
           (= cl-user::*pa-saw* 1))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 21 numeric prefix arg green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-pa")
        (rename-file "/tmp/.limn/init.lisp.stash-pa" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
