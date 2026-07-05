#!/bin/sh
set -eu

api_url="${API_URL:-http://api:8080}"
mkdir -p /data
wget -qO /data/api-response.txt "$api_url"
echo "worker-ok" | tee /data/worker.txt
exec tail -f /dev/null
