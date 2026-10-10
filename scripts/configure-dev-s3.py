#!/usr/bin/env python3
"""Generate independent development S3 identities. Never print credentials."""
import json
import os
from pathlib import Path
import secrets
import stat
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LOCAL = ROOT / ".local"


def private_read(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 16384:
            raise ValueError("Invalid private configuration")
        return json.load(source)


def private_write(path, content):
    if path.is_symlink():
        raise ValueError("Invalid private configuration")
    fd, temporary = tempfile.mkstemp(prefix="s3-config-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as target:
            os.fchmod(target.fileno(), 0o600)
            json.dump(content, target, indent=2)
            target.write("\n")
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure():
    LOCAL.mkdir(exist_ok=True)
    if LOCAL.is_symlink():
        raise ValueError("Invalid local directory")
    settings = LOCAL / "s3-settings.json"
    if not settings.exists() and not settings.is_symlink():
        values = {name: secrets.token_hex(32) for name in ("adminAccessKey", "adminSecretKey", "appAccessKey", "appSecretKey")}
        fd = os.open(settings, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as target:
            json.dump(values, target)
            target.flush()
            os.fsync(target.fileno())
    values = private_read(settings)
    if set(values) != {"adminAccessKey", "adminSecretKey", "appAccessKey", "appSecretKey"} or any(
        not isinstance(v, str) or len(v) != 64 or any(c not in "0123456789abcdef" for c in v) for v in values.values()
    ):
        raise ValueError("Invalid local development S3 settings")
    private_write(LOCAL / "s3-identities.json", {"identities": [
        {"name": "makosh-dev-admin", "credentials": [{"accessKey": values["adminAccessKey"], "secretKey": values["adminSecretKey"]}], "actions": ["Admin", "Read", "Write", "List"]},
        {"name": "makosh-files", "credentials": [{"accessKey": values["appAccessKey"], "secretKey": values["appSecretKey"]}], "actions": ["Read:makosh-files", "Write:makosh-files", "List:makosh-files"]},
    ]})
    private_write(LOCAL / "s3-app.json", {"endpoint": "http://127.0.0.1:55440", "region": "us-east-1", "bucket": "makosh-files", "accessKeyID": values["appAccessKey"], "secretAccessKey": values["appSecretKey"]})


if __name__ == "__main__":
    try:
        configure()
    except (OSError, ValueError, KeyError, TypeError):
        raise SystemExit("S3 development configuration failed; existing credentials were not replaced.") from None
    print("Local S3 development configuration is ready in ignored private files.")
