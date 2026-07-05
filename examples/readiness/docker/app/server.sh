#!/bin/sh
set -eu

message="${DORY_MESSAGE:-dory-readiness-ok}"
mkdir -p /www
cat > /www/index.html <<EOF
${message}
EOF
cat > /www/health <<EOF
ok
EOF
exec /usr/sbin/httpd -f -p 8080 -h /www
