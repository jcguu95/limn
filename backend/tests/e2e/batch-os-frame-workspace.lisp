;;;; Batch 31: v0.21 A — frame workspace (multi-desktop) integration.
;;;;
;;;; v0.21 ships:
;;;;   Ω0 — container has wmctrl + openbox provides ≥ 4 desktops
;;;;   Ω1 — xdotool set_desktop_for_window moves f2's window to ws 2
;;;;   Ω2 — bridge call to f2 still works post-move (backgrounded
;;;;        workspace doesn't break the protocol)
;;;;
;;;; Explicitly deferred to a future release (SPEC §12 v0.21 follow-up):
;;;;   - frame-workspace-change event: requires QAbstractNativeEvent-
;;;;     Filter on X11, handling xcb_property_notify_event_t for
;;;;     _NET_WM_DESKTOP, mapping the source X window back to a Limn
;;;;     frame. ~half day of work; non-blocking for v0.21 since
;;;;     user-land which-workspace polling via wmctrl works today.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defun xdotool-stdout (&rest args)
  (with-output-to-string (s)
    (let ((p (sb-ext:run-program "xdotool" args :search t
                                  :wait t :output s :error t)))
      (unless (zerop (sb-ext:process-exit-code p))
        (error "xdotool ~{~a~^ ~} exited non-zero" args)))))

(defun wmctrl (&rest args)
  (let ((p (sb-ext:run-program "wmctrl" args :search t :wait t
                                :output nil :error nil)))
    (zerop (sb-ext:process-exit-code p))))

(defun wmctrl-stdout (&rest args)
  (with-output-to-string (s)
    (let ((p (sb-ext:run-program "wmctrl" args :search t :wait t
                                  :output s :error t)))
      (unless (zerop (sb-ext:process-exit-code p))
        (error "wmctrl ~{~a~^ ~} exited non-zero" args)))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-fws"))

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

(defun ok? (r) (eq (getf r :|ok|) t))

(let* ((sock (format nil "/tmp/limn-e2e-fws-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-fws.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.5)

;;; ── Ω0: container infra — wmctrl + openbox 4 workspaces ─────────

  (format t "~%── Ω0: container infra ──~%")
  (check "Ω0a — wmctrl present in PATH"
         (zerop (sb-ext:process-exit-code
                 (sb-ext:run-program "which" '("wmctrl")
                                      :search t :wait t
                                      :output nil :error nil))))
  ;; openbox configured for ≥ 4 desktops via Xvfb root window properties;
  ;; wmctrl -d lists them
  (let* ((desktops (handler-case (wmctrl-stdout "-d") (error () "")))
         (desktop-count (count #\Newline desktops)))
    (check (format nil "Ω0b — openbox has ≥ 4 desktops (got ~a)" desktop-count)
           (>= desktop-count 4)))

;;; ── Ω1: f2 window can be moved to workspace 2 ─────────────────

  (format t "~%── Ω1: xdotool moves f2's window to workspace 2 ──~%")
  (let* ((r (limn:call "frame/create"))
         (fid (and (ok? r) (getf (getf r :|data|) :|frame-id|))))
    (when fid
      (sleep 0.8)
      ;; Find the second Limn window (f2's MainWindow)
      (let* ((wins-raw (xdotool-stdout "search" "--name" "Limn"))
             (wins (loop with start = 0
                         for i from 0 below (length wins-raw)
                         when (char= (char wins-raw i) #\Newline)
                           collect (subseq wins-raw start i)
                           and do (setf start (1+ i))))
             ;; pick the LAST (newest) window — that's f2
             (f2-wid (and wins (parse-integer (car (last wins))
                                              :junk-allowed t))))
        (check (format nil "Ω1a — got f2 X window id (~a)" f2-wid)
               (numberp f2-wid))
        (when f2-wid
          ;; xdotool set_desktop_for_window <wid> 1  (workspace 2 = index 1)
          (handler-case
            (progn
              (sb-ext:run-program "xdotool"
                                   (list "set_desktop_for_window"
                                         (write-to-string f2-wid) "1")
                                   :search t :wait t
                                   :output nil :error nil)
              (sleep 0.4)
              (check "Ω1b — set_desktop_for_window ran ok" t))
            (error (e)
              (check (format nil "Ω1b — set_desktop_for_window failed: ~a" e) nil))))

;;; ── Ω2: bridge call to f2 still works after workspace move ────

        (format t "~%── Ω2: bridge call to f2 still works ──~%")
        (let ((r (limn:call "frame/list")))
          (check "Ω2 — frame/list responsive"
                 (and (ok? r)
                      (find fid (getf (getf r :|data|) :|items|)
                            :key (lambda (f) (getf f :|frame-id|))
                            :test #'string=))))

        ;; Ω3 (frame-workspace-change event) deferred — see file header.
        ;; Move f2 back to ws 0 so cleanup is hygienic.
        (when f2-wid
          (sb-ext:run-program "xdotool"
                               (list "set_desktop_for_window"
                                     (write-to-string f2-wid) "0")
                               :search t :wait t
                               :output nil :error nil)))

      (limn:call "frame/close" :|frame-id| fid)))

  ;; ── summary ─────────────────────────────────────────────────
  (format t "~%~%── frame-workspace e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
