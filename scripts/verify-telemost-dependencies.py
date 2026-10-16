#!/usr/bin/env python3
"""Offline provenance validation; no research clone is a product dependency."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parent.parent
REVISION = "f0a237c6016088a8e3816dde2e56c06e4a47c5eb"

def verify(root=ROOT):
    lock = json.loads((root / "Dependencies/Telemost.lock.json").read_text())
    if lock["source"] != {
        "url": "https://github.com/Bezooom/yandex-messenger-native",
        "revision": REVISION, "license": "MIT", "role": "research-only",
    }:
        raise ValueError("Unreviewed Telemost source")
    if lock["runtime"] != {"implementation": "native-swift-official-rest", "externalDependencies": []}:
        raise ValueError("Unreviewed Telemost runtime")
    for path in (root / "Sources/MakoshTelemost").rglob("*.swift"):
        text = path.read_text()
        if any(value in text for value in [".references/", "makosh_old", "api.messenger.yandex.net"]):
            raise ValueError("Telemost runtime depends on research or private endpoints")
    return REVISION

if __name__ == "__main__":
    try:
        print("Telemost provenance valid: " + verify() + "; own Swift official REST, no reference runtime.")
    except (ValueError, OSError, KeyError):
        raise SystemExit("Telemost provenance verification failed; inspect the independent manifest.") from None
