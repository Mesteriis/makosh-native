#!/usr/bin/env python3
"""Reproducible local XERJ refresh and content freshness checks. No remote rerank."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LOCAL = ROOT / ".local"


def git(*args, cwd=ROOT):
    return subprocess.check_output(["git", *args], cwd=cwd)


def scope(name):
    if name == "project":
        return ROOT, "mk-own-v24", "project-v24"
    if name == "telegram-engine":
        spec = importlib.util.spec_from_file_location("telegram_preparation", ROOT / "scripts/prepare-telegram.py")
        preparation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(preparation)
        if not preparation.verify_prepared():
            raise ValueError("Telegram engine is not prepared")
        return preparation.DEST / "submodules/TelegramCore", "mk-telegram-engine", "telegram-engine"
    lock = json.loads((ROOT / "references.lock.json").read_text())
    item = next((x for x in lock["references"] if x["name"] == name), None)
    if not item:
        raise ValueError("Unknown reference: " + name)
    path = (ROOT / item["path"]).resolve()
    if not path.is_relative_to((ROOT / ".references").resolve()):
        raise ValueError("Reference path must stay inside .references")
    actual = git("rev-parse", "HEAD", cwd=path).decode().strip()
    if actual != item["sha"]:
        raise ValueError("Reference SHA differs from lock: " + name)
    return path, item["xerj"]["prefix"], item["xerj"]["stateName"]


def fingerprint(path):
    if path == ROOT / ".local/telegram-engine/submodules/TelegramCore":
        names = [str(p.relative_to(path)) for p in path.rglob("*") if p.is_file()]
    else:
        names = git("ls-files", "--cached", "--others", "--exclude-standard", "-z", cwd=path).decode().split("\0")
    # Status is an evidence ledger updated AFTER indexing; deliberately excluded by .xerjignore.
    names = sorted(set(n for n in names if n and n != "docs/development-status.md"))
    digest = hashlib.sha256()
    for name in names:
        file = path / name
        if file.is_symlink():
            content = ("symlink:" + str(file.readlink())).encode()
        elif file.is_file():
            content = file.read_bytes()
        else:
            continue
        digest.update(name.encode() + b"\0" + hashlib.sha256(content).digest())
    # Scope-local rules may be excluded from Git but still affect XERJ selection.
    controls = {path / ".gitignore": "scope:.gitignore", path / ".xerjignore": "scope:.xerjignore",
                ROOT / ".gitignore": "root:.gitignore", ROOT / ".xerjignore": "root:.xerjignore"}
    for control, label in controls.items():
        if control.exists():
            digest.update(label.encode() + control.read_bytes())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name", help="project, telegram-engine, or reference name from references.lock.json")
    parser.add_argument("--url", default="http://127.0.0.1:19320")
    parser.add_argument("--check", action="store_true", help="read-only fingerprint check; exit 1 if stale/missing")
    parser.add_argument("--record-existing", nargs=2, metavar=("RESULT", "LOG"), help="record a completed run after checking its root and terminal line")
    args = parser.parse_args()
    path, prefix, state_name = scope(args.name)
    report_path = LOCAL / "freshness" / (args.name + ".json")
    before = fingerprint(path)
    if args.check:
        if not report_path.exists():
            print(args.name + ": missing freshness record"); return 1
        report = json.loads(report_path.read_text())
        fresh = report["fingerprint"] == before and report["prefix"] == prefix
        print(args.name + (": fresh" if fresh else ": STALE"))
        return 0 if fresh else 1
    LOCAL.mkdir(exist_ok=True)
    if args.record_existing:
        result_path, log_path = [ROOT / p for p in args.record_existing]
        result = json.loads(result_path.read_text())
        terminals = [line for line in log_path.read_text().splitlines() if line.startswith("xerj-done ")]
        if Path(result["root"]).resolve() != path or result["prefix"] != prefix or not terminals:
            raise ValueError("Existing result does not identify the selected scope/completed run")
        terminal = terminals[-1]
        if "ok=true" not in terminal or not any("exit=" + str(n) + " " in terminal for n in [0, 3]):
            raise ValueError("Existing run did not complete")
        exit_code = int(terminal.split("exit=")[1].split()[0])
        command = "record-existing; see original logs"
    else:
        result_path = LOCAL / (args.name + "-refresh.json")
        log_path = LOCAL / (args.name + "-refresh.log")
        command = ["xerj", "autoindex", str(path), "--url", args.url, "--prefix", prefix,
                   "--state-dir", str(LOCAL / "xerj-state" / state_name), "--no-graph", "--no-semantic",
                   "--workers", "2", "--yes", "--json"]
        with result_path.open("w") as out, log_path.open("w") as err:
            completed = subprocess.run(command, stdout=out, stderr=err)
        exit_code = completed.returncode
        if exit_code not in (0, 3):
            print(f"XERJ failed: exit {exit_code}; see {log_path.relative_to(ROOT)}"); return exit_code
        result = json.loads(result_path.read_text())
        terminal = next((line for line in reversed(log_path.read_text().splitlines()) if line.startswith("xerj-done ")), "missing")
    after = fingerprint(path)
    if after != before:
        print("Source changed while indexing; freshness not recorded"); return 1
    report_path.parent.mkdir(exist_ok=True)
    report = {"name": args.name, "fingerprint": after, "prefix": prefix, "command": command,
              "source_sha": (json.loads((ROOT / "Dependencies/TelegramEngine.lock.json").read_text())["revision"] if args.name == "telegram-engine" else
                  git("rev-parse", "HEAD", cwd=path).decode().strip() if args.name != "project" else "see content fingerprint"),
              "exit_code": exit_code, "result": result, "terminal": terminal,
              "result_path": str(result_path.relative_to(ROOT)), "log_path": str(log_path.relative_to(ROOT)),
              "recording_limit": "Existing-run recording validates scope and current fingerprint; it cannot reconstruct source changes during a past run."}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{args.name}: recorded exit {exit_code}, files {result['files_indexed']}, code {result['code_files_indexed']}/{result['code_files']}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError, RuntimeError) as error:
        print("XERJ workflow error: " + str(error), file=sys.stderr)
        sys.exit(1)
