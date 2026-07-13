#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-endurance-analysis.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import csv
import os
import sys

root = sys.argv[1]
fields = ["phase", "cycle", "epoch", "pid_count", "fd_total", "rss_kb", "cpu_percent", "state_kb",
          "fseventsd_pid_count", "fseventsd_rss_kb", "fseventsd_cpu_percent"]

def write(name, rows):
    with open(os.path.join(root, name), "w", encoding="utf-8", newline="") as handle:
        output = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
        output.writeheader()
        output.writerows(rows)

def row(cycle, *, phase="cleaned", pids=3, fds=60, rss=500_000, cpu=1.0, state=3_000_000,
        fseventsd_rss=50_000, fseventsd_cpu=0.2):
    return {
        "phase": phase, "cycle": cycle, "epoch": 1_700_000_000 + cycle,
        "pid_count": pids, "fd_total": fds, "rss_kb": rss,
        "cpu_percent": cpu, "state_kb": state,
        "fseventsd_pid_count": 1, "fseventsd_rss_kb": fseventsd_rss,
        "fseventsd_cpu_percent": fseventsd_cpu,
    }

stable = [row(0, phase="baseline", rss=900_000)]
stable += [row(index, rss=500_000 + index * 20, state=3_000_000 + index * 10) for index in range(1, 801)]
stable[-1]["rss_kb"] = 2_000_000  # A single allocator/outlier sample must not define the plateau.
write("stable.tsv", stable)

rss_leak = [row(index, rss=400_000 if index <= 400 else 900_000) for index in range(1, 801)]
write("rss-leak.tsv", rss_leak)

fd_leak = [row(index, fds=50 if index <= 400 else 80) for index in range(1, 801)]
write("fd-leak.tsv", fd_leak)

process_leak = [row(index, pids=3 if index <= 400 else 4) for index in range(1, 801)]
write("process-leak.tsv", process_leak)

fseventsd_rss_leak = [row(index, fseventsd_rss=50_000 if index <= 400 else 300_000) for index in range(1, 801)]
write("fseventsd-rss-leak.tsv", fseventsd_rss_leak)

fseventsd_cpu = [row(index, fseventsd_cpu=50) for index in range(1, 801)]
write("fseventsd-cpu.tsv", fseventsd_cpu)

write("too-short.tsv", [row(0, phase="baseline"), row(1)])
PY

analyze() {
  python3 scripts/analyze-endurance-resources.py "$1" \
    --fd-growth 8 --rss-growth-mb 100 --disk-growth-mb 64 --idle-cpu 25 \
    --fseventsd-rss-growth-mb 128 --fseventsd-cpu 25
}

analyze "$TMP/stable.tsv" > "$TMP/stable.out"
grep -q 'resource plateau PASS: window=200' "$TMP/stable.out"

for fixture in rss-leak fd-leak process-leak fseventsd-rss-leak fseventsd-cpu too-short; do
  if analyze "$TMP/$fixture.tsv" > "$TMP/$fixture.out" 2>&1; then
    echo "endurance analysis test: $fixture unexpectedly passed" >&2
    exit 1
  fi
done
grep -q 'median RSS growth' "$TMP/rss-leak.out"
grep -q 'median FD growth' "$TMP/fd-leak.out"
grep -q 'median Dory process count grew' "$TMP/process-leak.out"
grep -q 'median fseventsd RSS growth' "$TMP/fseventsd-rss-leak.out"
grep -q 'median cleaned fseventsd CPU' "$TMP/fseventsd-cpu.out"
grep -q 'at least two cleaned/final' "$TMP/too-short.out"

echo "endurance resource analysis tests: PASS"
