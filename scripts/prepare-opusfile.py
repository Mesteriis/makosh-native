#!/usr/bin/env python3
"""Pinned offline Ogg/Opus file sources; never runs upstream build tools."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import urllib.request

spec = importlib.util.spec_from_file_location("opus_source_helpers", Path(__file__).with_name("prepare-opus.py"))
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
RECIPE = Path(__file__).resolve()
INPUTS = {
    "ogg": ["src/bitwise.c", "src/framing.c", "src/crctable.h", "include/ogg/ogg.h", "include/ogg/os_types.h"],
    "opusfile": ["src/info.c", "src/internal.c", "src/opusfile.c", "src/stream.c", "src/internal.h", "include/opusfile.h"]
}
URLS = {"ogg": "https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz",
        "opusfile": "https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz"}
ROOTS = {"ogg": "libogg-1.3.6", "opusfile": "opusfile-0.12"}
CONFIG = b'''/* Makosh: fixed-width types for the supported macOS arm64 ABI. */
#ifndef __CONFIG_TYPES_H__
#define __CONFIG_TYPES_H__
#include <stdint.h>
typedef int16_t ogg_int16_t;
typedef uint16_t ogg_uint16_t;
typedef int32_t ogg_int32_t;
typedef uint32_t ogg_uint32_t;
typedef int64_t ogg_int64_t;
typedef uint64_t ogg_uint64_t;
#endif
'''
MANIFEST = b'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MakoshOpusFile", platforms: [.macOS("26.0")],
    products: [.library(name: "COgg", targets: ["COgg"]), .library(name: "COpusFile", targets: ["COpusFile"])],
    dependencies: [.package(name: "MakoshOpus", path: "../voice-codec")],
    targets: [
        .target(name: "COgg", path: "Sources/COgg", sources: ["src/bitwise.c", "src/framing.c"], publicHeadersPath: "include"),
        .target(name: "COpusFile", dependencies: ["COgg", .product(name: "COpus", package: "MakoshOpus")],
            path: "Sources/COpusFile", sources: ["src/info.c", "src/internal.c", "src/opusfile.c", "src/stream.c"],
            publicHeadersPath: "include", cSettings: [.define("OP_DISABLE_HTTP"), .define("HAVE_LRINTF")])
    ], cLanguageStandard: .c99)
'''


def read_lock(path):
    raw = path.read_bytes(); lock = json.loads(raw)
    if set(lock) != {"schemaVersion", "archives", "preparedFilesSHA256"} or lock["schemaVersion"] != 1 or \
            set(lock["archives"]) != set(INPUTS):
        raise RuntimeError("Unsupported OpusFile lock")
    hashes = [lock["preparedFilesSHA256"]]
    for key, entry in lock["archives"].items():
        if set(entry) != {"sourceURL", "archiveRoot", "archiveSHA256", "licenseSHA256", "manifestSHA256"} or \
                entry["sourceURL"] != URLS[key] or entry["archiveRoot"] != ROOTS[key]:
            raise RuntimeError("Unreviewed OpusFile archive source")
        hashes += [entry[name] for name in ("archiveSHA256", "licenseSHA256", "manifestSHA256")]
    if any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes):
        raise RuntimeError("OpusFile requires complete content pins")
    return lock, helpers.sha(raw)


def build_inputs(archives, lock):
    result = {"Package.swift": MANIFEST, "Sources/COgg/include/ogg/config_types.h": CONFIG}
    for key, files in archives.items():
        entry = lock["archives"][key]
        if helpers.sha(files.get("COPYING", b"")) != entry["licenseSHA256"] or \
                helpers.sha(files.get("Makefile.am", b"")) != entry["manifestSHA256"]:
            raise RuntimeError("OpusFile license or source manifest differs from review")
        target = "COgg" if key == "ogg" else "COpusFile"
        result["Licenses/" + key + ".txt"] = files["COPYING"]
        result["Provenance/" + key + "-Makefile.am"] = files["Makefile.am"]
        for name in INPUTS[key]:
            if name not in files: raise RuntimeError("Missing reviewed OpusFile source")
            result["Sources/" + target + "/" + name] = files[name]
    if helpers.fingerprint({name: helpers.sha(value) for name, value in result.items()}) != lock["preparedFilesSHA256"]:
        raise RuntimeError("OpusFile prepared file set differs from review")
    return result


def prepare(lock_path, cache, destination):
    lock, lock_hash = read_lock(lock_path)
    helpers.plain_parent(destination)
    recipe_hash = helpers.sha(RECIPE.read_bytes())
    helper_hash = helpers.sha(helpers.RECIPE.read_bytes())
    if destination.exists():
        marker = destination / "preparation.json"
        if marker.is_symlink() or not marker.is_file():
            raise RuntimeError("Unmarked OpusFile directory; preserve before preparing")
        files = helpers.prepared_hashes(destination)
        record = json.loads(marker.read_bytes())
        if helpers.fingerprint(files) != lock["preparedFilesSHA256"] or record != {
                "lockSHA256": lock_hash, "recipeSHA256": recipe_hash,
                "helperSHA256": helper_hash, "preparedFiles": files}:
            raise RuntimeError("OpusFile output, pin or recipe changed; preserve before preparing")
        return
    helpers.plain_parent(cache)
    cache.mkdir(parents=True, exist_ok=True)
    archives = {}
    for key, entry in lock["archives"].items():
        path = cache / (entry["archiveSHA256"] + ".tar.gz")
        if path.is_symlink(): raise RuntimeError("OpusFile archive cache link refused")
        if not path.exists():
            with urllib.request.urlopen(entry["sourceURL"], timeout=30) as response:
                if not response.url.startswith("https://"): raise RuntimeError("Archive transport downgrade")
                blob = response.read(3 * 1024 * 1024 + 1)
            if len(blob) > 3 * 1024 * 1024 or helpers.sha(blob) != entry["archiveSHA256"]:
                raise RuntimeError("OpusFile downloaded archive differs from pin")
            with path.open("xb") as output: output.write(blob)
        if not path.is_file() or path.stat().st_size > 3 * 1024 * 1024:
            raise RuntimeError("OpusFile archive cache exceeds bounds")
        archives[key] = helpers.archive_files(path.read_bytes(), entry)
    files = build_inputs(archives, lock)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="opusfile-prepared-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "package"; staged.mkdir()
        for name, content in files.items():
            path = staged / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(content)
        hashes = helpers.prepared_hashes(staged)
        (staged / "preparation.json").write_text(json.dumps({"lockSHA256": lock_hash,
            "recipeSHA256": recipe_hash, "helperSHA256": helper_hash,
            "preparedFiles": hashes}, indent=2, sort_keys=True) + "\n")
        if destination.exists() or destination.is_symlink(): raise RuntimeError("OpusFile destination appeared")
        staged.rename(destination)


if __name__ == "__main__":
    root = RECIPE.parent.parent
    prepare(root / "Dependencies/OpusFile.lock.json", root / ".local/opusfile-archives", root / ".local/opusfile-codec")
