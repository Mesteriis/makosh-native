#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
if [[ "$#" -eq 0 ]]; then
    if [[ ! -f .local/postgres-app.json ]]; then
        echo 'Run ./scripts/dev-db.sh up first, or supply --database-config /path/to/config.json.' >&2
        exit 1
    fi
    set -- --database-config "$PWD/.local/postgres-app.json" --storage-config "$PWD/.local/s3-app.json"
fi
open -n .build/Makosh.app --args "$@"
