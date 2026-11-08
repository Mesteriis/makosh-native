#!/usr/bin/env python3
"""Generate ignored Swift constants for Makosh's Google OAuth desktop client; values are never printed."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import stat

ROOT = Path(__file__).resolve().parent.parent
# Atomic private publication and symlink refusal are shared with the Telegram build input.
_spec = importlib.util.spec_from_file_location("telegram_build", Path(__file__).with_name("prepare-telegram-build-config.py"))
_telegram = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_telegram)
private_output_directory, publish = _telegram.private_output_directory, _telegram.publish

PATH_KEY = "MAKOSH_GOOGLE_OAUTH_CLIENT_CONFIG_PATH"
ENV_KEYS = ("MAKOSH_GOOGLE_OAUTH_CLIENT_ID", "MAKOSH_GOOGLE_OAUTH_CLIENT_SECRET")
LIMIT = 128 * 1024
CLIENT_ID = re.compile(r"[A-Za-z0-9._-]{1,4096}")
SECRET = re.compile(r"[A-Za-z0-9._-]{1,4096}")


def private_bytes(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > LIMIT:
            raise ValueError("Unsafe Google OAuth input")
        data = os.read(descriptor, LIMIT + 1)
    finally:
        os.close(descriptor)
    if len(data) > LIMIT: raise ValueError("Oversized Google OAuth input")
    return data


def validate(client_id, secret):
    if not CLIENT_ID.fullmatch(client_id or "") or not SECRET.fullmatch(secret or ""):
        raise ValueError("Invalid Google OAuth client")
    return client_id, secret


def loopback(uri):
    return isinstance(uri, str) and re.fullmatch(r"http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/?", uri) is not None


def read_client(env_path):
    try:
        lines = private_bytes(env_path).decode("utf-8").splitlines()
    except FileNotFoundError:
        return None
    paths = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"): continue
        name, separator, value = line.removeprefix("export ").partition("=")
        if not separator or name.strip() != PATH_KEY: raise ValueError("Invalid Google OAuth input")
        paths.append(value.strip().strip("'\""))
    if len(paths) != 1 or not os.path.isabs(paths[0]): raise ValueError("Invalid Google OAuth input")
    document = json.loads(private_bytes(paths[0]).decode("utf-8"))
    installed = document.get("installed") if isinstance(document, dict) else None
    if not isinstance(installed, dict): raise ValueError("Only an installed (desktop) client is accepted")
    redirects = installed.get("redirect_uris")
    if not isinstance(redirects, list) or not redirects or not all(loopback(uri) for uri in redirects):
        raise ValueError("Only loopback redirects are accepted")
    return validate(installed.get("client_id"), installed.get("client_secret"))


def select_client(env_path):
    values = tuple(os.environ.get(key, "") for key in ENV_KEYS)
    if any(values): return validate(*values)
    return read_client(env_path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / ".local/google-oauth.env")
    parser.add_argument("--output", type=Path, default=ROOT / ".local/build-configuration/GoogleOAuthConfiguration.swift")
    args = parser.parse_args()
    output = None
    try:
        output = private_output_directory(args.output)
        client = select_client(args.input)
        identifier, secret = ('"' + client[0] + '"', '"' + client[1] + '"') if client else ("nil", "nil")
        publish(output, "// Generated private build configuration. Do not commit.\n"
                "public enum MakoshGoogleOAuthConfiguration {\n"
                f"    public static let clientID: String? = {identifier}\n"
                f"    public static let clientSecret: String? = {secret}\n"
                "}\n")
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        # A rejected new input must not silently compile an earlier client.
        if output is not None:
            publish(output, '#error("Google OAuth build configuration rejected; rerun preparation")\n')
        raise SystemExit("Google OAuth build configuration failed. Supply a valid desktop client; no values were displayed.") from None
    print("Google OAuth: " + ("configured." if client else "not configured; Google sign-in is disabled in this build."))


if __name__ == "__main__":
    main()
