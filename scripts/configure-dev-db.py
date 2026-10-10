#!/usr/bin/env python3
"""Generate only this project's local development credentials; never print them."""
import json
import os
from pathlib import Path
import secrets

root = Path(__file__).resolve().parent.parent
local = root / ".local"
local.mkdir(exist_ok=True)
settings = local / "postgres-settings.json"
if not settings.exists():
    descriptor = os.open(settings, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as target:
        json.dump({"password": secrets.token_hex(32)}, target)
password = json.loads(settings.read_text())["password"]
if not isinstance(password, str) or len(password) != 64 or any(c not in "0123456789abcdef" for c in password):
    raise SystemExit("Invalid local development settings; files were left unchanged.")

def save_private(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w") as target:
        target.write(content)

save_private(local / "postgres.env", f"MAKOSH_POSTGRES_PASSWORD={password}\n")
save_private(local / "postgres-app.json", json.dumps({
    "connectionString": f"host=127.0.0.1 port=55439 dbname=makosh user=makosh password={password} connect_timeout=5",
    "schema": "makosh",
}, indent=2) + "\n")
print("Local PostgreSQL development configuration is ready in ignored .local/ files.")
