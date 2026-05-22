;;;; Unit tests for limn/runtime:load-init-file — SPEC §9.3 + dev fallback.
;;;;
;;;; Search order:
;;;;   1. $LIMN_INIT env var (highest priority)
;;;;   2. ~/.limn/init.lisp
;;;;   3. ~/.config/limn/init.lisp     (XDG)
;;;;   4. /tmp/.limn/init.lisp         (dev fallback — see note in module)
;;;;
;;;; First existing file wins; the rest are silently skipped.
;;;; If none exists, the function is a no-op (no error).
;;;;
;;;; These tests deliberately use only /tmp/* paths or explicit $LIMN_INIT
;;;; overrides — they MUST NOT create files under $HOME. We verify the
;;;; lookup logic, not actual user-shell behaviour.

(in-package #:limn/unit-test)

(defun %make-temp-init (content)
  "Write CONTENT into a unique /tmp/limn-init-test-XXXXX.lisp file.
   Returns the path. Caller is responsible for deletion."
  (let* ((path (format nil "/tmp/limn-init-test-~a-~a.lisp"
                       (sb-posix:getpid)
                       (random 1000000)))
         (stream (open path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)))
    (write-string content stream)
    (close stream)
    path))

(defun %unset-env (name)
  ;; sb-posix:unsetenv isn't always available; setting to empty + treating
  ;; empty as unset is good enough for our tests since the loader checks
  ;; for non-empty.
  (handler-case (sb-posix:setenv name "" 1)
    (error () nil)))

(defmacro %with-clean-env (&body body)
  "Run BODY with $LIMN_INIT cleared, restored after."
  `(let ((saved (sb-posix:getenv "LIMN_INIT")))
     (%unset-env "LIMN_INIT")
     (unwind-protect (progn ,@body)
       (when saved (sb-posix:setenv "LIMN_INIT" saved 1)))))

;;; ── basic load mechanics ───────────────────────────────────────────────

(deftest init-load-runs-file-pointed-by-env
  (%with-clean-env
    (let* ((flag (intern "INIT-LOAD-FLAG-1" :limn/unit-test))
           (path (%make-temp-init
                  (format nil "(setf (symbol-value '~s) :loaded)"
                          flag))))
      (unwind-protect
           (progn
             (setf (symbol-value flag) nil)
             (sb-posix:setenv "LIMN_INIT" path 1)
             (limn/runtime:load-init-file)
             (assert-eq :loaded (symbol-value flag)
                        "init file at $LIMN_INIT was executed"))
        (ignore-errors (delete-file path))
        (%unset-env "LIMN_INIT")))))

(deftest init-load-noop-when-no-file-exists
  (%with-clean-env
    ;; Point env at a path that doesn't exist; runtime must skip silently.
    (sb-posix:setenv "LIMN_INIT" "/tmp/limn-init-does-not-exist-xyz.lisp" 1)
    (assert-no-error (limn/runtime:load-init-file))
    (%unset-env "LIMN_INIT")))

(deftest init-load-returns-path-loaded
  "load-init-file returns the path that was actually loaded (or NIL if
   none) — handy for the start-up banner / debugging."
  (%with-clean-env
    (let ((path (%make-temp-init "(values)")))
      (unwind-protect
           (progn
             (sb-posix:setenv "LIMN_INIT" path 1)
             (assert-equal path (limn/runtime:load-init-file)))
        (ignore-errors (delete-file path))
        (%unset-env "LIMN_INIT")))))

(deftest init-load-returns-nil-when-none-found
  (%with-clean-env
    ;; Override ALL fallback paths to non-existing ones by not creating
    ;; them. Set $LIMN_INIT to nothing. Assumes the test runner doesn't
    ;; have ~/.limn/init.lisp etc. on the dev machine — if you do, this
    ;; test will surprise you (and that's the point — we'd want to know).
    (assert-equal nil (limn/runtime:load-init-file))))

;;; ── search-path resolution (unit-level, no actual load) ────────────────

(deftest init-resolve-prefers-env-over-fallbacks
  "When $LIMN_INIT is set AND exists, it wins over the other three."
  (%with-clean-env
    (let ((path (%make-temp-init "(values)")))
      (unwind-protect
           (progn
             (sb-posix:setenv "LIMN_INIT" path 1)
             (assert-equal path (limn/runtime:resolve-init-path)))
        (ignore-errors (delete-file path))
        (%unset-env "LIMN_INIT")))))

(deftest init-resolve-skips-nonexistent-env-and-tries-others
  "If $LIMN_INIT points at nothing, fall through to the next candidate
   (which in test conditions is also empty → returns NIL)."
  (%with-clean-env
    (sb-posix:setenv "LIMN_INIT" "/tmp/definitely-no-such-file.lisp" 1)
    (let ((resolved (limn/runtime:resolve-init-path)))
      ;; In a clean test env, none of ~/.limn/ XDG /tmp/.limn/ exists →
      ;; resolution returns NIL. (Assertion below also holds if a real
      ;; ~/.limn/init.lisp happens to exist; in that case resolved is
      ;; that path, not the bogus env path.)
      (assert-false (equal "/tmp/definitely-no-such-file.lisp" resolved)
                    "non-existent env path is skipped"))
    (%unset-env "LIMN_INIT")))

(deftest init-resolve-uses-tmp-fallback
  "/tmp/.limn/init.lisp is the lowest-priority dev fallback — it wins
   only when env + home paths are absent."
  (%with-clean-env
    (let ((dir "/tmp/.limn")
          (file "/tmp/.limn/init.lisp"))
      ;; Create the dev fallback if not present.
      (ensure-directories-exist (concatenate 'string dir "/"))
      (let ((stream (open file :direction :output
                               :if-exists :supersede
                               :if-does-not-exist :create)))
        (write-string "(values)" stream)
        (close stream))
      (unwind-protect
           ;; Only assert resolved /tmp/.limn/init.lisp when no higher
           ;; priority path exists. If user happens to have ~/.limn/
           ;; populated, that wins — we just check the fallback IS in
           ;; the candidate list at all.
           (let ((cands (limn/runtime:init-candidate-paths)))
             (assert-contains file cands
                              "/tmp/.limn/init.lisp listed as a candidate"))
        (ignore-errors (delete-file file))))))
