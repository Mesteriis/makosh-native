#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/libpq-env.sh
python3 scripts/prepare-telegram.py
python3 scripts/prepare-opus.py
python3 scripts/test-opus-preparation.py
python3 scripts/test-telegram-preparation.py
python3 scripts/test-telegram-search-adaptation.py
python3 scripts/test-telegram-retention-adaptation.py
python3 scripts/test-telegram-read-adaptation.py
python3 scripts/test-telegram-enqueue-adaptation.py
python3 scripts/test-telegram-selection-adaptation.py
python3 scripts/test-telegram-delete-adaptation.py
python3 - "$@" <<'PYTHON'
import json
import os
from pathlib import Path
import subprocess
import sys

environment = dict(os.environ)
if not environment.get("MAKOSH_TEST_S3_CONFIG") and Path(".local/s3-app.json").exists():
    environment["MAKOSH_TEST_S3_CONFIG"] = str(Path(".local/s3-app.json").resolve())
if not environment.get("MAKOSH_TEST_DATABASE_URL"):
    config = Path(".local/postgres-app.json")
    if not config.exists():
        raise SystemExit("Run ./scripts/dev-db.sh up before PostgreSQL integration tests.")
    try:
        environment["MAKOSH_TEST_DATABASE_URL"] = json.loads(config.read_text())["connectionString"]
    except (ValueError, KeyError):
        raise SystemExit("Invalid development database configuration.") from None
sys.exit(subprocess.call(["swift", "test", "-j", "4", *sys.argv[1:]], env=environment))
PYTHON
