#!/usr/bin/env python3
"""Stage a fresh Teams-only synthetic bundle; preserve previous QA runs and never launch the ordinary app."""
import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
import plistlib
import shutil
import struct
import subprocess
import uuid
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def connection_options(connection):
    class Option(ctypes.Structure):
        _fields_ = [(name, ctypes.c_char_p) for name in ("keyword", "envvar", "compiled", "val", "label", "dispchar")] + [("dispsize", ctypes.c_int)]
    candidates = [str(ROOT / ".local/postgres-client/lib/libpq.5.dylib"), "/opt/homebrew/opt/libpq/lib/libpq.5.dylib", "/usr/local/opt/libpq/lib/libpq.5.dylib", ctypes.util.find_library("pq")]
    library = None
    for candidate in candidates:
        if not candidate: continue
        try: library = ctypes.CDLL(candidate); break
        except OSError: continue
    if library is None: raise ValueError("The prepared PostgreSQL client is required")
    library.PQconninfoParse.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]; library.PQconninfoParse.restype = ctypes.POINTER(Option)
    library.PQconninfoFree.argtypes = [ctypes.POINTER(Option)]; library.PQfreemem.argtypes = [ctypes.c_void_p]
    error = ctypes.c_void_p()
    result = library.PQconninfoParse(connection.encode(), ctypes.byref(error))
    try:
        if not result: raise ValueError("Invalid database configuration")
        values = {}; index = 0
        while result[index].keyword:
            if result[index].val is not None: values[result[index].keyword.decode()] = result[index].val.decode()
            index += 1
        return values
    finally:
        if result: library.PQconninfoFree(result)
        if error.value: library.PQfreemem(error)

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
    if not set(options).issubset({"host", "hostaddr", "port", "dbname", "user", "password", "sslmode", "connect_timeout", "application_name"}): raise ValueError("Unsupported QA connection options")
    address = "127.0.0.1" if host == "localhost" else host
    parts = urlsplit(connection)
    if parts.scheme in ("postgres", "postgresql"):
        query = [(key, value) for key, value in parse_qsl(parts.query, keep_blank_values=True) if key != "hostaddr"] + [("hostaddr", address)]
        connection = urlunsplit(parts._replace(query=urlencode(query)))
    else: connection += " hostaddr=" + address
    return {"connectionString": connection, "schema": "qa_teams_" + suffix, "archiveSchema": "qa_teams_archive_" + suffix}

def qa_info(source):
    if source.get("CFBundleIdentifier") != "org.makosh.desktop" or source.get("CFBundleExecutable") != "Makosh":
        raise ValueError("Expected the current Makosh desktop bundle")
    result = dict(source)
    result.update(CFBundleIdentifier="org.makosh.teams.qa", CFBundleName="MakoshTeamsQA", CFBundleDisplayName="Макош · Teams QA",
                  MakoshRequiresSyntheticConfiguration=True, MakoshSyntheticService="teams")
    return result

def text_hash(path):
    data = path.read_bytes()
    if len(data) < 32 or struct.unpack_from("<II", data) != (0xfeedfacf, 0x0100000c):
        raise ValueError("Expected a thin ARM64 Mach-O")
    count = struct.unpack_from("<I", data, 16)[0]
    command = 32
    for _ in range(count):
        kind, size = struct.unpack_from("<II", data, command)
        if size < 8 or command + size > len(data): raise ValueError("Invalid Mach-O commands")
        if kind == 0x19:
            sections = struct.unpack_from("<I", data, command + 64)[0]
            for index in range(sections):
                section = command + 72 + index * 80
                if section + 80 > command + size: raise ValueError("Invalid Mach-O section")
                if data[section:section + 16].rstrip(b"\0") == b"__text" and data[section + 16:section + 32].rstrip(b"\0") == b"__TEXT":
                    length = struct.unpack_from("<Q", data, section + 40)[0]
                    offset = struct.unpack_from("<I", data, section + 48)[0]
                    if offset + length > len(data): raise ValueError("Invalid executable text")
                    return hashlib.sha256(data[offset:offset + length]).hexdigest()
        command += size
    raise ValueError("Executable text not found")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=ROOT / ".build/Makosh.app")
    parser.add_argument("--database-config", type=Path, default=ROOT / ".local/postgres-app.json")
    parser.add_argument("--storage-config", type=Path, default=ROOT / ".local/s3-app.json")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--launch", action="store_true")
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    info = qa_info(plistlib.loads((bundle / "Contents/Info.plist").read_bytes()))
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True, capture_output=True)
    original_hash = text_hash(bundle / "Contents/MacOS/Makosh")
    config = isolated_configuration(json.loads(args.database_config.read_text()), uuid.uuid4().hex[:16])
    storage = args.storage_config.resolve()
    if not storage.is_file(): raise ValueError("Run scripts/dev-db.sh up before file QA")
    endpoint = urlsplit(json.loads(storage.read_text()).get("endpoint", ""))
    if endpoint.scheme not in ("http", "https") or endpoint.hostname not in ("127.0.0.1", "::1", "localhost"): raise ValueError("QA requires local S3")
    output = (args.output or ROOT / ".local/teams-qa" / uuid.uuid4().hex).resolve()
    if not output.is_relative_to((ROOT / ".local").resolve()) or output.exists():
        raise ValueError("QA output must be a fresh directory below .local")
    output.mkdir(parents=True, mode=0o700)
    os.chmod(output, 0o700)
    qa_bundle = output / "MakoshTeamsQA.app"
    shutil.copytree(bundle, qa_bundle, symlinks=True)
    (qa_bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(qa_bundle)], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(qa_bundle)], check=True, capture_output=True)
    if text_hash(qa_bundle / "Contents/MacOS/Makosh") != original_hash: raise ValueError("QA executable differs from the built app")
    database = output / "database.json"
    database.write_text(json.dumps(config) + "\n"); database.chmod(0o600)
    spool = output / "spool"; spool.mkdir(mode=0o700)
    fixtures = output / "fixtures"; fixtures.mkdir(mode=0o700)
    for name in ("Материалы проекта.txt", "Проверка вложений.txt"):
        file = fixtures / name; file.write_text("Синтетические данные Teams QA.\n"); file.chmod(0o600)
    (output / "exports").mkdir(mode=0o700)
    launch = ["/usr/bin/open", "-n", str(qa_bundle), "--args", "--teams-synthetic-preview", "--database-config", str(database), "--storage-config", str(storage), "--teams-qa-spool", str(spool), "--teams-qa-fixtures", str(fixtures)]
    manifest = {"bundle": str(qa_bundle), "executableTextSHA256": original_hash, "schema": config["schema"], "archiveSchema": config["archiveSchema"], "launch": launch}
    (output / "artifact.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output / "artifact.json").chmod(0o600)
    if args.launch: subprocess.run(launch, check=True, capture_output=True)
    print(qa_bundle)

if __name__ == "__main__":
    try: main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit("Teams QA staging failed: " + str(error))
