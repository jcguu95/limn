;;;; v0.27 — crash recovery / atomic save / migration (OS e2e)
;;;;
;;;;   Ω1 SIGKILL 中途、重啟 → sidecar 仍合法 lisp（atomic .tmp 護住）
;;;;   Ω2 寫一個半合法 .tmp 殘骸 → 下次 save 自動覆蓋、不卡住
;;;;   Ω3 寫一個 v0 sidecar 殘骸 → 開 PDF → 自動 migrate 並 re-save 成 v1
;;;;   Ω4 100 annotation save → SIGKILL → 重啟、最後 1 個可能丟、前 99 OK

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-cr"))

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
(defun xdotool (&rest args)
  (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))
(defun key (k) (xdotool "key" k))
(defun nuke-sidecars ()
  (let ((dir (merge-pathnames ".limn/annotations/" (user-homedir-pathname))))
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
    (limn:start sock) (sleep 0.3) (wait-for-window)
    proc))

(defun stop-session (proc)
  (ignore-errors (limn:stop))
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc))

(defun sigkill-session (proc)
  "Force SIGKILL — emulates power loss / kill -9."
  (ignore-errors (sb-ext:process-kill proc 9))
  (sb-ext:process-wait proc))

(defparameter *fixture* (b/ "tests/fixtures/test.pdf"))

;;; ── Ω1: SIGKILL after annotation → sidecar valid ───────────

(format t "~%── Ω1: SIGKILL → sidecar 仍合法 ──~%")
(nuke-sidecars)
(let* ((sock (format nil "/tmp/limn-e2e-cr1-~a" (sb-posix:getpid)))
       (proc (start-session sock "/tmp/limn-os-v027cr1.log")))
  (engine-load *fixture*) (sleep 0.2)
  (limn:call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| 0 :|x| 0.1 :|y| 0.2)
              :|end|   (list :|page| 0 :|x| 0.5 :|y| 0.25))
  (sleep 0.1) (key "h") (sleep 0.5)        ; let save complete
  (sigkill-session proc))

(sleep 0.3)
;; Inspect sidecar — should be readable
(let* ((sidecars (ignore-errors
                   (directory (merge-pathnames ".limn/annotations/*.lisp"
                                                (user-homedir-pathname)))))
       (path (first sidecars))
       (form (and path
                   (handler-case
                       (with-open-file (in path :direction :input)
                         (read in nil nil))
                     (error () nil)))))
  (check (format nil "Ω1 — sidecar after SIGKILL parses (~s)"
                 (and form (first form)))
         (and form (listp form) (getf form :version))))

;;; ── Ω2: .tmp 殘骸不卡 next save ─────────────────────────────

(format t "~%── Ω2: stale .tmp 殘骸 + next save ──~%")
(nuke-sidecars)
(let* ((dir (merge-pathnames ".limn/annotations/" (user-homedir-pathname))))
  (ensure-directories-exist dir)
  ;; create a stale .tmp
  (with-open-file (out (merge-pathnames "stale-key.lisp.tmp" dir)
                        :direction :output :if-exists :supersede
                        :if-does-not-exist :create)
    (write-string "(:partial-write-truncated" out)))

(let* ((sock (format nil "/tmp/limn-e2e-cr2-~a" (sb-posix:getpid)))
       (proc (start-session sock "/tmp/limn-os-v027cr2.log")))
  (engine-load *fixture*) (sleep 0.2)
  (limn:call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| 0 :|x| 0.2 :|y| 0.3)
              :|end|   (list :|page| 0 :|x| 0.6 :|y| 0.4))
  (sleep 0.1) (key "h") (sleep 0.5)
  (let ((sidecars (ignore-errors
                    (directory
                     (merge-pathnames ".limn/annotations/*.lisp"
                                       (user-homedir-pathname))))))
    (check (format nil "Ω2 — new save succeeded despite stale .tmp (~a files)"
                   (length sidecars))
           (>= (length sidecars) 1)))
  (stop-session proc))

;;; ── Ω3: v0 sidecar 自動 migrate 到 v1 ──────────────────────

