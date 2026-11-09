#!/usr/bin/env python3
"""The flowsint pin compiled into MakoshOSINT must equal Dependencies/Flowsint.lock.json."""
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
lock_path = ROOT / "Dependencies/Flowsint.lock.json"
swift_path = ROOT / "Sources/MakoshOSINT/FlowsintPin.swift"
if not lock_path.exists() or not swift_path.exists():
    sys.exit("flowsint pin: lock or Swift constant is missing")
lock = json.loads(lock_path.read_text())
swift = swift_path.read_text()
problems = []
for key in ("repository", "tag", "sha"):
    if not re.search(rf'{key}:\s*"{re.escape(lock[key])}"', swift):
        problems.append(f"{key} differs: lock has {lock[key]!r}")
for image in lock["baseImages"]:
    if f'"{image}"' not in swift:
        problems.append(f"base image {image!r} missing from Swift")
if not re.fullmatch(r"[0-9a-f]{40}", lock["sha"]):
    problems.append("sha is not a 40-hex commit")
if problems:
    sys.exit("flowsint pin: " + "; ".join(problems))
print(f"flowsint pin ok: {lock['tag']} {lock['sha'][:10]}")
