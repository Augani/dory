#!/bin/bash
# Enforce the competitive strategy's binary launch policy: no partial/strong/degraded status tier.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "usage: scripts/verify-competitor-coverage-matrix.sh [MATRIX.md]"
  exit 0
fi
MATRIX="${1:-$ROOT/COMPETITOR_ISSUE_COVERAGE.md}"
[ -f "$MATRIX" ] || { echo "competitor matrix verification: missing $MATRIX" >&2; exit 66; }

python3 - "$MATRIX" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
rows = []
for line_number, line in enumerate(text.splitlines(), 1):
    if not line.startswith("| ") or "Competitor failure class" in line or line.startswith("|---"):
        continue
    cells = [cell.strip() for cell in line.strip("|").split("|")]
    if len(cells) != 3:
        raise SystemExit(f"{path}:{line_number}: expected three matrix columns, found {len(cells)}")
    coverage = cells[1]
    if coverage.startswith("**FULL"):
        status = "FULL"
    elif coverage.startswith("**LAUNCH BLOCKER"):
        status = "LAUNCH BLOCKER"
    else:
        raise SystemExit(
            f"{path}:{line_number}: coverage must begin with **FULL or **LAUNCH BLOCKER: {coverage[:80]}"
        )
    if not cells[0] or not cells[2]:
        raise SystemExit(f"{path}:{line_number}: issue class and closure action are required")
    rows.append((line_number, status))

if not rows:
    raise SystemExit(f"{path}: no competitor coverage rows found")
if not any(status == "FULL" for _, status in rows):
    raise SystemExit(f"{path}: matrix has no FULL rows")
if not any(status == "LAUNCH BLOCKER" for _, status in rows):
    raise SystemExit(f"{path}: matrix must fail closed while release blockers remain")

for forbidden in (
    "**Strong current-runtime proof**",
    "**Partial",
):
    if forbidden in text:
        raise SystemExit(f"{path}: forbidden intermediate status wording remains: {forbidden}")

if not re.search(r"Public release remains\s+\*\*NO-GO\*\*", text):
    raise SystemExit(f"{path}: open blockers do not produce an explicit NO-GO decision")

full = sum(status == "FULL" for _, status in rows)
blocked = sum(status == "LAUNCH BLOCKER" for _, status in rows)
print(f"competitor matrix verification: PASS ({full} FULL, {blocked} LAUNCH BLOCKER, 0 partial)")
PY
