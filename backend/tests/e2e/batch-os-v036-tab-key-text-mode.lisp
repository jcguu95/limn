;;;; v0.36 — TAB key in text-mode triggers indent-for-tab-command (real key
;;;; via xdotool). v0.36 §B keymap wireup 實作前 RED.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v036tab"))

(handler-case (load (b/ "../vendor/cl-ppcre-load.lisp"))
  (error (e) (format t "  !! skipped vendor cl-ppcre: ~A~%" e)))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun buf-text (buf)
  (let ((r (limn:call "buffer/text" :|buffer-id| buf)))
    (and (ok? r) (getf (data r) :|text|))))

(defun text-engine-load ()
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "text" :|path| "" :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool"
                                            '("search" "--name" "Limn")
                                            :search t :wait t
                                            :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found))
                           0))
          do (return found)
        do (sleep 0.1)))

(defun xdo-key (key)
  (sb-ext:run-program "xdotool" (list "key" "--clearmodifiers" key)
                      :search t :wait t :output nil :error nil))

(let* ((sock (format nil "/tmp/limn-e2e-v036tab-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v036tab.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (sleep 0.3) (wait-for-window)

  (let ((buf (text-engine-load)))
    (check (format nil "opened text buffer (~a)" buf) (stringp buf))
    (when buf
      ;; Focus the Limn window so xdotool can send keys to it.
      (let ((wid (with-output-to-string (s)
                   (ignore-errors
                     (sb-ext:run-program "xdotool"
                                          '("search" "--name" "Limn")
                                          :search t :wait t
                                          :output s :error nil)))))
        (when wid
          (let ((win (string-trim '(#\Newline #\Space) wid)))
            (when (> (length win) 0)
              (sb-ext:run-program "xdotool"
                                  (list "windowactivate" "--sync" win)
                                  :search t :wait t :output nil :error nil)
              (sleep 0.2)))))

      ;; Activate text-mode (idempotent — should already be on the
      ;; mode-buffer, but make sure).
      (let* ((r (limn:call "view/get" :|win-id| "w1"))
             (mb (and (ok? r) (getf (data r) :|mode-buffer-id|))))
        (when mb
          (limn:call "mode/activate" :|buffer-id| mb :|mode| "text-mode")))

      ;; Press TAB.
      (xdo-key "Tab")
      (sleep 0.2)

      (let ((txt (buf-text buf)))
        (check (format nil "after TAB key, buffer has indent (got ~s)" txt)
               (or (equal txt (string #\Tab))
                   (equal txt "        ")
                   ;; If newline-and-indent wasn't pressed, default could be empty
                   ;; if keymap not wired; this is the assertion that fails RED.
                   nil))
        (check "buffer non-empty after TAB"
               (and (stringp txt) (> (length txt) 0))))

      (ignore-errors (limn:call "buffer/close" :|buffer-id| buf))))

  (format t "~%── v036 tab-key text-mode results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn (format t "✗ ~a FAILURE(s):~%" (length *failures*))
             (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15) (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
