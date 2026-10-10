#!/usr/bin/env python3
"""Prepare the exact official flatc used by the pinned Telegram-iOS checkout."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".local" / "telegram-flatc"
VERSION = "24.12.23"
URL = "https://github.com/google/flatbuffers/archive/refs/tags/v24.12.23.zip"
SHA256 = "c5cd6a605ff20350c7faa19d8eeb599df6117ea4aabd16ac58a7eb5ba82df4e7"
SOURCE_NAME = "flatbuffers-" + VERSION
MARKER = CACHE / "preparation.json"
BINARY = CACHE / "build" / "flatc"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run(command, log):
    with (ROOT / ".local" / log).open("w") as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)


def entries(archive):
    result = []
    for item in archive.infolist():
        path = PurePosixPath(item.filename)
        mode = item.external_attr >> 16
        if path.is_absolute() or ".." in path.parts or "\\" in item.filename:
            raise ValueError("Unsafe source archive path")
        if not path.parts or path.parts[0] != SOURCE_NAME:
            raise ValueError("Unexpected source archive root")
        if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
            raise ValueError("Source archive special files are refused")
        if stat.S_ISLNK(mode) and not any(item.filename.startswith(SOURCE_NAME + "/" + prefix) for prefix in ("docs/", "java/src/test/", "tests/")):
            raise ValueError("Source archive contains a link in build inputs")
        result.append(item)
    return result


def verify_source(archive, source, items):
    expected = set()
    for item in items:
        relative = PurePosixPath(item.filename).relative_to(SOURCE_NAME)
        target = source.joinpath(*relative.parts)
        if target.is_symlink():
            raise ValueError("Source cache contains a symlink")
        if item.is_dir():
            if not target.is_dir():
                raise ValueError("Source cache is incomplete")
        else:
            # A prior manual zipfile extraction may have materialized link text
            # as a regular file. Validate it without ever creating a symlink.
            if stat.S_ISLNK(item.external_attr >> 16) and not target.exists():
                continue
            expected.add(relative.as_posix())
            if not target.is_file() or digest(target) != hashlib.sha256(archive.read(item)).hexdigest():
                raise ValueError("Source cache differs from pinned archive; preserve and inspect it")
    actual = set()
    for directory, dirs, files in os.walk(source, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            if path.is_symlink():
                raise ValueError("Source cache contains a symlink")
        actual.update((Path(directory) / name).relative_to(source).as_posix() for name in files)
    if actual != expected:
        raise ValueError("Source cache contains unexpected files; preserve and inspect it")


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    if CACHE.is_symlink() or (CACHE / "build").is_symlink():
        raise ValueError("Cache or build symlinks are refused")
    archive_path = CACHE / "source.zip"
    if archive_path.is_symlink():
        raise ValueError("Source archive symlink is refused")
    if not archive_path.exists():
        with tempfile.NamedTemporaryFile(dir=CACHE, delete=False) as temporary:
            temporary_path = Path(temporary.name)
            try:
                with urllib.request.urlopen(URL, timeout=60) as response:
                    shutil.copyfileobj(response, temporary)
                temporary.flush()
                if digest(temporary_path) != SHA256:
                    raise ValueError("Downloaded source checksum mismatch")
                temporary_path.rename(archive_path)
            finally:
                temporary_path.unlink(missing_ok=True)
    if digest(archive_path) != SHA256:
        raise ValueError("Existing source archive checksum mismatch; preserve and inspect it")
    source = CACHE / SOURCE_NAME
    with zipfile.ZipFile(archive_path) as archive:
        items = entries(archive)
        if source.is_symlink():
            raise ValueError("Source directory symlink is refused")
        if not source.exists():
            with tempfile.TemporaryDirectory(dir=CACHE) as staging:
                archive.extractall(staging, members=[item for item in items if not stat.S_ISLNK(item.external_attr >> 16)])
                (Path(staging) / SOURCE_NAME).rename(source)
        verify_source(archive, source, items)
    prior = None
    if MARKER.exists():
        if MARKER.is_symlink():
            raise ValueError("Cache marker symlink is refused")
        prior = json.loads(MARKER.read_text())
        if prior.get("source_sha256") != SHA256 or prior.get("version") != VERSION:
            raise ValueError("Cache marker differs from requested pin")
    build = CACHE / "build"
    if build.exists() and not prior:
        raise ValueError("Unmarked build directory; preserve/rename it before preparing again")
    reuse = BINARY.is_file() and not BINARY.is_symlink()
    if reuse:
        version = subprocess.check_output([str(BINARY), "--version"], text=True).strip()
        if version != "flatc version " + VERSION:
            raise ValueError("Existing compiler version differs; preserve and inspect it")
        if prior and prior.get("binary_sha256") != digest(BINARY):
            raise ValueError("Existing compiler digest differs from cache marker")
    else:
        run(["cmake", "-S", str(source), "-B", str(build), "-G", "Ninja",
             "-DCMAKE_BUILD_TYPE=Release", "-DFLATBUFFERS_BUILD_TESTS=OFF",
             "-DFLATBUFFERS_INSTALL=OFF", "-DFLATBUFFERS_BUILD_FLATLIB=OFF",
             "-DFLATBUFFERS_BUILD_FLATC=ON", "-DFLATBUFFERS_BUILD_SHAREDLIB=OFF",
             "-DFLATBUFFERS_BUILD_BENCHMARKS=OFF", "-DFLATBUFFERS_BUILD_GRPCTEST=OFF"],
            "telegram-flatc-configure.log")
        run(["cmake", "--build", str(build), "--target", "flatc", "-j4"], "telegram-flatc-build.log")
        if subprocess.check_output([str(BINARY), "--version"], text=True).strip() != "flatc version " + VERSION:
            raise ValueError("Built compiler version mismatch")
    report = {"version": VERSION, "source_url": URL, "source_sha256": SHA256,
              "rejected_archive_symlinks": [item.filename for item in items if stat.S_ISLNK(item.external_attr >> 16)],
              "binary": str(BINARY), "binary_sha256": digest(BINARY)}
    MARKER.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
