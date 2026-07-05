#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../out
for GOARCH in arm64 amd64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" go build -trimpath -ldflags="-s -w" \
    -o "../out/dory-agent-$GOARCH" .
done
ln -sf dory-agent-arm64 ../out/dory-agent
