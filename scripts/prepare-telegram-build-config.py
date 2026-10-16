#!/usr/bin/env python3
"""Generate ignored, private Swift build constants; never read credentials at runtime."""
import argparse
import os
from pathlib import Path
import re
import stat
import tempfile

ROOT = Path(__file__).resolve().parent.parent
KEYS = ("MAKOSH_TELEGRAM_API_ID", "MAKOSH_TELEGRAM_API_HASH")
LIMIT = 8192


def validate_pair(identifier, digest):
    if (not re.fullmatch(r"[0-9]{1,10}", identifier) or not 0 < int(identifier) <= 2147483647
            or not re.fullmatch(r"[0-9a-fA-F]{32}", digest)):
        raise ValueError("Invalid API pair")
    return int(identifier), digest


def read_private_input(path):
    # Nonblocking open also refuses FIFO/device input before reading any bytes.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_size > LIMIT):
            raise ValueError("Unsafe API build input")
        data = os.read(descriptor, LIMIT + 1)
        if len(data) > LIMIT:
            raise ValueError("Oversized API build input")
    finally:
        os.close(descriptor)
    selected = {}
    for line in data.decode("ascii").splitlines():
        if not line.strip(): continue
        name, separator, value = line.partition("=")
        if not separator or name not in KEYS or name in selected:
            raise ValueError("Invalid API build input")
        selected[name] = value
    if set(selected) != set(KEYS):
        raise ValueError("Incomplete API build input")
    return validate_pair(*(selected[key] for key in KEYS))


def select_pair(path, allow_unconfigured):
    # Empty CI secret variables count as absent only when BOTH are empty.
    values = tuple(os.environ.get(key, "") for key in KEYS)
    if any(values): return validate_pair(*values)
    try:
        return read_private_input(path)
    except FileNotFoundError:
        if allow_unconfigured: return None
        raise ValueError("Missing API build input") from None


def private_output_directory(output):
    output = output.absolute()
    # Refuse symlink ancestors instead of publishing private source through them.
    directory = Path(output.anchor)
    for component in output.parent.parts[1:]:
        directory /= component
        try: info = directory.lstat()
        except FileNotFoundError:
            directory.mkdir(mode=0o700)
            info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode): raise ValueError("Unsafe generated directory")
    if output.parent.stat().st_uid != os.getuid(): raise ValueError("Foreign generated directory")
    output.parent.chmod(0o700)
    if output.is_symlink(): raise ValueError("Unsafe generated source")
    if output.exists():
        info = output.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("Unsafe generated source")
    return output


def publish(output, contents):
    payload = contents.encode("ascii")
    if output.exists() and output.read_bytes() == payload:
        output.chmod(0o600)
        return
    descriptor, name = tempfile.mkstemp(dir=output.parent, prefix=".telegram-build-")
    pending = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        os.replace(pending, output)
    finally:
        pending.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / ".local/telegram-build.env")
    parser.add_argument("--output", type=Path,
                        default=ROOT / ".local/build-configuration/TelegramBuildConfiguration.swift")
    parser.add_argument("--allow-unconfigured", action="store_true",
                        help="Explicit source/CI test build without Telegram account connectivity")
    args = parser.parse_args()
    output = None
    try:
        output = private_output_directory(args.output)
        pair = select_pair(args.input, args.allow_unconfigured)
        identifier, digest = (str(pair[0]), '"' + pair[1] + '"') if pair else ("nil", "nil")
        publish(output, "// Generated private build configuration. Do not commit.\n"
                "public enum MakoshBuildConfiguration {\n"
                f"    public static let telegramAPIID: Int32? = {identifier}\n"
                f"    public static let telegramAPIHash: String? = {digest}\n"
                "}\n")
    except (OSError, UnicodeError, ValueError):
        # A rejected new input must not silently compile an earlier API pair.
        if output is not None:
            publish(output, '#error("Telegram build configuration rejected; rerun preparation")\n')
        raise SystemExit("Telegram build configuration failed. Supply a valid private build input or CI pair; no values were displayed.") from None
    print("Telegram build configuration prepared" + (" (explicit unconfigured mode)." if pair is None else "."))


if __name__ == "__main__": main()
