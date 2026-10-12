#!/usr/bin/env python3
"""Select unchanged pinned JPEG C sources; never execute upstream build scripts."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile

RECIPE = Path(__file__).resolve()
TEMPLATES = ("jconfig.h.in", "jconfigint.h.in", "jversion.h.in")
NOTICES = ("LICENSE.md", "README.ijg", "README-mozilla.txt", "simd/nasm/jsimdext.inc")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fingerprint(files):
    return sha(json.dumps(files, sort_keys=True, separators=(",", ":")).encode())


def safe_path(value):
    return isinstance(value, str) and bool(re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", value)) \
        and not any(part in (".", "..") for part in PurePosixPath(value).parts)


def read_lock(path):
    data = path.read_bytes(); lock = json.loads(data)
    if len(data) > 128 * 1024 or set(lock) != {"schemaVersion", "sourceURL", "revision", "tree", "sourcePath", "version",
            "sources", "sourceFilesSHA256", "preparedFilesSHA256"} or lock["schemaVersion"] != 1:
        raise RuntimeError("Unsupported JPEG lock")
    if any(not isinstance(lock[k], str) or not re.fullmatch(r"[0-9a-f]{40}", lock[k]) for k in ("revision", "tree")) \
            or lock["version"] != "4.1.4" or not safe_path(lock["sourcePath"]) \
            or not isinstance(lock["sourceURL"], str) or not 0 < len(lock["sourceURL"]) < 4096:
        raise RuntimeError("Invalid JPEG source pin")
    files, sources = lock["sourceFilesSHA256"], lock["sources"]
    if not isinstance(files, dict) or not 0 < len(files) <= 256 or not isinstance(sources, list) or not sources \
            or any(not isinstance(s, str) for s in sources) or sources != sorted(set(sources)) \
            or any(not safe_path(s) or "/" in s or not s.endswith(".c") or s not in files for s in sources) \
            or not set(TEMPLATES + NOTICES + ("CMakeLists.txt",)).issubset(files):
        raise RuntimeError("Invalid JPEG compilation selection")
    if any(not safe_path(name) or not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for name, value in files.items()) \
            or not isinstance(lock["preparedFilesSHA256"], str) or not re.fullmatch(r"[0-9a-f]{64}", lock["preparedFilesSHA256"]):
        raise RuntimeError("Invalid JPEG content pins")
    return lock, sha(data)


def plain_parent(path):
    if path.is_symlink() or path.parent.is_symlink():
        raise RuntimeError("JPEG cache symlinks are refused")


def git(source, *args):
    return ["git", "--no-replace-objects", "--git-dir", str(source), *args]


def output(*args):
    return subprocess.check_output(args).decode().strip()


def verify_source(source, lock):
    plain_parent(source)
    if output(*git(source, "rev-parse", "--is-bare-repository")) != "true" \
            or output(*git(source, "rev-parse", lock["revision"] + "^{tree}")) != lock["tree"]:
        raise RuntimeError("JPEG cache differs from pinned bare Git tree")


def prepare_source(source, lock):
    plain_parent(source)
    if source.exists(): verify_source(source, lock); return
    source.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="jpeg-source-", dir=source.parent) as temporary:
        staged = Path(temporary) / "repository.git"
        output("git", "init", "--bare", "--quiet", "--initial-branch=main", str(staged))
        output(*git(staged, "fetch", "--depth", "1", "--no-tags", lock["sourceURL"], lock["revision"]))
        if output(*git(staged, "rev-parse", "FETCH_HEAD")) != lock["revision"]:
            raise RuntimeError("Fetched JPEG revision differs")
        verify_source(staged, lock); staged.rename(source)


def source_files(source, lock):
    selected = lock["sourceFilesSHA256"]
    entries = subprocess.check_output(git(source, "ls-tree", "-r", "-z", lock["revision"] + ":" + lock["sourcePath"], "--", *selected))
    objects = {}
    for entry in entries.split(b"\0"):
        if not entry: continue
        header, name = entry.split(b"\t", 1); mode, kind, oid = header.decode().split(); name = name.decode()
        if name in objects or name not in selected or mode != "100644" or kind != "blob":
            raise RuntimeError("JPEG source has an unreviewed path or Git mode")
        objects[name] = oid
    if set(objects) != set(selected): raise RuntimeError("Missing JPEG source file")
    files, total = {}, 0
    for name, oid in objects.items():
        size = int(output(*git(source, "cat-file", "-s", oid))); total += size
        if not 0 <= size <= 4 * 1024 * 1024 or total > 16 * 1024 * 1024:
            raise RuntimeError("JPEG source exceeds bounds")
        data = subprocess.check_output(git(source, "cat-file", "blob", oid))
        if len(data) != size or sha(data) != selected[name]: raise RuntimeError("JPEG source checksum differs")
        files[name] = data
    return files


def configured(data, values):
    text = data.decode()
    for name, value in values.items(): text = text.replace("@" + name + "@", value)
    enabled = {"C_ARITH_CODING_SUPPORTED", "D_ARITH_CODING_SUPPORTED", "MEM_SRCDST_SUPPORTED", "HAVE_BUILTIN_CTZL"}
    text = re.sub(r"^#cmakedefine (\w+)([^\n]*)$", lambda m: "#define " + m[1] + m[2] if m[1] in enabled else "/* #undef " + m[1] + " */", text, flags=re.M)
    if re.search(r"@[A-Za-z0-9_]+@|#cmakedefine", text): raise RuntimeError("Unknown JPEG configuration variable")
    return text.encode()


def build_inputs(files, lock):
    result = {
        "Sources/CMozjpeg/include/CMozjpeg.h": b"#include <stddef.h>\n#include <stdio.h>\n#include \"jpeglib.h\"\n",
        "Sources/CMozjpeg/include/module.modulemap": b'module CMozjpeg { header "CMozjpeg.h" export * }\n'}
    public = {"jpeglib.h", "jerror.h", "jmorecfg.h"}
    for name, data in files.items():
        if name.endswith((".c", ".h")):
            result["Sources/CMozjpeg/" + ("include/" if name in public else "") + name] = data
        else: result["Provenance/" + name] = data
    values = {"JPEG_LIB_VERSION": "80", "VERSION": lock["version"], "LIBJPEG_TURBO_VERSION_NUMBER": "4001004",
        "BITS_IN_JSAMPLE": "8", "BUILD": "makosh-pinned", "INLINE": "__inline__", "THREAD_LOCAL": "__thread",
        "CMAKE_PROJECT_NAME": "mozjpeg", "SIZE_T": "8", "COPYRIGHT_YEAR": "1991-2023"}
    for name, target in zip(TEMPLATES, ("include/jconfig.h", "jconfigint.h", "jversion.h")):
        result["Sources/CMozjpeg/" + target] = configured(files[name], values)
    result["Package.swift"] = f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MakoshMozjpeg", platforms: [.macOS("26.0")],
    products: [.library(name: "CMozjpeg", targets: ["CMozjpeg"])],
    targets: [.target(name: "CMozjpeg", path: "Sources/CMozjpeg",
        sources: {json.dumps(lock["sources"])}, publicHeadersPath: "include",
        cSettings: [.headerSearchPath(".")])], cLanguageStandard: .c99)
'''.encode()
    if fingerprint({name: sha(data) for name, data in result.items()}) != lock["preparedFilesSHA256"]:
        raise RuntimeError("JPEG prepared file set differs from reviewed pin")
    return result


def prepared_hashes(destination):
    files, total = {}, 0
    for path in sorted(destination.rglob("*")):
        if path.is_symlink() or not (path.is_file() or path.is_dir()): raise RuntimeError("JPEG artifact contains a link or special file")
        if path.is_file() and path != destination / "preparation.json":
            size = path.stat().st_size; total += size
            if size > 4 * 1024 * 1024 or total > 16 * 1024 * 1024 or len(files) >= 300:
                raise RuntimeError("JPEG artifact exceeds bounds")
            files[path.relative_to(destination).as_posix()] = sha(path.read_bytes())
    return files


def prepare(lock_path, source_cache, destination):
    lock, lock_hash = read_lock(lock_path); plain_parent(destination)
    recipe_hash = sha(RECIPE.read_bytes())
    if destination.exists():
        marker = destination / "preparation.json"
        if marker.is_symlink() or not marker.is_file(): raise RuntimeError("Unmarked JPEG output; preserve before preparing")
        record = json.loads(marker.read_text()); files = prepared_hashes(destination)
        if fingerprint(files) != lock["preparedFilesSHA256"] or record != {
                "lockSHA256": lock_hash, "recipeSHA256": recipe_hash, "preparedFiles": files}:
            raise RuntimeError("JPEG artifact, pin or recipe changed; preserve before preparing")
        return
    prepare_source(source_cache, lock)
    files = build_inputs(source_files(source_cache, lock), lock)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="jpeg-prepared-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "package"; staged.mkdir()
        for name, data in files.items():
            target = staged / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        hashes = prepared_hashes(staged)
        (staged / "preparation.json").write_text(json.dumps({"lockSHA256": lock_hash,
            "recipeSHA256": recipe_hash, "preparedFiles": hashes}, indent=2, sort_keys=True) + "\n")
        if destination.exists() or destination.is_symlink(): raise RuntimeError("JPEG output appeared during preparation")
        staged.rename(destination)


if __name__ == "__main__":
    root = RECIPE.parent.parent
    prepare(root / "Dependencies/Mozjpeg.lock.json", root / ".local/telegram-source.git", root / ".local/jpeg-codec")
