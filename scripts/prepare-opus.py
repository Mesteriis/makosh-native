#!/usr/bin/env python3
"""Prepare portable Opus C sources from a locked Git blob, without installers."""
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tempfile

RECIPE = Path(__file__).resolve()
GROUPS = ("OPUS_SOURCES", "OPUS_SOURCES_FLOAT", "CELT_SOURCES", "SILK_SOURCES", "SILK_SOURCES_FLOAT")
MANIFESTS = ("opus_sources.mk", "celt_sources.mk", "silk_sources.mk")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fingerprint(files):
    return sha(json.dumps(files, sort_keys=True, separators=(",", ":")).encode())


def read_lock(path):
    data = path.read_bytes()
    lock = json.loads(data)
    keys = {"schemaVersion", "sourceURL", "revision", "tree", "archivePath", "archiveSHA256",
            "version", "archiveRoot", "licenseSHA256", "manifestSHA256", "preparedFilesSHA256"}
    if set(lock) != keys or lock["schemaVersion"] != 1:
        raise RuntimeError("Unsupported Opus lock fields or version")
    for key in ("revision", "tree"):
        if not isinstance(lock[key], str) or not re.fullmatch(r"[0-9a-f]{40}", lock[key]):
            raise RuntimeError("Opus requires complete Git pins")
    hashes = [lock[key] for key in ("archiveSHA256", "licenseSHA256", "preparedFilesSHA256")]
    if not isinstance(lock["manifestSHA256"], dict) or set(lock["manifestSHA256"]) != set(MANIFESTS):
        raise RuntimeError("Unexpected Opus source manifests")
    hashes += list(lock["manifestSHA256"].values())
    if any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes):
        raise RuntimeError("Opus requires complete content hashes")
    if not isinstance(lock["version"], str) or not re.fullmatch(r"\d+\.\d+\.\d+", lock["version"]):
        raise RuntimeError("Unexpected Opus version")
    if lock["archiveRoot"] != "opus-" + lock["version"]:
        raise RuntimeError("Unexpected Opus archive root")
    relative = PurePosixPath(lock["archivePath"])
    if relative.is_absolute() or ".." in relative.parts or not relative.parts or "\\" in str(relative):
        raise RuntimeError("Unsafe Opus Git blob path")
    if not isinstance(lock["sourceURL"], str) or not 0 < len(lock["sourceURL"]) <= 4096:
        raise RuntimeError("Missing Opus Git source")
    return lock, sha(data)


def plain_parent(path):
    if path.is_symlink() or path.parent.is_symlink():
        raise RuntimeError("Dependency cache symlinks are refused")


def source_git(source, *args):
    return ["git", "--no-replace-objects", "--git-dir", str(source), *args]


def output(*args):
    return subprocess.check_output(args).decode().strip()


def verify_source(source, lock):
    plain_parent(source)
    if output(*source_git(source, "rev-parse", "--is-bare-repository")) != "true":
        raise RuntimeError("Opus source cache must be bare")
    if output(*source_git(source, "rev-parse", lock["revision"] + "^{tree}")) != lock["tree"]:
        raise RuntimeError("Opus source tree differs from locked pin")


def prepare_source(source, lock):
    plain_parent(source)
    if source.exists():
        verify_source(source, lock)
        return
    source.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="opus-source-", dir=source.parent) as temporary:
        staged = Path(temporary) / "repository.git"
        output("git", "init", "--bare", "--quiet", "--initial-branch=main", str(staged))
        output(*source_git(staged, "fetch", "--depth", "1", "--no-tags", lock["sourceURL"], lock["revision"]))
        if output(*source_git(staged, "rev-parse", "FETCH_HEAD")) != lock["revision"]:
            raise RuntimeError("Fetched Opus source differs from locked revision")
        verify_source(staged, lock)
        staged.rename(source)


def archive_files(blob, lock):
    if len(blob) > 12 * 1024 * 1024 or sha(blob) != lock["archiveSHA256"]:
        raise RuntimeError("Opus archive checksum or size mismatch")
    files, names, total = {}, set(), 0
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or "\\" in member.name or not path.parts or \
                    path.parts[0] != lock["archiveRoot"] or member.name in names or \
                    not (member.isfile() or member.isdir()):
                raise RuntimeError("Unsafe Opus archive member")
            names.add(member.name); total += member.size
            if member.size < 0 or member.size > 20 * 1024 * 1024 or total > 64 * 1024 * 1024 or len(names) > 5000:
                raise RuntimeError("Opus archive exceeds source bounds")
            if member.isfile():
                relative = path.relative_to(lock["archiveRoot"]).as_posix()
                files[relative] = archive.extractfile(member).read()
    return files


