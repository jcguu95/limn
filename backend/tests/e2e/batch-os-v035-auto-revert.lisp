;;;; v0.35 §A+B+C OS-tier — file-notify + auto-revert + process-coding
;;;;
;;;; Runs inside the production Limn container (nix SBCL + real Limn
;;;; binary + real inotify-tools).  Validates that:
;;;;
;;;;   Ω1: container has a file-notify backend available
;;;;       (inotifywait on Linux, fswatch on macOS — only inotify here)
;;;;
;;;;   Ω2: limn/file-notify subscribes to a real file via the real helper
;;;;       subprocess; an external `echo >> file` delivers a :modified
;;;;       event within 2 seconds.
;;;;
;;;;   Ω3: limn/auto-revert wired on a real fbuf — external append →
;;;;       buffer-set-content sees the new content within 2 seconds.
;;;;
;;;;   Ω4: limn/auto-revert-tail-mode — cursor follows append.
;;;;
;;;;   Ω5: limn/process with :coding-system 'utf-8 → /bin/cat round-trip
;;;;       of "中文" preserves the string end-to-end.
;;;;
;;;;   Ω6: limn/process with :decode-coding-system 'big5 → printf big5
;;;;       bytes (你好 = A4 41 A6 6E in Big5) decode correctly.
;;;;
;;;; RED until v0.35 implementation lands.

(in-package :cl-user)
(require :sb-posix)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))

(defun b/ (f) (concatenate 'string *bdir* f))

;; ── load backend modules ────────────────────────────────────────────────

(dolist (f '("limn-hooks.lisp"
             "limn-log.lisp"
             "limn-error.lisp"
             "limn-timer.lisp"
             "limn-process.lisp"
             "limn-marker.lisp"
             "limn-local.lisp"
             "limn-coding.lisp"
             "limn-file.lisp"
             "limn-file-notify.lisp"
             "limn-auto-revert.lisp"))
  (handler-case (load (b/ f))
    (error (e) (format t "  !! skipped ~A: ~A~%" f e))))

;; ── harness ─────────────────────────────────────────────────────────────

(defparameter *failures* nil)

(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details)
    (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun poll-until (pred &key (timeout 5.0) (interval 0.05))
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (funcall pred) (return t))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep interval))))

(defun which (binary)
  "Locate BINARY on PATH. Works on FHS and NixOS (where /usr/bin/env exists)."
  (let* ((out (make-string-output-stream)))
    (handler-case
        (let ((p (sb-ext:run-program "/usr/bin/env" (list "which" binary)
                                      :search nil :wait t
                                      :output out :error nil)))
          (when (and p (= (sb-ext:process-exit-code p) 0))
            (let ((line (string-trim '(#\Newline #\Space)
                                      (get-output-stream-string out))))
              (and (plusp (length line)) line))))
      (error () nil))))

(defun shell (cmd)
  (sb-ext:run-program "/bin/sh" (list "-c" cmd)
                       :search nil :wait t
                       :output nil :error nil))

(defparameter *cat-bin*
  (or (which "cat")
      (loop for p in '("/bin/cat" "/usr/bin/cat" "/run/current-system/sw/bin/cat")
            when (probe-file p) return p)
      "/bin/cat"))

;; ── Ω1: probe a file-notify backend ─────────────────────────────────────

(format t "~%── Ω1: file-notify backend available ──~%")
(let ((inotify (which "inotifywait"))
      (fswatch (which "fswatch")))
  (check (format nil "inotifywait OR fswatch on PATH (inotify=~a fswatch=~a)"
                 inotify fswatch)
         (or inotify fswatch)
         "v0.35 needs at least one OS-level watcher in the container"))

;; ── Ω2: real file-notify subscription via real helper ───────────────────

