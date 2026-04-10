#!/bin/bash
# gc2607-settings-helper.sh
# Privileged helper called by gc2607-settings via pkexec.
# Only two allowed operations: write-config and restart-isp.

set -euo pipefail

case "${1:-}" in
    write-config)
        SRC="${2:-}"
        [ -f "$SRC" ] || { echo "No source file"; exit 1; }
        install -m 644 "$SRC" /etc/gc2607/gc2607.conf
        ;;
    restart-isp)
        systemctl restart gc2607-isp.service
        ;;
    *)
        echo "Usage: $0 write-config <tmpfile> | restart-isp"
        exit 1
        ;;
esac