def package_manifest(sources, version):
    return f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MakoshOpus", platforms: [.macOS("26.0")],
    products: [.library(name: "COpus", targets: ["COpus"])],
    targets: [.target(name: "COpus", path: "Sources/COpus",
        sources: {json.dumps(sources)}, publicHeadersPath: "include",
        cSettings: [.headerSearchPath("."), .headerSearchPath("celt"),
            .headerSearchPath("silk"), .headerSearchPath("silk/float"),
            .define("OPUS_BUILD"), .define("USE_ALLOCA"), .define("HAVE_ALLOCA_H"),
            .define("HAVE_LRINT"), .define("HAVE_LRINTF"),
            .define("PACKAGE_VERSION", to: {json.dumps('"' + version + '"')})])], cLanguageStandard: .c99)
'''.encode()


def build_inputs(files, lock):
    if sha(files.get("COPYING", b"")) != lock["licenseSHA256"]:
        raise RuntimeError("Opus license differs from reviewed notice")
    groups = {}
    result = {"COPYING": files["COPYING"]}
    for name in MANIFESTS:
        content = files.get(name, b"")
        if sha(content) != lock["manifestSHA256"][name]:
            raise RuntimeError("Opus source manifest differs from reviewed pin")
        result["Provenance/" + name] = content
        for match in re.finditer(r"^([A-Z0-9_]+)\s*=\s*([^=]*?)(?=^[A-Z0-9_]+\s*=|\Z)", content.decode(), re.M | re.S):
            key, values = match.groups()
            if key in groups: raise RuntimeError("Duplicate Opus source group")
            groups[key] = values.replace("\\\n", " ").split()
    if not all(name in groups for name in GROUPS):
        raise RuntimeError("Missing portable Opus source group")
    sources = sorted({name for group in GROUPS for name in groups[group]})
    for name in sources:
        path = PurePosixPath(name)
        if not re.fullmatch(r"(?:src|celt|silk)/[a-zA-Z0-9_/]+\.c", name) or ".." in path.parts or name not in files:
            raise RuntimeError("Unreviewed Opus compilation input")
        result["Sources/COpus/" + name] = files[name]
    for name, content in files.items():
        path = PurePosixPath(name)
        if path.suffix == ".h" and path.parts[0] in ("src", "celt", "silk", "include"):
            result["Sources/COpus/" + name] = content
    if not sources or "Sources/COpus/include/opus.h" not in result:
        raise RuntimeError("Incomplete Opus compilation inputs")
    result["Package.swift"] = package_manifest(sources, lock["version"])
    if fingerprint({name: sha(content) for name, content in result.items()}) != lock["preparedFilesSHA256"]:
        raise RuntimeError("Prepared Opus file set differs from reviewed pin")
    return result


def prepared_hashes(destination):
    result = {}
    for path in sorted(destination.rglob("*")):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise RuntimeError("Prepared Opus contains a link or special file")
        if path.is_file() and path != destination / "preparation.json":
            if path.stat().st_size > 20 * 1024 * 1024 or len(result) >= 5000:
                raise RuntimeError("Prepared Opus exceeds bounds")
            result[path.relative_to(destination).as_posix()] = sha(path.read_bytes())
    return result


def prepare(lock_path, source_cache, destination):
    lock, lock_hash = read_lock(lock_path)
    plain_parent(destination)
    recipe_hash = sha(RECIPE.read_bytes())
    if destination.exists():
        marker = destination / "preparation.json"
        if marker.is_symlink() or not marker.is_file():
            raise RuntimeError("Unmarked Opus directory; preserve before preparing")
        record = json.loads(marker.read_text())
        files = prepared_hashes(destination)
        if fingerprint(files) != lock["preparedFilesSHA256"] or record != {
                "lockSHA256": lock_hash, "recipeSHA256": recipe_hash, "preparedFiles": files}:
            raise RuntimeError("Prepared Opus file set, content, pin or recipe changed; preserve before preparing")
        return
    prepare_source(source_cache, lock)
    size = int(output(*source_git(source_cache, "cat-file", "-s", lock["revision"] + ":" + lock["archivePath"])))
    if not 0 < size <= 12 * 1024 * 1024: raise RuntimeError("Opus source blob exceeds bounds")
    blob = subprocess.check_output(source_git(source_cache, "show", lock["revision"] + ":" + lock["archivePath"]))
    files = build_inputs(archive_files(blob, lock), lock)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="opus-prepared-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "package"; staged.mkdir()
        for name, content in files.items():
            path = staged / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(content)
        hashes = prepared_hashes(staged)
        (staged / "preparation.json").write_text(json.dumps({"lockSHA256": lock_hash,
            "recipeSHA256": recipe_hash, "preparedFiles": hashes}, indent=2, sort_keys=True) + "\n")
        if destination.exists() or destination.is_symlink(): raise RuntimeError("Opus destination appeared during preparation")
        staged.rename(destination)


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    prepare(root / "Dependencies/Opus.lock.json", root / ".local/telegram-source.git", root / ".local/voice-codec")
