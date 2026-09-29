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

if [ "${RECEIPT_SERVICE:-}" = api ]; then
    chown -R "$PUID:$PGID" /data
elif [ "${RECEIPT_SERVICE:-}" = ocr ]; then
    # NVIDIA exposes capability nodes as root-only inside this container. Give the
    # inference user access before dropping privileges; no business data is mounted.
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi -L >/dev/null 2>&1 || true
    fi
    for device in /dev/nvidia-caps/nvidia-cap*; do
        [ -e "$device" ] || continue
        chown "$PUID:$PGID" "$device"
        chmod u+r "$device"
    done
fi

export HOME=/tmp/receipt-home
mkdir -p "$HOME"
chown "$PUID:$PGID" "$HOME"

exec gosu "$PUID:$PGID" "$@"