(format t "~%── Ω2: limn/file-notify subscribes and receives :modified ──~%")
(let ((fn-pkg (find-package '#:limn/file-notify)))
  (cond
    ((null fn-pkg)
     (check "limn/file-notify package present" nil "module not loaded"))
    (t
     (let* ((path (format nil "/tmp/limn-v035-~D-fn.txt"
                          (sb-posix:getpid)))
            (add-fn (symbol-function
                      (find-symbol "FILE-NOTIFY-ADD-WATCH" fn-pkg)))
            (rm-fn  (symbol-function
                      (find-symbol "FILE-NOTIFY-RM-WATCH" fn-pkg)))
            (events '()))
       (shell (format nil "echo initial > ~a" path))
       (unwind-protect
            (handler-case
                (let ((d (funcall add-fn path '(:change)
                                   (lambda (ev) (push ev events)))))
                  (check "subscription returned descriptor" d)
                  ;; brief grace for helper to start
                  (sleep 0.3)
                  (shell (format nil "echo more >> ~a" path))
                  (let ((got (poll-until
                               (lambda () (some (lambda (e)
                                                  (eq :modified (getf e :action)))
                                                events))
                               :timeout 5.0)))
                    (check "received :modified event within 5s" got
                           (format nil "events seen: ~s" events)))
                  (funcall rm-fn d))
              (error (e)
                (check "no unhandled error" nil (format nil "~A" e))))
         (ignore-errors (delete-file path)))))))

;; ── Ω3: auto-revert end-to-end ──────────────────────────────────────────

;; NOTE: vtable functions must be installed via setf-symbol-value (a global
;; binding), NOT progv (dynamic binding) — file-notify events arrive on the
;; limn/process reader thread, which doesn't inherit our dynamic bindings.

(format t "~%── Ω3: auto-revert auto-updates on external write ──~%")
(let ((ar-pkg   (find-package '#:limn/auto-revert))
      (file-pkg (find-package '#:limn/file)))
  (cond
    ((not (and ar-pkg file-pkg))
     (check "limn/auto-revert & limn/file loaded" nil "RED"))
    (t
     (let* ((path (format nil "/tmp/limn-v035-~D-ar.txt"
                          (sb-posix:getpid)))
            (content-store (list ""))
            (find-fn (symbol-function (find-symbol "FIND-FILE" file-pkg)))
            (cont-sym (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
            (ar-fn (symbol-function
                     (find-symbol "AUTO-REVERT-MODE" ar-pkg)))
            (saved-cont (symbol-value cont-sym)))
       (shell (format nil "echo initial > ~a" path))
       (setf (symbol-value cont-sym)
             (lambda (bid s) (declare (ignore bid))
               (setf (first content-store) s)))
       (unwind-protect
            (handler-case
                (let ((bid (funcall find-fn path)))
                  (check "find-file returned a buffer id" bid)
                  (when bid
                    (funcall ar-fn bid)
                    (sleep 0.5)
                    (shell (format nil "echo appended >> ~a" path))
                    (let ((got (poll-until
                                 (lambda ()
                                   (search "appended"
                                           (first content-store)))
                                 :timeout 5.0)))
                      (check "buffer auto-updated within 5s" got
                             (format nil "content: ~s"
                                     (first content-store))))))
              (error (e)
                (check "no unhandled error" nil (format nil "~A" e))))
         (setf (symbol-value cont-sym) saved-cont)
         (ignore-errors (delete-file path)))))))

;; ── Ω4: tail-mode follows append ────────────────────────────────────────

(format t "~%── Ω4: auto-revert-tail-mode cursor follows ──~%")
(let ((ar-pkg   (find-package '#:limn/auto-revert))
      (file-pkg (find-package '#:limn/file)))
  (cond
    ((not (and ar-pkg file-pkg))
     (check "modules loaded" nil "RED"))
    (t
     (let* ((path (format nil "/tmp/limn-v035-~D-tail.txt"
                          (sb-posix:getpid)))
            (content-store (list ""))
            (cursor-store (list 0))
            (find-fn (symbol-function (find-symbol "FIND-FILE" file-pkg)))
            (cont-sym (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
            (cur-sym  (find-symbol "*CURSOR-SET-FN*" ar-pkg))
            (txt-sym  (find-symbol "*BUFFER-TEXT-FN*" ar-pkg))
            (tail-fn (symbol-function
                       (find-symbol "AUTO-REVERT-TAIL-MODE" ar-pkg)))
            (saved-cont (symbol-value cont-sym))
            (saved-cur  (symbol-value cur-sym))
            (saved-txt  (symbol-value txt-sym)))
       (shell (format nil "echo first > ~a" path))
       (setf (symbol-value cont-sym)
             (lambda (bid s) (declare (ignore bid))
               (setf (first content-store) s))
             (symbol-value cur-sym)
             (lambda (bid pos) (declare (ignore bid))
               (setf (first cursor-store) pos))
             (symbol-value txt-sym)
             ;; tail-mode needs the current text length to compute point-max
             (lambda (bid) (declare (ignore bid))
               (first content-store)))
       (unwind-protect
            (handler-case
                (progn
                  (let ((bid (funcall find-fn path)))
                    (when bid
                      (funcall tail-fn bid)
                      (sleep 0.3)
                      (shell (format nil "echo line-two >> ~a" path))
                      (let ((got (poll-until
                                   (lambda ()
                                     (and (search "line-two"
                                                   (first content-store))
                                          (= (first cursor-store)
                                             (length (first content-store)))))
                                   :timeout 5.0)))
                        (check "tail-mode: content updated AND cursor=point-max" got
                               (format nil "content=~s cursor=~a"
                                       (first content-store)
                                       (first cursor-store)))))))
              (error (e)
                (check "no unhandled error" nil (format nil "~A" e))))
         (setf (symbol-value cont-sym) saved-cont
               (symbol-value cur-sym)  saved-cur
               (symbol-value txt-sym)  saved-txt)
         (ignore-errors (delete-file path)))))))

;; ── Ω5: process-coding UTF-8 round-trip ─────────────────────────────────

(format t "~%── Ω5: limn/process :coding-system utf-8 round-trip ──~%")
(let ((proc-pkg (find-package '#:limn/process))
      (cod-pkg  (find-package '#:limn/coding)))
  (cond
    ((not (and proc-pkg cod-pkg))
     (check "process/coding loaded" nil "RED"))
    (t
     (handler-case
         (let* ((mk   (symbol-function (find-symbol "MAKE-PROCESS"        proc-pkg)))
                (snd  (symbol-function (find-symbol "PROCESS-SEND-STRING" proc-pkg)))
                (eof  (symbol-function (find-symbol "PROCESS-SEND-EOF"    proc-pkg)))
                (wait (symbol-function (find-symbol "PROCESS-WAIT"        proc-pkg)))
                (out  (symbol-function (find-symbol "PROCESS-STDOUT"      proc-pkg)))
                (p (funcall mk :command (list *cat-bin*) :coding-system 'utf-8)))
           (funcall snd p "中文")
           (funcall eof p)
           (funcall wait p :timeout 5)
           (let ((s (funcall out p)))
             (check (format nil "stdout contains 中文; got ~s" s)
                    (search "中文" s))))
       (error (e)
         (check "no unhandled error" nil (format nil "~A" e)))))))

;; ── Ω6: process-coding decode GB18030 ───────────────────────────────────

(format t "~%── Ω6: limn/process :decode-coding-system gb18030 ──~%")
(let ((proc-pkg (find-package '#:limn/process))
      (cod-pkg  (find-package '#:limn/coding)))
  (cond
    ((not (and proc-pkg cod-pkg))
     (check "process/coding loaded" nil "RED"))
    (t
     ;; GB18030 is natively supported in Linux SBCL (:gbk external-format).
     ;; Big5 isn't always available — we use GB18030 here for the OS-tier
     ;; smoke check; the Big5 path is covered by unit-tier on macOS.
     (handler-case
         ;; "你好" in GB18030 (= GBK): C4 E3 BA C3
         (let* ((mk   (symbol-function (find-symbol "MAKE-PROCESS"   proc-pkg)))
                (wait (symbol-function (find-symbol "PROCESS-WAIT"   proc-pkg)))
                (out  (symbol-function (find-symbol "PROCESS-STDOUT" proc-pkg)))
                (p (funcall mk
                            :command '("/bin/sh" "-c"
                                       "printf '\\xc4\\xe3\\xba\\xc3'")
                            :decode-coding-system 'gb18030)))
           (funcall wait p :timeout 5)
           (let ((s (funcall out p)))
             (check (format nil "decoded gb18030 stdout contains 你好; got ~s" s)
                    (search "你好" s))))
       (error (e)
         (check "no unhandled error" nil (format nil "~A" e)))))))

;; ── summary ─────────────────────────────────────────────────────────────

(format t "~%=== v0.35 file-notify + auto-revert + process-coding OS-tier: ~a failure(s) ===~%"
        (length *failures*))
(when *failures*
  (format t "Failed checks:~%")
  (dolist (f (reverse *failures*))
    (format t "  - ~a~%" f)))

(format t "VERDICT: ~a~%" (if *failures* "✗ FAIL" "✓ PASS"))
(sb-ext:exit :code (if *failures* 1 0))
