;;;; OS-tier batch v0.23 §A: real subprocess spawn
;;;;
;;;; Verifies limn/process against REAL /bin/sh, REAL exit codes,
;;;; REAL stderr separation, REAL pipe round-trip. Unit tier uses
;;;; the same shell but inside the unit-test framework's faster
;;;; harness; this batch re-exercises the contract under the OS-tier
;;;; runner so any docker/CI quirk shows up.
;;;;
;;;; No Xvfb / xdotool / limn binary needed. Pure Lisp.

(in-package :cl-user)
(require :sb-posix)

(defparameter *bdir*
  (or (handler-case (sb-posix:getenv "LIMN_BACKEND_DIR") (error () nil))
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))

(load (concatenate 'string *bdir* "limn-hooks.lisp"))
(load (concatenate 'string *bdir* "limn-log.lisp"))
(load (concatenate 'string *bdir* "limn-error.lisp"))
(load (concatenate 'string *bdir* "limn-process.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    → ~a~%" details))
  (unless ok (push msg *failures*)))

(defun %first-exists (paths)
  (loop for p in paths when (probe-file p) return p))

;;; v0.37 Phase F (driver-C1): the docker container is nix-based, so
;;; coreutils live at /nix/store/.../bin and are reachable via $PATH or
;;; /root/.nix-profile/bin — they are NOT under /bin or /usr/bin.  The
;;; original hardcoded list returns NIL for true/echo/cat in the
;;; container, and make-process then chokes on `(list nil ...)`.  Walk
;;; PATH if the canonical UNIX paths are missing.
(defun %split-path (s)
  (loop with start = 0
        for i from 0 below (length s)
        when (char= (char s i) #\:)
          collect (subseq s start i) into dirs
          and do (setf start (1+ i))
        finally (return (append dirs (list (subseq s start))))))

(defun %find-on-path (name)
  (let ((path (or (sb-posix:getenv "PATH") "")))
    (loop for dir in (%split-path path)
          for full = (and (plusp (length dir))
                          (concatenate 'string dir "/" name))
          when (and full (probe-file full)) return full)))

(defun %bin (name canonical-paths)
  (or (%first-exists canonical-paths)
      (%find-on-path name)))

(defparameter *true* (%bin "true" '("/usr/bin/true" "/bin/true")))
(defparameter *sh*   (%bin "sh"   '("/bin/sh" "/usr/bin/sh")))
(defparameter *echo* (%bin "echo" '("/bin/echo" "/usr/bin/echo")))
(defparameter *cat*  (%bin "cat"  '("/bin/cat" "/usr/bin/cat")))

(unless (and *true* *sh* *echo* *cat*)
  (format t "  SKIP: required binaries missing (true=~a sh=~a echo=~a cat=~a)~%"
          *true* *sh* *echo* *cat*)
  (sb-ext:exit :code 77))

(format t "~%=== batch-os-v023-process-shell ===~%")
(format t "shell=~a echo=~a cat=~a~%" *sh* *echo* *cat*)

;;; ── echo → stdout ────────────────────────────────────────────────────
(let ((p (limn/process:make-process
          :command (list *echo* "hello-from-subprocess"))))
  (limn/process:process-wait p :timeout 5)
  (check "echo exit 0" (eql 0 (limn/process:process-exit-code p)))
  (check "echo stdout has marker"
         (search "hello-from-subprocess" (limn/process:process-stdout p))))

;;; ── sh -c with stdout + stderr + non-zero exit ───────────────────────
(let ((p (limn/process:make-process
          :command (list *sh* "-c" "echo OUT; echo ERR >&2; exit 3"))))
  (limn/process:process-wait p :timeout 5)
  (check "shell exit 3" (eql 3 (limn/process:process-exit-code p)))
  (check "shell stdout has OUT"
         (search "OUT" (limn/process:process-stdout p)))
  (check "shell stderr has ERR"
         (search "ERR" (limn/process:process-stderr p)))
  (check "shell stdout has NO ERR"
         (not (search "ERR" (limn/process:process-stdout p)))))

;;; ── cat round-trip via stdin ─────────────────────────────────────────
(let ((p (limn/process:make-process :command (list *cat*))))
  (limn/process:process-send-string p "ping-round-trip
")
  (limn/process:process-send-eof p)
  (limn/process:process-wait p :timeout 5)
  (check "cat round-trip" (search "ping-round-trip"
                                  (limn/process:process-stdout p))))

;;; ── true exit clean ──────────────────────────────────────────────────
(let ((p (limn/process:make-process :command (list *true*))))
  (limn/process:process-wait p :timeout 5)
  (check "true exit 0" (eql 0 (limn/process:process-exit-code p)))
  (check "true status :EXIT"
         (eq :exit (limn/process:process-status p))))

;;; ── stderr merge to stdout ───────────────────────────────────────────
(let ((p (limn/process:make-process
          :command (list *sh* "-c" "echo OUT; echo ERR >&2")
          :stderr :stdout)))
  (limn/process:process-wait p :timeout 5)
  (let ((combined (limn/process:process-stdout p)))
    (check "merge: combined has OUT" (search "OUT" combined))
    (check "merge: combined has ERR" (search "ERR" combined))
    (check "merge: stderr buffer empty"
           (zerop (length (limn/process:process-stderr p))))))

;;; ── Verdict ──────────────────────────────────────────────────────────
(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failures)~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
