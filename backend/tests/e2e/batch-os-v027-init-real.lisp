;;;; v0.27 — 真實 init.lisp customize (OS e2e)
;;;;
;;;;   Ω1 user init 改 *pdf-annotation-color* → 新標注用新色
;;;;   Ω2 user init 第一行 (error ...) → pdf-mode 仍在、j 仍翻頁
;;;;   Ω3 user init 重綁 j → 按 j 跑 user-fn 不是 pdf-scroll-down

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

;; Stash any existing init.lisp for this test session
(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-ir"))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))
(defun engine-load (path)
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "mupdf" :|path| path :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))
(defun page-of () (getf (data (limn:call "view/get" :|win-id| "w1")) :|page|))
(defun xdotool (&rest args)
  (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))
(defun key (k) (xdotool "key" k))
(defun nuke-sidecars ()
  (let ((dir (merge-pathnames ".limn/annotations/" (user-homedir-pathname))))
    (when (probe-file dir)
      (dolist (f (ignore-errors (directory (merge-pathnames "*.lisp" dir))))
        (ignore-errors (delete-file f))))))

(defun write-init (content)
  (ensure-directories-exist "/tmp/.limn/init.lisp")
  (with-open-file (out "/tmp/.limn/init.lisp" :direction :output
                                                :if-exists :supersede
                                                :if-does-not-exist :create)
    (write-string content out)))

(defun wait-for-window ()
  (loop repeat 50 for found =
    (with-output-to-string (out)
      (ignore-errors
        (sb-ext:run-program "xdotool" '("search" "--name" "Limn")
                             :search t :wait t :output out :error nil)))
    when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
      do (return found) do (sleep 0.1)))

(defun start-session (sock log)
  (let* ((limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
         (proc (sb-ext:run-program
                limn-bin (list "--test-mode" "--socket" sock)
                :wait nil :search nil
                :output log :if-output-exists :supersede :error :output)))
    (loop repeat 100 until (probe-file sock) do (sleep 0.05))
    (limn:start sock) (sleep 0.3) (wait-for-window) proc))

(defun stop-session (proc)
  (ignore-errors (limn:stop))
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc))

(defparameter *fixture* (b/ "tests/fixtures/test.pdf"))

;;; ── Ω1: customize annotation color via init.lisp ──────────

(format t "~%── Ω1: init.lisp customize color ──~%")
(nuke-sidecars)
(write-init "
(setf limn/pdf-mode:*pdf-annotation-color* \"#ff00ff\")
")

(let* ((sock (format nil "/tmp/limn-e2e-ir1-~a" (sb-posix:getpid)))
       (proc (start-session sock "/tmp/limn-os-v027ir1.log")))
  (let ((b (engine-load *fixture*)))
    (when b
      (limn:call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| 0 :|x| 0.1 :|y| 0.2)
              :|end|   (list :|page| 0 :|x| 0.5 :|y| 0.25))
      (sleep 0.1)
      (key "h") (sleep 0.3)
      ;; Read back the sidecar; color should be #ff00ff
      (let* ((sidecars (ignore-errors
                         (directory
                          (merge-pathnames ".limn/annotations/*.lisp"
                                            (user-homedir-pathname)))))
             (path (first sidecars))
             (content (and path
                            (with-open-file (in path :direction :input)
                              (let* ((sz (file-length in))
                                     (buf (make-string (or sz 0))))
                                (read-sequence buf in) buf)))))
        (check (format nil "Ω1 — sidecar contains #ff00ff (~a chars)"
                       (length (or content "")))
               (and content (search "#ff00ff" content))))))
  (stop-session proc))

;;; ── Ω2: broken init.lisp 不殺 pdf-mode ────────────────────

(format t "~%── Ω2: broken init.lisp tolerance ──~%")
(write-init "
(error \"intentional broken init\")
")

(let* ((sock (format nil "/tmp/limn-e2e-ir2-~a" (sb-posix:getpid)))
       (proc (start-session sock "/tmp/limn-os-v027ir2.log")))
  (let ((b (engine-load *fixture*)))
    (check (format nil "Ω2a — broken init: still able to load PDF (~a)" b)
           (stringp b)))
  ;; j should still navigate even though init.lisp threw
  (limn:call "view/set" :|win-id| "w1" :|page| 0)
  (sleep 0.1)
  (key "j") (sleep 0.2)
  (let* ((v (data (limn:call "view/get" :|win-id| "w1")))
         (p (getf v :|page|))
         (off (or (getf v :|offset-y|) 0.0)))
    (check (format nil "Ω2b — j still works (page=~a, offset=~a)" p off)
           (or (> p 0) (> off 0))))
  (stop-session proc))

;;; ── Ω3: user 重綁 j → 跑 user-fn ─────────────────────────

(format t "~%── Ω3: user override j ──~%")
(write-init "
(limn/cmd:defcommand my-user-j (:interactive nil)
  (lambda ()
    (limn:call \"message/echo\" :|text| \"user-j-fired\")))
;; Need install completed before we override — but install hook fires before
;; init load, so by here pdf-mode-map exists. Re-bind:
(let* ((m (limn/mode:find-mode 'pdf-mode))
       (km (and m (limn/mode:mode-keymap m))))
  (when km
    (limn/keys:define-key km \"j\" (lambda (ev) (declare (ignore ev))
                                       (limn/cmd:call-interactively 'my-user-j)))))
")

(let* ((sock (format nil "/tmp/limn-e2e-ir3-~a" (sb-posix:getpid)))
       (proc (start-session sock "/tmp/limn-os-v027ir3.log")))
  (let ((b (engine-load *fixture*)))
    (when b
      (limn:call "view/set" :|win-id| "w1" :|page| 0) (sleep 0.1)
      ;; before override-aware: page is 0, off is 0.
      (let ((p-before (page-of)))
        (key "j") (sleep 0.3)
        (let* ((mr (data (limn:call "message/get")))
               (msg (and mr (or (getf mr :|text|) ""))))
          ;; user-fn should have echoed "user-j-fired"; AND because user
          ;; override replaces pdf-scroll-down, page should NOT advance
          (check (format nil "Ω3a — message contains user-j-fired (~s)" msg)
                 (and (stringp msg) (search "user-j-fired" msg)))
          (check (format nil "Ω3b — page didn't advance (~a → ~a)"
                          p-before (page-of))
                 (= p-before (page-of)))))))
  (stop-session proc))

;; Restore stashed init
(write-init "")
(ignore-errors (delete-file "/tmp/.limn/init.lisp"))
(when (probe-file "/tmp/.limn/init.lisp.stash-ir")
  (rename-file "/tmp/.limn/init.lisp.stash-ir" "/tmp/.limn/init.lisp"))

(format t "~%── v027-init-real e2e ──~%")
(if (null *failures*)
    (format t "✓ ALL CHECKS PASSED~%")
    (progn
      (format t "✗ ~a FAILURE(s):~%" (length *failures*))
      (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
(sb-ext:exit :code (if *failures* 1 0))
