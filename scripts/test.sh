#!/bin/bash
set -euo pipefail
# Validate current recipe source even after equal-size, same-second edits.
# These settings are confined to this test process and its children.
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPYCACHEPREFIX=/dev/null
cd "$(dirname "$0")/.."
source scripts/libpq-env.sh
python3 scripts/prepare-telegram.py
python3 scripts/prepare-opus.py
python3 scripts/prepare-opusfile.py
python3 scripts/prepare-mozjpeg.py
python3 scripts/prepare-code-highlight.py
python3 scripts/prepare-rlottie.py
python3 scripts/prepare-vpx.py
python3 scripts/prepare-telegram-voip.py
python3 scripts/test-telegram-voip-preparation.py
python3 scripts/test-telegram-voip-native.py
python3 scripts/test-vpx-preparation.py
python3 scripts/test-vpx-rtcd-preparation.py
python3 scripts/test-rlottie-preparation.py
python3 scripts/test-code-highlight-preparation.py
python3 scripts/test-telegram-code-highlight-adaptation.py
python3 scripts/test-mozjpeg-preparation.py
python3 scripts/test-opusfile-preparation.py
python3 scripts/test-opus-preparation.py
python3 scripts/test-telegram-preparation.py
python3 scripts/test-telegram-remote-peer-preparation.py
python3 scripts/test-telegram-avatar-preparation.py
python3 scripts/test-telegram-group-preparation.py
python3 scripts/test-telegram-secret-preparation.py
python3 scripts/test-telegram-search-adaptation.py
python3 scripts/test-telegram-retention-adaptation.py
python3 scripts/test-telegram-read-adaptation.py
python3 scripts/test-telegram-enqueue-adaptation.py
python3 scripts/test-telegram-selection-adaptation.py
python3 scripts/test-telegram-delete-adaptation.py
python3 scripts/test-telegram-draft-adaptation.py
python3 scripts/test-telegram-topic-adaptation.py
python3 scripts/test-telegram-peer-management-adaptation.py
python3 scripts/test-telegram-proxy-adaptation.py
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
