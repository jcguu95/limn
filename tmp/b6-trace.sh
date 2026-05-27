#!/usr/bin/env bash
# Run W10 driver up to ~30 times, with limn launched under gdb so we
# capture the abort stack on the next crash.
set -u

# Write a wrapper that gdb-traces limn. We mount this at /tmp/limn-gdb-wrap
# inside docker and point the driver at it via LIMN_BIN env.
cat > /tmp/limn-gdb-wrap.sh <<'WRAP'
#!/usr/bin/env bash
exec gdb -batch \
  -ex 'set pagination off' \
  -ex 'set print thread-events off' \
  -ex 'handle SIGPIPE noprint nostop pass' \
  -ex 'run' \
  -ex 'bt full' \
  -ex 'thread apply all bt' \
  --args /limn/sioyek/limn "$@" 2>&1
WRAP
chmod +x /tmp/limn-gdb-wrap.sh

for i in $(seq 1 15); do
  echo "=== run $i ==="
  out=$(docker run --rm \
    -v "$(pwd)/tmp:/host-tmp" \
    -v "$(pwd)/backend:/limn/backend" \
    -v "/tmp/limn-gdb-wrap.sh:/limn/sioyek/limn-gdb-wrap.sh" \
    --entrypoint "" limn-e2e:latest bash -c '
      rm -f /tmp/.limn/init.lisp; rm -rf /root/.limn;
      export LIMN_BIN=/limn/sioyek/limn-gdb-wrap.sh
      nix develop /limn#docker --command /usr/local/bin/container-entry.sh \
        sbcl --no-userinit --no-sysinit --non-interactive \
             --load /host-tmp/w10-driver.lisp 2>&1
      echo "--- LIMN-LOG ---"
      cat /tmp/limn-w10*.log 2>/dev/null
    ' 2>&1)
  if echo "$out" | grep -q "stack smash\|SIGABRT\|received signal"; then
    echo "[$i] CRASH CAPTURED"
    echo "$out" | sed -n '/LIMN-LOG/,$p' > tmp/b6-crash-trace.txt
    echo "$out" | grep -E "result:" | tail -1
    break
  else
    echo "[$i] $(echo "$out" | grep -E "result:" | tail -1)"
  fi
done