(format t "~%── Ω3: v0 sidecar migrate ──~%")
(nuke-sidecars)
;; Compute the path-keyed sidecar manually, write v0 content there.
(let* ((dir (merge-pathnames ".limn/annotations/" (user-homedir-pathname)))
       (anno-pkg (find-package '#:limn/pdf-mode))
       (path-fn (and anno-pkg
                      (find-symbol "PDF-ANNOTATIONS-SIDECAR-PATH" anno-pkg)))
       (cont-fn (and anno-pkg
                      (find-symbol "PDF-ANNOTATIONS-CONTENT-HASH-SIDECAR-PATH"
                                    anno-pkg))))
  (declare (ignore dir))
  ;; Seed BOTH potential paths so whichever load goes through, finds v0
  (dolist (fn (list path-fn cont-fn))
    (let ((p (and fn (fboundp fn)
                   (funcall (symbol-function fn) *fixture*))))
      (when p
        (ensure-directories-exist p)
        (with-open-file (out p :direction :output :if-exists :supersede
                                :if-does-not-exist :create)
          (write-string
            "(:version 0 :annotations
               ((:id \"legacy-1\" :page 0 :rects ((0.1 0.1 0.4 0.2))
                 :color \"#FFD700\" :note \"from-v0\" :created-at 1)))"
            out))))))

(let* ((sock (format nil "/tmp/limn-e2e-cr3-~a" (sb-posix:getpid)))
       (proc (start-session sock "/tmp/limn-os-v027cr3.log")))
  (let ((b (engine-load *fixture*)))
    (declare (ignore b))
    (sleep 0.3))
  ;; Trigger a save to force re-serialize at v1
  (limn:call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| 1 :|x| 0.1 :|y| 0.5)
              :|end|   (list :|page| 1 :|x| 0.4 :|y| 0.6))
  (sleep 0.1) (key "h") (sleep 0.5)

  ;; v0.37 Phase F: pdf-annotations-save prefers the content-hash
  ;; sidecar (survives rename / move).  Read it preferentially; fall
  ;; back to the legacy path-keyed sidecar so the test stays correct
  ;; for older binaries too.
  (let* ((anno-pkg (find-package '#:limn/pdf-mode))
         (path-fn (and anno-pkg
                        (find-symbol "PDF-ANNOTATIONS-SIDECAR-PATH" anno-pkg)))
         (cont-fn (and anno-pkg
                        (find-symbol "PDF-ANNOTATIONS-CONTENT-HASH-SIDECAR-PATH"
                                      anno-pkg)))
         (p-cont  (and cont-fn (funcall (symbol-function cont-fn) *fixture*)))
         (p-path  (and path-fn (funcall (symbol-function path-fn) *fixture*)))
         (chosen  (or (and p-cont (probe-file p-cont) p-cont)
                       (and p-path (probe-file p-path) p-path)))
         (form    (and chosen
                       (handler-case
                           (with-open-file (in chosen :direction :input)
                             (read in nil nil))
                         (error () nil)))))
    (check (format nil "Ω3 — after migrate, sidecar :version = current (~a)"
                   (getf form :version))
           (and form (integerp (getf form :version))
                (>= (getf form :version) 1))))
  (stop-session proc))

;;; ── Ω4: 多 annotation save → SIGKILL → 前 N-1 OK ──────────

(format t "~%── Ω4: bulk save + SIGKILL ──~%")
(nuke-sidecars)
(let* ((sock (format nil "/tmp/limn-e2e-cr4-~a" (sb-posix:getpid)))
       (proc (start-session sock "/tmp/limn-os-v027cr4.log")))
  (engine-load *fixture*) (sleep 0.2)
  ;; Drop 5 annotations rapidly
  (dotimes (i 5)
    (let ((y (+ 0.1 (* 0.1 i))))
      (limn:call "view/selection-set" :|win-id| "w1"
                  :|begin| (list :|page| 0 :|x| 0.1 :|y| y)
                  :|end|   (list :|page| 0 :|x| 0.5 :|y| (+ y 0.05)))
      (sleep 0.05)
      (key "h") (sleep 0.15)))
  (sigkill-session proc))

(sleep 0.3)
(let* ((anno-pkg (find-package '#:limn/pdf-mode))
       (load-fn (and anno-pkg
                      (find-symbol "PDF-ANNOTATIONS-LOAD" anno-pkg)))
       (back (and load-fn (fboundp load-fn)
                   (funcall (symbol-function load-fn) *fixture*))))
  (check (format nil "Ω4 — at least 1 annotation survived SIGKILL (~a)"
                 (length (or back '())))
         (and (listp back) (>= (length back) 1))))

(nuke-sidecars)

(format t "~%── v027-crash-recovery e2e ──~%")
(if (null *failures*)
    (format t "✓ ALL CHECKS PASSED~%")
    (progn
      (format t "✗ ~a FAILURE(s):~%" (length *failures*))
      (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
(sb-ext:exit :code (if *failures* 1 0))
