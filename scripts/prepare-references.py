#!/usr/bin/env python3
"""Clone exactly pinned public references, without running their code or scripts."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
lock = json.loads((root / "references.lock.json").read_text())
for item in lock["references"]:
    path = (root / item["path"]).resolve()
    if not path.is_relative_to((root / ".references").resolve()):
        raise ValueError("Reference path must stay in .references")
    if path.exists():
        actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path).decode().strip()
        if actual != item["sha"]:
            raise ValueError("Existing checkout differs; preserve it and resolve explicitly: " + item["name"])
    else:
        path.parent.mkdir(exist_ok=True)
        subprocess.run(["git", "init", str(path)], check=True)
        subprocess.run(["git", "remote", "add", "origin", item["url"]], cwd=path, check=True)
        subprocess.run(["git", "fetch", "--depth", "1", "origin", item["sha"]], cwd=path, check=True)
        subprocess.run(["git", "checkout", "--detach", "FETCH_HEAD"], cwd=path, check=True)
    # Machine-local index selection; never alter tracked upstream source or an existing control.
    ignore = path / ".xerjignore"
    if not ignore.exists():
        ignore.write_text("\n".join(item["xerj"]["exclusions"]) + "\n")
    exclude = path / ".git" / "info" / "exclude"
    existing = exclude.read_text() if exclude.exists() else ""
    if ".xerjignore" not in existing.splitlines():
        exclude.parent.mkdir(exist_ok=True)
        exclude.write_text(existing + "\n.xerjignore\n")
    print(item["name"] + " " + item["sha"])
