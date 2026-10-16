#!/usr/bin/env python3
"""Copy only Telegram API settings from a user-selected dotenv file, without eval."""
import argparse
import os
from pathlib import Path
import re
import shlex
import tempfile


def read_api(path):
    selected = {}
    names = {"HERMES_TELEGRAM_API_ID": "apiID", "HERMES_TELEGRAM_API_HASH": "apiHash"}
    for line in path.read_text().splitlines():
        match = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)", line)
        if not match or match[1] not in names:
            continue
        key = names[match[1]]
        if key in selected:
            raise ValueError("Ambiguous duplicate Telegram API setting")
        parts = shlex.split(match[2], comments=True, posix=True)
        if len(parts) != 1:
            raise ValueError("Invalid Telegram API setting")
        selected[key] = parts[0]
    identifier, digest = selected.get("apiID", ""), selected.get("apiHash", "")
    if not re.fullmatch(r"[0-9]+", identifier) or not 0 < int(identifier) <= 2147483647 or not re.fullmatch(r"[0-9a-fA-F]{32}", digest):
        raise ValueError("Missing or invalid Telegram API settings")
    return selected


def install(configuration, destination):
    if destination.is_symlink() or destination.exists():
        raise ValueError("Destination already exists; preserve and inspect it before another import")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if destination.parent.is_symlink():
        raise ValueError("Destination directory must not be a symlink")
    with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, delete=False) as temporary:
        pending = Path(temporary.name)
        try:
            os.fchmod(temporary.fileno(), 0o600)
            identifier, digest = configuration["apiID"], configuration["apiHash"]
            if (not re.fullmatch(r"[0-9]{1,10}", identifier) or not 0 < int(identifier) <= 2147483647
                    or not re.fullmatch(r"[0-9a-fA-F]{32}", digest)):
                raise ValueError("Invalid Telegram API settings")
            temporary.write(f"MAKOSH_TELEGRAM_API_ID={identifier}\nMAKOSH_TELEGRAM_API_HASH={digest}\n")
            temporary.flush()
            os.fsync(temporary.fileno())
            # Hard-link publication refuses an existing destination atomically.
            os.link(pending, destination)
        finally:
            pending.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-env", type=Path, required=True)
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parent.parent / ".local/telegram-build.env")
    args = parser.parse_args()
    try:
        install(read_api(args.from_env), args.output)
    except (OSError, UnicodeError, ValueError):
        raise SystemExit("Telegram API import failed. Check the selected settings and preserve any existing destination; no values were displayed.") from None
    print("Telegram API build input installed with mode 0600. Rebuild the app; no account session was imported or opened.")


if __name__ == "__main__":
    main()
