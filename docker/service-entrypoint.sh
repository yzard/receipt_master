#!/bin/sh
set -eu
umask 077

for value in "${PUID:-}" "${PGID:-}"; do
    case "$value" in
        ''|*[!0-9]*) echo 'PUID and PGID must be positive numeric IDs' >&2; exit 2 ;;
    esac
    if [ "$value" -eq 0 ]; then
        echo 'PUID and PGID must be non-root IDs' >&2
        exit 2
    fi
done

chown -R "$PUID:$PGID" /data

export HOME=/tmp/receipt-home
mkdir -p "$HOME"
chown "$PUID:$PGID" "$HOME"

exec su-exec "$PUID:$PGID" "$@"
