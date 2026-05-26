#!/usr/bin/env bash
# v0.38 verification pass — re-run all 30 dogfood drivers post-fixes.
# Each driver runs in a fresh docker container with backend/ mounted
# (so our Lisp fixes apply without rebuilding docker image).
set -u

cd "$(dirname "$0")/.."

OUT=tmp/rerun-summary.txt
echo "v0.38 rerun verification — $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT"
echo "git: $(git rev-parse --short=12 HEAD)" >> "$OUT"
echo "" >> "$OUT"

for drv in tmp/w*-driver.lisp; do
  name=$(basename "$drv" -driver.lisp)
  nn=${name#w}
  # Clean receipts dir
  rm -rf "tmp/receipts/${nn}"
  mkdir -p "tmp/receipts/${nn}"
  # Run
  printf "%-4s ... " "W${nn}" | tee -a "$OUT"
  out=$(docker run --rm \
    -v "$(pwd)/tmp:/host-tmp" \
    -v "$(pwd)/backend:/limn/backend" \
    --entrypoint "" \
    limn-e2e:latest \
    bash -c "rm -f /tmp/.limn/init.lisp; rm -rf /root/.limn; nix develop /limn#docker --command /usr/local/bin/container-entry.sh sbcl --no-userinit --no-sysinit --non-interactive --load /host-tmp/${name}-driver.lisp" 2>&1)
  # Extract the result line (e.g. "── W27 result: 4 / 4 pass ──")
  result=$(echo "$out" | grep -E "── W.* result:" | tail -1)
  # Save full output for inspection
  echo "$out" | tail -50 > "tmp/receipts/${nn}/rerun.log"
  echo "$result" | tee -a "$OUT"
done

echo ""             >> "$OUT"
echo "=== TALLY ==" >> "$OUT"
grep -E "result:" "$OUT" | awk '{
  if (match($0, /([0-9]+) \/ ([0-9]+) pass/, a)) {
    if (a[1] == a[2]) p++; else if (a[1] > 0) part++; else f++;
  }
}
END {
  print "PASS:      " (p+0);
  print "PARTIAL:   " (part+0);
  print "FAIL:      " (f+0);
}' >> "$OUT"
echo "" >> "$OUT"
cat "$OUT" | tail -20
