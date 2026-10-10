#!/usr/bin/env python3
"""Verified upstream binary for ephemeral hosted-macOS S3 tests (local dev uses Docker)."""
import hashlib
import json
import os
from pathlib import Path
import platform
import tarfile
import urllib.request

root = Path(__file__).resolve().parent.parent
lock = json.loads((root / "Dependencies/ObjectStorage.lock.json").read_text())
if platform.system() != "Darwin" or platform.machine() not in lock["ciArchives"]:
    raise SystemExit("This S3 test helper requires a supported macOS architecture.")
archive = lock["ciArchives"][platform.machine()]
local = root / ".local/ci-seaweedfs"
local.mkdir(parents=True, exist_ok=True)
target = local / archive["name"]
url = lock["project"] + "/releases/download/" + lock["version"] + "/" + archive["name"]
if not target.exists():
    with urllib.request.urlopen(url, timeout=60) as source, target.open("xb") as output:
        while chunk := source.read(1024 * 1024):
            output.write(chunk)
with target.open("rb") as source:
    digest = hashlib.file_digest(source, "sha256").hexdigest()
if digest != archive["sha256"]:
    raise SystemExit("SeaweedFS archive checksum mismatch; no binary extracted.")
with tarfile.open(target, "r:gz") as source:
    matches = [member for member in source.getmembers() if member.name in ("weed", "./weed")]
    if len(matches) != 1 or not matches[0].isfile() or not 0 < matches[0].size < 1024 * 1024 * 1024:
        raise SystemExit("Unexpected SeaweedFS archive contents.")
    executable = local / "weed"
    if executable.is_symlink():
        raise SystemExit("Unsafe SeaweedFS binary destination.")
    with source.extractfile(matches[0]) as input_file, executable.open("wb") as output:
        while chunk := input_file.read(1024 * 1024):
            output.write(chunk)
    os.chmod(executable, 0o700)
print("Verified pinned SeaweedFS CI binary prepared.")
