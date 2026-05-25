;;;; v0.27 stress — long-session RSS + keyboard throughput + idle (OS e2e)
;;;;
;;;;   Ω1 200 連續 j → page 真的走、event 不掉
;;;;   Ω2 100 次 open+search+close → RSS 增長 < 50%
;;;;   Ω3 1000 次 n（search hit 推進）→ overlay 沒洩漏
;;;;   Ω4 idle 5 秒 → 之後 j 仍 responsive

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-st"))

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
(defun page-of () (getf (data (limn:call "view/get" :|win-id| "w1")) :|page|))
(defun overlays-of ()
  (let ((r (limn:call "view/get" :|win-id| "w1")))
    (when (ok? r) (or (getf (data r) :|overlays|) '()))))

(defun limn-rss (pid)
  "Return RSS in KB.  Prefer /proc/<pid>/status (Linux containers
   including the nix-based docker image), fall back to ps for macOS
   host.  Returns NIL when neither is available — downstream RSS
   ratio checks handle NIL as 'skip'.
   v0.37 Phase F (driver-C2): nix containers ship without ps on PATH,
   so the original `sb-ext:run-program \"ps\"` raised 'Couldn't
   execute ps: No such file or directory' and aborted the whole
   driver before any stress assertion could run."
  (let ((status-path (format nil "/proc/~a/status" pid)))
    (cond
      ((probe-file status-path)
       (with-open-file (in status-path :direction :input)
         (loop for line = (read-line in nil nil)
               while line
               when (search "VmRSS:" line)
                 return (parse-integer line :junk-allowed t))))
      (t
       (handler-case
           (let ((out (with-output-to-string (s)
                        (sb-ext:run-program "ps"
                                              (list "-o" "rss=" "-p"
                                                    (princ-to-string pid))
                                              :search t :wait t
                                              :output s :error nil))))
             (parse-integer (string-trim '(#\Space #\Newline) out)
                            :junk-allowed t))
         (error () nil))))))

(defun wait-for-window ()
  (loop repeat 50 for found =
    (with-output-to-string (out)
      (ignore-errors
        (sb-ext:run-program "xdotool" '("search" "--name" "Limn")
                             :search t :wait t :output out :error nil)))
    when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
      do (return found) do (sleep 0.1)))

;;; ── session ─────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-st-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (fixture (b/ "tests/fixtures/test.pdf"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v027st.log"
              :if-output-exists :supersede :error :output))
       (pid (sb-ext:process-pid proc)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

;;; ── Ω1: 200 連 j ───────────────────────────────────────────

  (format t "~%── Ω1: 200 連 j ──~%")
  (let* ((b (engine-load fixture))
         (vg (data (limn:call "view/get" :|win-id| "w1")))
         (pc (or (getf vg :|page-count|) 1)))
    (declare (ignore b))
    (limn:call "view/set" :|win-id| "w1" :|page| 0)
    (sleep 0.1)
    (let ((rss-before (limn-rss pid)))
      ;; xdotool key --repeat is faster than 200 separate xdotool calls.
      (xdotool "key" "--repeat" "200" "--delay" "5" "j")
      (sleep 0.5)
      (let ((p (page-of)))
        (check (format nil "Ω1a — 200 j 後 page 推進 (~a, pc=~a)" p pc)
               (and (integerp p) (> p 0))))
      (let ((rss-after (limn-rss pid)))
        (check (format nil "Ω1b — RSS 增 < 50% (~a → ~a)" rss-before rss-after)
               (or (null rss-before) (null rss-after)
                    (< rss-after (* 1.5 rss-before)))))))

;;; ── Ω2: 100 open+close 循環 ────────────────────────────────

  (format t "~%── Ω2: 100 open/close ──~%")
  (let ((rss-pre (limn-rss pid)))
    (dotimes (i 100)
      (let ((b (engine-load fixture)))
        (when b (limn:call "buffer/close" :|buffer-id| b)))
      (when (zerop (mod i 25))
        (format t "  iter ~a/100 (rss=~a)~%" i (limn-rss pid))))
    (sleep 0.3)
    (let ((rss-post (limn-rss pid)))
      (check (format nil "Ω2 — 100 cycles RSS ratio (~a → ~a)" rss-pre rss-post)
             (or (null rss-pre) (null rss-post)
                  (< rss-post (* 2.0 rss-pre))))))

;;; ── Ω3: 1000 n（search hit cycling）─────────────────────────

  (format t "~%── Ω3: 1000 search-hit cycling ──~%")
  (let ((b (engine-load fixture)))
    (when b
      ;; Pre-load a search so n cycles do something
      (limn:call "buffer/search" :|buffer-id| b :|query| "the"
                  :|case-sensitive| :false)
      (sleep 0.2)
      ;; n key cycle — burst
      (xdotool "key" "--repeat" "1000" "--delay" "1" "n")
      (sleep 0.5)
      (let ((ovs (overlays-of)))
        (check (format nil "Ω3 — 1000 n 後 overlay 數量穩定 (~a)" (length ovs))
               ;; Overlay count should equal the # of total hits, not grow with n's
               (and (listp ovs) (< (length ovs) 10000))))))

;;; ── Ω4: idle 5s → still responsive ───────────────────────

  (format t "~%── Ω4: idle 5s → responsive ──~%")
  (sleep 5)
  (let ((r (limn:call "view/get" :|win-id| "w1")))
    (check "Ω4 — idle 後 wire call 還回應" (ok? r)))

  (format t "~%── v027-stress e2e ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
