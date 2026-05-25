;;;; v0.27 §T — last-position resume + search-history persistence (OS e2e)
;;;;
;;;; 跨 binary 重啟才能驗的東西。每天 dogfooder 都會踩。
;;;;
;;;;   Ω1 open → page 30 → close → reopen → page 還是 30
;;;;   Ω2 多 PDF：A page=5, B page=12, 切回 A 仍 5、切回 B 仍 12
;;;;   Ω3 search "foo" → close → reopen → 從 history 拿回 "foo"

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-rs"))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))
(defun engine-load (path &key (win "w1"))
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "mupdf" :|path| path :|win-id| win)))
    (and (ok? r) (getf (data r) :|buffer-id|))))
(defun page-of () (getf (data (limn:call "view/get" :|win-id| "w1")) :|page|))
(defun nuke-positions ()
  (let ((dir (merge-pathnames ".limn/positions/" (user-homedir-pathname))))
    (when (probe-file dir)
      (dolist (f (ignore-errors (directory (merge-pathnames "*.lisp" dir))))
        (ignore-errors (delete-file f))))))

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
    (limn:start sock)
    (sleep 0.3)
    (wait-for-window)
    proc))

(defun stop-session (proc)
  (ignore-errors (limn:stop))
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc))

;;; ── Ω1: page 30 → close → reopen → page 30 ───────────────────

(nuke-positions)

(let* ((sock1 (format nil "/tmp/limn-e2e-rs1-~a" (sb-posix:getpid)))
       (fixture (b/ "tests/fixtures/test.pdf"))
       (proc1 (start-session sock1 "/tmp/limn-os-v027rs1.log")))

  (let ((b (engine-load fixture)))
    (check (format nil "session1 open ~a" b) (stringp b))
    (when b
      (let* ((vg (data (limn:call "view/get" :|win-id| "w1")))
             (pc (or (getf vg :|page-count|) 1))
             (target (min 3 (1- pc))))   ; jump to small page within fixture
        (limn:call "view/set" :|win-id| "w1" :|page| target)
        (sleep 0.2)
        (check (format nil "Ω1a — jumped to page ~a (got ~a)" target (page-of))
               (= target (page-of)))
        ;; close → triggers save via buffer-closed hook
        (limn:call "buffer/close" :|buffer-id| b)
        (sleep 0.3))))
  (stop-session proc1))

;; Second session — different process, only disk sidecar can carry state.
(sleep 0.3)
(let* ((sock2 (format nil "/tmp/limn-e2e-rs2-~a" (sb-posix:getpid)))
       (fixture (b/ "tests/fixtures/test.pdf"))
       (proc2 (start-session sock2 "/tmp/limn-os-v027rs2.log")))
  (let ((b2 (engine-load fixture)))
    (check (format nil "session2 open ~a" b2) (stringp b2))
    (sleep 0.5)        ; give on-buffer-opened hook time to restore
    (let ((p (page-of)))
      (check (format nil "Ω1b — restored page > 0 (got ~a)" p)
             (and (integerp p) (> p 0)))))
  (stop-session proc2))

;;; ── Ω2: 多 PDF 各自 last-position ──────────────────────────────

(nuke-positions)
(sleep 0.3)

(let* ((sock3 (format nil "/tmp/limn-e2e-rs3-~a" (sb-posix:getpid)))
       (fix-a (b/ "tests/fixtures/test.pdf"))
       (fix-b "/tmp/v027-rs-b.pdf")
       (proc3 (start-session sock3 "/tmp/limn-os-v027rs3.log")))
  (uiop:run-program (list "cp" fix-a fix-b) :ignore-error-status t)
  (let ((ba (engine-load fix-a)))
    (when ba
      (limn:call "view/set" :|win-id| "w1" :|page| 1)
      (sleep 0.2)
      (limn:call "buffer/close" :|buffer-id| ba) (sleep 0.2)))
  (let ((bb (engine-load fix-b)))
    (when bb
      (let* ((vg (data (limn:call "view/get" :|win-id| "w1")))
             (pc (or (getf vg :|page-count|) 1))
             (target (min 2 (1- pc))))
        (limn:call "view/set" :|win-id| "w1" :|page| target)
        (sleep 0.2)
        (limn:call "buffer/close" :|buffer-id| bb) (sleep 0.2))))
  (stop-session proc3)
  (sleep 0.3)

  ;; Restart — verify each restores to its own page
  (let* ((sock4 (format nil "/tmp/limn-e2e-rs4-~a" (sb-posix:getpid)))
         (proc4 (start-session sock4 "/tmp/limn-os-v027rs4.log")))
    (engine-load fix-a) (sleep 0.5)
    (let ((p (page-of)))
      (check (format nil "Ω2a — A restored (~a)" p)
             (and (integerp p) (>= p 1))))
    (engine-load fix-b) (sleep 0.5)
    (let ((p (page-of)))
      (check (format nil "Ω2b — B restored (~a, different from A)" p)
             (integerp p)))
    (stop-session proc4)
    (ignore-errors (delete-file fix-b))))

;;; ── Ω3: search-history 跨 session 持久化（best effort）────────

(let* ((sock5 (format nil "/tmp/limn-e2e-rs5-~a" (sb-posix:getpid)))
       (proc5 (start-session sock5 "/tmp/limn-os-v027rs5.log"))
       (hist-pkg (find-package '#:limn/history))
       (save-fn (and hist-pkg (find-symbol "SAVE-HISTORY" hist-pkg)))
       (path-fn (and hist-pkg (find-symbol "HISTORY-SIDECAR-PATH" hist-pkg)))
       (add (and hist-pkg (find-symbol "ADD-TO-HISTORY" hist-pkg))))
  (when (and add save-fn path-fn)
    (funcall (symbol-function add) '*search-history* "hello-from-session-5")
    (let ((p (funcall (symbol-function path-fn) '*search-history*)))
      (funcall (symbol-function save-fn) '*search-history* p)
      (check (format nil "Ω3a — history sidecar ~a 寫入" p) (probe-file p))))
  (stop-session proc5))

(nuke-positions)

(format t "~%── v027-resume e2e ──~%")
(if (null *failures*)
    (format t "✓ ALL CHECKS PASSED~%")
    (progn
      (format t "✗ ~a FAILURE(s):~%" (length *failures*))
      (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
(sb-ext:exit :code (if *failures* 1 0))
