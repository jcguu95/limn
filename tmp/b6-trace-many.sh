#!/usr/bin/env bash
# Repeatedly run W10 under gdb until we capture the crash; check if
# the crash backtrace is always the same.
set -u

cat > /tmp/limn-gdb-wrap.sh <<'WRAP'
#!/usr/bin/env bash
exec gdb -batch \
  -ex 'set pagination off' \
  -ex 'handle SIGPIPE noprint nostop pass' \
  -ex 'run' \
  -ex 'bt 20' \
  --args /limn/sioyek/limn "$@" 2>&1
WRAP
chmod +x /tmp/limn-gdb-wrap.sh

mkdir -p tmp/b6-traces
captured=0
for i in $(seq 1 20); do
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
    ' 2>&1)
  if echo "$out" | grep -q "stack smash"; then
    captured=$((captured+1))
    bt_summary=$(echo "$out" | grep -E "^#[0-9]+" | head -8 | sed 's/0x[0-9a-f]*//g' | sed 's/ from .*//' | tr -d ' ' | tr '\n' '|')
    echo "[$i] CRASH: $bt_summary" | tee -a tmp/b6-traces/summary.txt
    echo "$out" > tmp/b6-traces/run-$i.txt
  else
    echo "[$i] ok"
  fi
done
echo "=== $captured / 20 crashes ==="
