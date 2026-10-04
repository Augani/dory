#!/bin/bash
# CI uses the same current security policy as the public test entrypoint.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec bash "$ROOT/scripts/test-security-contracts.sh"
