#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-up}" in
    up)
        python3 scripts/configure-dev-db.py
        docker compose --env-file .local/postgres.env up -d --wait --wait-timeout 60
        ;;
    status)
        docker compose --env-file .local/postgres.env ps
        ;;
    down)
        # Deliberately preserve the named volume and local credentials.
        docker compose --env-file .local/postgres.env down
        ;;
    *)
        echo 'Usage: scripts/dev-db.sh [up|status|down]' >&2
        exit 2
        ;;
esac
