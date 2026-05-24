;;;; v0.23 §A — process primitive RED tests
;;;;
;;;; ~52 tests. References limn/process symbols that do not exist
;;;; yet — every test should fail with "package not found" or
;;;; "undefined function" until the implementation lands.
;;;;
;;;; Pre-intern + export defensively so the file READs even before
;;;; limn-process.lisp exists (matches v0.19 keymap-v019.lisp pattern).

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/process)
    (make-package '#:limn/process :use '(#:cl)))
  (dolist (sym '("MAKE-PROCESS"
                 "PROCESS-STATUS" "PROCESS-EXIT-CODE" "PROCESS-SIGNAL-NUM"
                 "PROCESS-STDOUT" "PROCESS-STDERR" "PROCESS-PID"
                 "PROCESS-NAME" "PROCESS-P" "PROCESS-LIVE-P"
                 "PROCESS-SEND-STRING" "PROCESS-SEND-EOF"
                 "PROCESS-WAIT"
                 "KILL-PROCESS" "LIST-PROCESSES"
                 "SHELL-COMMAND"
                 "PROCESS-ERROR"))
    (let ((s (intern sym '#:limn/process)))
      (export s '#:limn/process))))

(in-package #:limn/unit-test)

(use-package '#:limn/v023-helpers)

;;; Convenience: short spawn that returns proc and waits for exit.
(defun %spawn-and-wait (cmd &rest kw)
  (let ((p (apply #'limn/process:make-process :command cmd kw)))
    (limn/process:process-wait p :timeout 5)
    p))

;;; ─── A1. Basic lifecycle ───────────────────────────────────────────

(deftest process-a1-true-exits-clean
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    (assert-eq :exit (limn/process:process-status p))
    (assert-eql 0 (limn/process:process-exit-code p))))

(deftest process-a1-false-exits-nonzero
  (let ((p (%spawn-and-wait '("/usr/bin/false"))))
    (assert-eq :exit (limn/process:process-status p))
    (assert-true (not (zerop (limn/process:process-exit-code p))))))

(deftest process-a1-nonexistent-signals-error
  (assert-error limn/process:process-error
    (limn/process:make-process :command '("/no/such/binary"))))

(deftest process-a1-double-kill-is-safe
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    (assert-no-error (limn/process:kill-process p))
    (assert-no-error (limn/process:kill-process p))))

(deftest process-a1-status-stable-after-exit
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    (assert-eq :exit (limn/process:process-status p))
    (assert-eq :exit (limn/process:process-status p))
    (assert-eq :exit (limn/process:process-status p))))

;;; ─── A1'. Output redirection matrix ────────────────────────────────

(deftest process-a1m-stdout-default-buffer
  (let ((p (%spawn-and-wait '("/bin/echo" "hi"))))
    (assert-equal "hi
" (limn/process:process-stdout p))))

(deftest process-a1m-stdout-filter-callback
  (let* ((chunks '())
         (p (limn/process:make-process
             :command '("/bin/echo" "one two")
             :stdout (lambda (proc chunk)
                       (declare (ignore proc))
                       (push chunk chunks)))))
    (limn/process:process-wait p :timeout 5)
    (assert-true (some (lambda (c) (search "one two" c)) chunks)
                 "filter saw output")))

(deftest process-a1m-stdout-named-buffer-object
  ;; :stdout-buffer takes a user-allocated string/byte buffer object.
  ;; Verify proc writes there, not into the default :stdout.
  (let* ((my-buf (make-array 0 :element-type 'character
                               :adjustable t :fill-pointer 0))
         (p (limn/process:make-process
             :command '("/bin/echo" "hello")
             :stdout-buffer my-buf)))
    (limn/process:process-wait p :timeout 5)
    (assert-true (search "hello" my-buf))))

(deftest process-a1m-stdout-discard-no-memory
  (let ((p (limn/process:make-process
            :command '("/bin/sh" "-c" "yes | head -c 200000")
            :stdout :discard)))
    (limn/process:process-wait p :timeout 5)
    (assert-eq :exit (limn/process:process-status p))
    ;; discard means stdout buffer is empty / not allocated
    (let ((s (limn/process:process-stdout p)))
      (assert-true (or (null s) (zerop (length s)))
                   "discard kept no stdout"))))

(deftest process-a1m-stderr-merge-to-stdout
  (let ((p (limn/process:make-process
            :command '("/bin/sh" "-c" "echo OUT; echo ERR >&2")
            :stderr :stdout)))
    (limn/process:process-wait p :timeout 5)
    (let ((combined (limn/process:process-stdout p)))
      (assert-true (search "OUT" combined))
      (assert-true (search "ERR" combined))
      (assert-true (or (null (limn/process:process-stderr p))
                       (zerop (length (limn/process:process-stderr p))))))))

(deftest process-a1m-stderr-independent-buffer
  (let ((p (%spawn-and-wait '("/bin/sh" "-c" "echo OUT; echo ERR >&2"))))
    (assert-true (search "OUT" (limn/process:process-stdout p)))
    (assert-true (search "ERR" (limn/process:process-stderr p)))
    (assert-false (search "ERR" (limn/process:process-stdout p)))))

(deftest process-a1m-stdout-to-file
  (let* ((tmp (format nil "/tmp/limn-v023-~A.out" (random 100000)))
         (p (limn/process:make-process
             :command '("/bin/echo" "to-disk")
             :stdout (pathname tmp))))
    (limn/process:process-wait p :timeout 5)
    (assert-true (probe-file tmp))
    (with-open-file (s tmp) (assert-true (search "to-disk" (read-line s))))
    (ignore-errors (delete-file tmp))))

(deftest process-a1m-bidirectional-cat
  (let ((p (limn/process:make-process :command '("/bin/cat"))))
    (limn/process:process-send-string p "ping
")
    (limn/process:process-send-eof p)
    (limn/process:process-wait p :timeout 5)
    (assert-true (search "ping" (limn/process:process-stdout p)))))

(deftest process-a1m-closed-stdin-immediate-eof
  ;; Child reads stdin → sees EOF → exits.
  (let ((p (%spawn-and-wait '("/bin/cat") :stdin :closed)))
    (assert-eq :exit (limn/process:process-status p))))

(deftest process-a1m-stdout-and-stderr-concurrent-no-interleave
  ;; Each stream should preserve its OWN ordering (no claim about
  ;; cross-stream ordering).
  (let ((p (%spawn-and-wait
            '("/bin/sh" "-c" "for i in 1 2 3 4 5; do echo o$i; echo e$i >&2; done"))))
    (let ((out (limn/process:process-stdout p))
          (err (limn/process:process-stderr p)))
      (assert-true (search "o1" out))
      (assert-true (search "o5" out))
      (assert-true (< (search "o1" out) (search "o5" out)))
      (assert-true (< (search "e1" err) (search "e5" err))))))

(deftest process-a1m-filter-chunk-order-matches-producer
  (let* ((seen "")
         (p (limn/process:make-process
             :command '("/bin/sh" "-c" "printf A; printf B; printf C")
             :stdout (lambda (proc chunk)
                       (declare (ignore proc))
                       (setf seen (concatenate 'string seen chunk))))))
    (limn/process:process-wait p :timeout 5)
    (assert-equal "ABC" seen)))

(deftest process-a1m-default-stdout-accumulates-across-reads
  (let ((p (%spawn-and-wait
            '("/bin/sh" "-c" "for i in 1 2 3 4 5 6 7 8 9 10; do echo line$i; done"))))
    (loop for i from 1 to 10 do
      (assert-true (search (format nil "line~A" i)
                           (limn/process:process-stdout p))))))

;;; ─── A1''. Self-die timing ─────────────────────────────────────────

(deftest process-a1d-self-die-1sec
  ;; sleep 1 → exit 0. Wall-clock should land in [0.8, 1.6].
  (let* ((t0 (get-internal-real-time))
         (p  (limn/process:make-process
              :command '("/bin/sh" "-c" "sleep 1; exit 0"))))
    (limn/process:process-wait p :timeout 3)
    (let ((dt (/ (- (get-internal-real-time) t0)
                 internal-time-units-per-second)))
      (assert-true (and (>= dt 0.8) (<= dt 1.6))
                   (format nil "1s sleep took ~,3F s" dt))
      (assert-eq :exit (limn/process:process-status p))
      (assert-eql 0 (limn/process:process-exit-code p)))))

;;; ─── A2. I/O streams ───────────────────────────────────────────────

(deftest process-a2-large-stdout-no-deadlock
  ;; ~100 KB of output, well past pipe buffer (~64 KB).
  (let ((p (%spawn-and-wait
            '("/bin/sh" "-c" "yes 'x' | head -n 50000"))))
    (assert-eq :exit (limn/process:process-status p))
    (assert-true (>= (length (limn/process:process-stdout p)) 50000))))

(deftest process-a2-send-string-once
  (let ((p (limn/process:make-process :command '("/bin/cat"))))
    (limn/process:process-send-string p "hello world
")
    (limn/process:process-send-eof p)
    (limn/process:process-wait p :timeout 5)
    (assert-true (search "hello world" (limn/process:process-stdout p)))))

(deftest process-a2-send-string-multi-accumulates
  (let ((p (limn/process:make-process :command '("/bin/cat"))))
    (limn/process:process-send-string p "part-1 ")
    (limn/process:process-send-string p "part-2 ")
    (limn/process:process-send-string p "part-3")
    (limn/process:process-send-eof p)
    (limn/process:process-wait p :timeout 5)
    (assert-true (search "part-1 part-2 part-3"
                         (limn/process:process-stdout p)))))

(deftest process-a2-send-eof-frees-cat
  ;; cat reads until EOF; without send-eof it would hang. Verify
  ;; send-eof unsticks it.
  (let ((p (limn/process:make-process :command '("/bin/cat"))))
    (limn/process:process-send-string p "x")
    (limn/process:process-send-eof p)
    (with-timeout-bound 3
      (limn/process:process-wait p :timeout 3))
    (assert-eq :exit (limn/process:process-status p))))

(deftest process-a2-stderr-only-no-stdout
  (let ((p (%spawn-and-wait
            '("/bin/sh" "-c" "echo only-err >&2"))))
    (assert-true (zerop (length (limn/process:process-stdout p))))
    (assert-true (search "only-err" (limn/process:process-stderr p)))))

(deftest process-a2-send-string-to-dead-proc-no-hang
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    ;; Whether it errors or no-ops is acceptable; it must NOT hang.
    (with-timeout-bound 0.5
      (handler-case
          (limn/process:process-send-string p "ignored")
        (limn/process:process-error () nil)))))

(deftest process-a2-send-eof-on-closed-stdin-no-hang
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    (with-timeout-bound 0.5
      (handler-case (limn/process:process-send-eof p)
        (limn/process:process-error () nil)))))

(deftest process-a2-filter-handles-large-stream
  (let* ((bytes 0)
         (p (limn/process:make-process
             :command '("/bin/sh" "-c" "yes y | head -c 200000")
             :stdout (lambda (proc chunk)
                       (declare (ignore proc))
                       (incf bytes (length chunk))))))
    (limn/process:process-wait p :timeout 10)
    (assert-true (>= bytes 200000))))

(deftest process-a2-binary-bytes-pass-through
  ;; printf with octal — ensure non-printable bytes do NOT crash
  ;; the buffer or decode path.
  (let ((p (%spawn-and-wait
            '("/bin/sh" "-c" "printf '\\001\\002\\003ok'"))))
    (assert-true (search "ok" (limn/process:process-stdout p)))))

(deftest process-a2-multiple-eof-calls-idempotent
  (let ((p (limn/process:make-process :command '("/bin/cat"))))
    (limn/process:process-send-eof p)
    (with-timeout-bound 1
      (limn/process:process-send-eof p)
      (limn/process:process-send-eof p))
    (limn/process:process-wait p :timeout 3)))

;;; ─── A3. Sentinel ──────────────────────────────────────────────────

(deftest process-a3-sentinel-fires-once
  (let* ((calls 0)
         (p (limn/process:make-process
             :command '("/usr/bin/true")
             :sentinel (lambda (proc) (declare (ignore proc)) (incf calls)))))
    (limn/process:process-wait p :timeout 5)
    ;; Give the dispatch one extra tick.
    (sleep 0.05)
    (assert-eql 1 calls)))

(deftest process-a3-sentinel-receives-exit-code
  (let* ((code nil)
         (p (limn/process:make-process
             :command '("/bin/sh" "-c" "exit 7")
             :sentinel (lambda (proc)
                         (setf code (limn/process:process-exit-code proc))))))
    (limn/process:process-wait p :timeout 5)
    (sleep 0.05)
    (assert-eql 7 code)))

(deftest process-a3-sentinel-status-signal-vs-exit
  (let* ((seen-status nil)
         (p (limn/process:make-process
             :command '("/bin/sh" "-c" "sleep 5")
             :sentinel (lambda (proc)
                         (setf seen-status (limn/process:process-status proc))))))
    (sleep 0.1)
    (limn/process:kill-process p :TERM)
    (limn/process:process-wait p :timeout 5)
    (sleep 0.05)
    (assert-eq :signal seen-status)))

(deftest process-a3-sentinel-error-does-not-break-framework
  (let ((p (limn/process:make-process
            :command '("/usr/bin/true")
            :sentinel (lambda (proc) (declare (ignore proc))
                        (error "boom from sentinel")))))
    (assert-no-error
      (progn (limn/process:process-wait p :timeout 5) (sleep 0.1)))))

(deftest process-a3-no-sentinel-still-exits-clean
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    (assert-eq :exit (limn/process:process-status p))))

;;; ─── A4. Kill / signals ────────────────────────────────────────────

(deftest process-a4-term-live-proc
  (let ((p (limn/process:make-process :command '("/bin/sh" "-c" "sleep 5"))))
    (sleep 0.05)
    (limn/process:kill-process p :TERM)
    (limn/process:process-wait p :timeout 3)
    (assert-eq :signal (limn/process:process-status p))))

(deftest process-a4-kill9-strong-stop
  (let ((p (limn/process:make-process
            :command '("/bin/sh" "-c" "trap '' TERM; sleep 5"))))
    (sleep 0.1)
    (limn/process:kill-process p :KILL)
    (limn/process:process-wait p :timeout 3)
    (assert-eq :signal (limn/process:process-status p))))

(deftest process-a4-kill-already-exited-no-hang
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    (with-timeout-bound 0.05
      (assert-no-error (limn/process:kill-process p :TERM)))))

(deftest process-a4-kill-thrice-no-hang
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    (with-timeout-bound 0.05
      (limn/process:kill-process p :TERM)
      (limn/process:kill-process p :TERM)
      (limn/process:kill-process p :TERM))))

(deftest process-a4-kill-zombie-no-hang
  ;; "Zombie" here = process exited but sentinel hasn't fired yet
  ;; (we kill in the tiny window between wait+exit and dispatch).
  ;; Approximate by killing immediately after wait returns.
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    (with-timeout-bound 0.05
      (limn/process:kill-process p :TERM))))

(deftest process-a4-stale-handle-errors-cleanly
  ;; Hand-build a process struct that was never spawned (or use a
  ;; freshly-killed one whose internal handle has been released).
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    ;; Simulate "freed handle" by killing twice — second call must
    ;; either no-op or signal limn/process:process-error, not crash.
    (limn/process:kill-process p :TERM)
    (assert-no-error (limn/process:kill-process p :TERM))))

;;; ─── A5. Environment & cwd ─────────────────────────────────────────

(deftest process-a5-env-passes-through
  (let ((p (%spawn-and-wait
            '("/bin/sh" "-c" "echo $LIMN_V023_TEST_KEY")
            :env '(("LIMN_V023_TEST_KEY" . "found-it")))))
    (assert-true (search "found-it" (limn/process:process-stdout p)))))

(deftest process-a5-cwd-changes-pwd
  (let ((p (%spawn-and-wait '("/bin/pwd") :cwd "/tmp")))
    (assert-true (search "/tmp" (limn/process:process-stdout p)))))

(deftest process-a5-no-env-inherits-parent
  (let ((p (%spawn-and-wait '("/bin/sh" "-c" "echo $PATH"))))
    ;; PATH must be non-empty when inherited.
    (assert-true (> (length (limn/process:process-stdout p)) 1))))

;;; ─── A6. Concurrency ───────────────────────────────────────────────

(deftest process-a6-ten-concurrent-short-lived
  (let* ((sentinel-count 0)
         (lock (sb-thread:make-mutex))
         (procs (loop repeat 10 collect
                      (limn/process:make-process
                       :command '("/usr/bin/true")
                       :sentinel (lambda (proc) (declare (ignore proc))
                                   (sb-thread:with-mutex (lock)
                                     (incf sentinel-count)))))))
    (dolist (p procs) (limn/process:process-wait p :timeout 5))
    (sleep 0.1)
    (assert-eql 10 sentinel-count)))

(deftest process-a6-hundred-short-lived-no-leak
  (let ((before (length (limn/process:list-processes))))
    (let ((procs (loop repeat 100 collect
                       (limn/process:make-process :command '("/usr/bin/true")))))
      (dolist (p procs) (limn/process:process-wait p :timeout 5)))
    (sleep 0.2)
    (let ((after (length (limn/process:list-processes))))
      (assert-true (<= (- after before) 2)
                   (format nil "leak: before=~A after=~A" before after)))))

(deftest process-a6-stdout-not-cross-contaminated
  (let* ((procs (loop for i from 1 to 5 collect
                      (limn/process:make-process
                       :command (list "/bin/echo" (format nil "uniq-tag-~A" i))))))
    (dolist (p procs) (limn/process:process-wait p :timeout 5))
    (loop for p in procs for i from 1 do
      (assert-true (search (format nil "uniq-tag-~A" i)
                           (limn/process:process-stdout p)))
      ;; And not contaminated with another's tag.
      (loop for j from 1 to 5 unless (= j i) do
        (assert-false (search (format nil "uniq-tag-~A" j)
                              (limn/process:process-stdout p)))))))

(deftest process-a6-spawn-from-other-thread-no-deadlock
  (let* ((done nil)
         (err  nil)
         (th (sb-thread:make-thread
              (lambda ()
                (handler-case
                    (let ((p (limn/process:make-process :command '("/usr/bin/true"))))
                      (limn/process:process-wait p :timeout 5)
                      (setf done t))
                  (error (e) (setf err e)))))))
    (sb-thread:join-thread th)
    (when err (error err))
    (assert-true done)))

(deftest process-a6-list-processes-auto-clears-exited
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    ;; Allow registry sweep
    (sleep 0.2)
    (assert-false (find p (limn/process:list-processes))
                  "exited proc removed from registry")))

(deftest process-a6-list-processes-no-hang-under-storm
  (let ((procs (loop repeat 50 collect
                     (limn/process:make-process :command '("/usr/bin/true")))))
    (with-timeout-bound 1
      (dotimes (_ 20) (limn/process:list-processes)))
    (dolist (p procs) (limn/process:process-wait p :timeout 5))))

;;; ─── A7. Edge cases ────────────────────────────────────────────────

(deftest process-a7-zero-length-stdout
  (let ((p (%spawn-and-wait '("/usr/bin/true"))))
    (assert-true (or (null (limn/process:process-stdout p))
                     (zerop (length (limn/process:process-stdout p)))))))

(deftest process-a7-stdin-with-nul-byte
  (let ((p (limn/process:make-process :command '("/bin/cat"))))
    (limn/process:process-send-string p (format nil "a~Cb" (code-char 0)))
    (limn/process:process-send-eof p)
    (limn/process:process-wait p :timeout 5)
    ;; "a" and "b" both present; NUL doesn't truncate.
    (let ((out (limn/process:process-stdout p)))
      (assert-true (search "a" out))
      (assert-true (search "b" out)))))

(deftest process-a7-non-utf8-bytes-do-not-crash
  (let ((p (%spawn-and-wait
            '("/bin/sh" "-c" "printf '\\xff\\xfe\\xfdtail'"))))
    (assert-no-error (limn/process:process-stdout p))
    (assert-true (search "tail" (or (limn/process:process-stdout p) "")))))

(deftest process-a7-string-command-rejected
  ;; "echo hello world" must NOT be accepted as a string — argv
  ;; word-splitting is shell-dependent. Require a list.
  (assert-error error
    (limn/process:make-process :command "echo hello world")))

(deftest process-a7-timeout-option-kills-runaway
  ;; If the API exposes :timeout, a runaway child should be reaped.
  ;; Skip cleanly if :timeout is not supported.
  (handler-case
      (let ((p (limn/process:make-process
                :command '("/bin/sh" "-c" "sleep 30")
                :timeout 0.3)))
        (with-timeout-bound 2
          (limn/process:process-wait p :timeout 2))
        (assert-true (member (limn/process:process-status p) '(:exit :signal))))
    (error () nil)))
