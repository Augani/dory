#!/bin/sh
set -eu

case "${1:-server}" in
  server)
    exec /app/server.sh
    ;;
  worker)
    exec /app/worker.sh
    ;;
  *)
    exec "$@"
    ;;
esac

