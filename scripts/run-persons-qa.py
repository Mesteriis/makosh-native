#!/usr/bin/env python3
"""Stage a fresh Persons-only synthetic bundle; preserve previous QA runs and never launch the ordinary app."""
import argparse
import importlib.util
import json
import plistlib
import shutil
import subprocess
import uuid
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

ROOT = Path(__file__).resolve().parents[1]
# libpq option parsing and the executable text hash are shared with the Telemost QA launcher.
_spec = importlib.util.spec_from_file_location("telemost_qa", ROOT/"scripts/run-telemost-qa.py")
_telemost = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_telemost)
connection_options, text_hash = _telemost.connection_options, _telemost.text_hash

def isolated_configuration(source, suffix):
    if not suffix or len(suffix) > 32 or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789" for c in suffix):
        raise ValueError("Invalid QA suffix")
    connection = source.get("connectionString")
    if not isinstance(connection, str) or not connection or "\0" in connection:
        raise ValueError("Invalid database configuration")
    options = connection_options(connection)
    host = options.get("host")
    if host not in ("127.0.0.1", "::1", "localhost") or options.get("hostaddr", "127.0.0.1") not in ("127.0.0.1", "::1"):
        raise ValueError("QA requires local PostgreSQL")
    if not set(options).issubset({"host", "hostaddr", "port", "dbname", "user", "password", "sslmode", "connect_timeout", "application_name"}):
        raise ValueError("Unsupported QA connection options")
    address = "127.0.0.1" if host == "localhost" else host
    parts = urlsplit(connection)
    if parts.scheme in ("postgres", "postgresql"):
        query = [(key, value) for key, value in parse_qsl(parts.query, keep_blank_values=True) if key != "hostaddr"] + [("hostaddr", address)]
        connection = urlunsplit(parts._replace(query=urlencode(query)))
    else: connection += " hostaddr=" + address
    schema = "qa_persons_" + suffix
    return {"connectionString": connection, "schema": schema, "archiveSchema": schema}

def qa_info(source):
    if source.get("CFBundleIdentifier") != "org.makosh.desktop" or source.get("CFBundleExecutable") != "Makosh":
        raise ValueError("Expected the current Makosh desktop bundle")
    result = dict(source)
    result.update(CFBundleIdentifier="org.makosh.persons.qa", CFBundleName="MakoshPersonsQA", CFBundleDisplayName="Макош · Персоны QA",
                  MakoshRequiresSyntheticConfiguration=True, MakoshSyntheticService="persons")
    return result

def verify_resources(bundle):
    forbidden = {"database.json", "s3.json", "api.json", "telegram-api.json", "tokens.json", "session.json", "google-oauth.env", "google-oauth.json"}
    if any(path.name in forbidden for path in (bundle/"Contents/Resources").rglob("*")): raise ValueError("Private configuration must not be bundled")

def launch_command(qa_bundle, database):
    return ["/usr/bin/open", "-n", str(qa_bundle), "--args", "--persons-synthetic-preview", "--database-config", str(database)]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=ROOT/".build/Makosh.app")
    parser.add_argument("--database-config", type=Path, default=ROOT/".local/postgres-app.json")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--launch", action="store_true")
    args = parser.parse_args()
    bundle = args.bundle.resolve(); verify_resources(bundle)
    info = qa_info(plistlib.loads((bundle/"Contents/Info.plist").read_bytes()))
    info.pop("CFBundleURLTypes", None)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True, capture_output=True)
    original_hash = text_hash(bundle/"Contents/MacOS/Makosh")
    config = isolated_configuration(json.loads(args.database_config.read_text()), uuid.uuid4().hex[:16])
    output = (args.output or ROOT/".local/persons-qa"/uuid.uuid4().hex).resolve()
    if not output.is_relative_to((ROOT/".local").resolve()) or output.exists(): raise ValueError("QA output must be a fresh directory below .local")
    output.mkdir(parents=True, mode=0o700); output.chmod(0o700)
    qa_bundle = output/"MakoshPersonsQA.app"
    shutil.copytree(bundle, qa_bundle, symlinks=True)
    (qa_bundle/"Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(qa_bundle)], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(qa_bundle)], check=True, capture_output=True)
    if text_hash(qa_bundle/"Contents/MacOS/Makosh") != original_hash: raise ValueError("QA executable differs from the built app")
    database = output/"database.json"; database.write_text(json.dumps(config)+"\n"); database.chmod(0o600)
    launch = launch_command(qa_bundle, database)
    manifest = {"bundle": str(qa_bundle), "executableTextSHA256": original_hash, "schema": config["schema"], "launch": launch}
    (output/"artifact.json").write_text(json.dumps(manifest, indent=2)+"\n"); (output/"artifact.json").chmod(0o600)
    if args.launch: subprocess.run(launch, check=True, capture_output=True)
    print(qa_bundle)

if __name__ == "__main__":
    try: main()
    except (ValueError, OSError, subprocess.CalledProcessError): raise SystemExit("Persons QA staging failed; inspect local configuration and built artifact")
