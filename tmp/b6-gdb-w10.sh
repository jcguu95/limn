#!/usr/bin/env bash
# Run W10 under gdb, capture stack trace on __stack_chk_fail.
# Strategy: gdb wraps the binary; when SIGABRT fires we already have a
# valid frame stack. The W10 driver calls (limn:start) which connects;
# the C++ binary is the one we're tracing.
set -u

# gdb script: catch abort, dump backtrace, dump local vars per frame.
cat > /tmp/gdb-cmds <<'EOF'
set pagination off
set print thread-events off
catch signal SIGABRT
run --test-mode --socket /tmp/limn-b6
bt full
info threads
thread apply all bt
quit
EOF

# Start gdb on limn binary in background.
# The W10 driver in turn connects via /tmp/limn-b6.
gdb -batch -x /tmp/gdb-cmds /limn/sioyek/limn 2>&1 &
GDB_PID=$!

# Give limn time to open the socket.
for i in $(seq 1 100); do
  [ -S /tmp/limn-b6 ] && break
  sleep 0.05
done
echo "[gdb-driver] socket up: $(ls -la /tmp/limn-b6 2>/dev/null || echo NO)"

# Run the W10 driver against this limn instance. We override LIMN_BIN
# so the driver does NOT spawn its own — it'll just connect.
# Trick: replace limn-bin in the driver to a no-op via env. Easier:
# write a tiny driver that uses LIMN_SOCKET only.
cat > /tmp/w10-attach.lisp <<'LISP'
(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defun xdotool (&rest args)
  (zerop (sb-ext:process-exit-code
           (sb-ext:run-program "xdotool" args :search t :wait t
                                :output nil :error nil))))
(defun wait-for-window (n)
  (let ((d (+ (get-universal-time) 5)))
    (loop (when (zerop (sb-ext:process-exit-code
                         (sb-ext:run-program "xdotool"
                           (list "search" "--name" n)
                           :search t :wait t :output nil)))
            (return t))
          (when (> (get-universal-time) d) (return nil))
          (sleep 0.1))))

(limn:start "/tmp/limn-b6")
(wait-for-window "Limn")
(sleep 0.5)
(xdotool "search" "--name" "Limn" "windowactivate")
(sleep 0.3)

;; Replay the W10 sequence: load paper-A, set bookmark, jump
;; Use whatever PDF is available.
(handler-case
    (progn
      (limn:call "bridge/engine-load" :|engine| "mupdf"
                  :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1")
      (sleep 0.4)
      ;; Set bookmark 'm at page 3
      (limn:call "bookmark/set" :|buffer-id|
                  (getf (limn/bridge:response-data
                          (limn:call "view/get" :|win-id| "w1"))
                        :|buffer-id|)
                  :|key| "m" :|page| 3 :|offset-x| 0.0 :|offset-y| 0.0)
      (sleep 0.3)
      ;; Set bookmark 'b at page 5
      (limn:call "bookmark/set" :|buffer-id|
                  (getf (limn/bridge:response-data
                          (limn:call "view/get" :|win-id| "w1"))
                        :|buffer-id|)
                  :|key| "b" :|page| 5 :|offset-x| 0.0 :|offset-y| 0.0)
      (sleep 0.5))
  (error (e) (format t "driver error: ~a~%" e)))

(sb-ext:exit :code 0)
LISP

# Run driver under nix shell.
nix develop /limn#docker --command \
  sbcl --no-userinit --no-sysinit --non-interactive \
       --load /tmp/w10-attach.lisp 2>&1 | tail -10

# Wait for gdb to finish (limn either exited cleanly or crashed)
wait $GDB_PID 2>/dev/null || true
echo "[gdb-driver] done"
