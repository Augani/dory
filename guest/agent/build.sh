#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../out
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o ../out/dory-agent .
