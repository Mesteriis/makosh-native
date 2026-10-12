#!/usr/bin/env python3
"""Prepare the independently pinned, portable RLottie source closure."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import urllib.request

RECIPE = Path(__file__).resolve()
ROOT = RECIPE.parent.parent
spec = importlib.util.spec_from_file_location("rlottie_archive_helpers", RECIPE.with_name("prepare-opus.py"))
helpers = importlib.util.module_from_spec(spec); spec.loader.exec_module(helpers)
REVISION = "67f103bc8b625f2a4a9e94f1d8c7bd84c5a08d1d"
URL = "https://codeload.github.com/TelegramMessenger/rlottie/tar.gz/" + REVISION
NOTICES = {"COPYING", "licenses/COPYING.FTL", "licenses/COPYING.LGPL", "licenses/COPYING.PIX", "licenses/COPYING.RPD", "licenses/COPYING.STB"}


def validate_lock(lock):
    required = {"schemaVersion", "revision", "sourceURL", "archiveRoot", "archiveSHA256", "sourceFilesSHA256", "sources"}
    if set(lock) not in [required, required | {"preparedFilesSHA256"}] or lock["schemaVersion"] != 1 or \
            lock["revision"] != REVISION or lock["sourceURL"] != URL or lock["archiveRoot"] != "rlottie-" + REVISION:
        raise ValueError("Unreviewed RLottie archive origin or fields")
    hashes = [lock["archiveSHA256"]] + ([lock["preparedFilesSHA256"]] if "preparedFilesSHA256" in lock else [])
    files = lock["sourceFilesSHA256"]
    if not isinstance(files, dict) or len(files) != 109 or not NOTICES.issubset(files):
        raise ValueError("Incomplete RLottie source closure")
    for path, digest in files.items():
        if not isinstance(path, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", path) or \
                any(p in (".", "..") for p in Path(path).parts) or not (path in NOTICES or path.endswith((".cpp", ".h"))):
            raise ValueError("Unsafe RLottie source path")
        hashes.append(digest)
    if any(not isinstance(h, str) or not re.fullmatch(r"[0-9a-f]{64}", h) for h in hashes):
        raise ValueError("Incomplete RLottie content pins")
    sources = sorted(n for n in files if n.endswith(".cpp"))
    if len(sources) != 31 or lock["sources"] != sources:
        raise ValueError("Unreviewed RLottie compilation units")


def build_inputs(files, lock):
    validate_lock(lock)
    if set(files) != set(lock["sourceFilesSHA256"]) or any(not isinstance(data, bytes) or helpers.sha(data) != lock["sourceFilesSHA256"][name] for name, data in files.items()):
        raise ValueError("RLottie source bytes differ from reviewed closure")
    result = {}
    for name, data in files.items():
        target = "Licenses/" + name.split("/")[-1] if name in NOTICES else "Sources/CRLottie/" + name
        result[target] = data
    result["Sources/CRLottie/include/CRLottie.h"] = b'#pragma once\n#include "../inc/rlottie.h"\n'
    result["Sources/CRLottie/include/module.modulemap"] = b'module CRLottie { requires cplusplus header "CRLottie.h" export * }\n'
    result["Sources/CRLottie/config.h"] = b'/* Makosh portable configuration; optional modules remain disabled. */\n#pragma once\n'
    result["Package.swift"] = ('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MakoshRLottie", platforms: [.macOS("26.0")],
    products: [.library(name: "CRLottie", targets: ["CRLottie"])],
    targets: [.target(name: "CRLottie", path: "Sources/CRLottie",
        sources: ''' + json.dumps(lock["sources"]) + ''', publicHeadersPath: "include",
        cxxSettings: [.headerSearchPath("."), .headerSearchPath("inc"), .headerSearchPath("src/vector"),
            .headerSearchPath("src/vector/pixman"), .headerSearchPath("src/vector/freetype"),
            .define("LOTTIE_IMAGE_MODULE_DISABLED", to: "1"), .define("LOTTIE_THREAD_SAFE", to: "1"),
            .define("LOTTIE_DISABLE_ARM_NEON", to: "1"),
            .define("pixman_region_selfcheck(x)", to: "1")])], cxxLanguageStandard: .cxx17)
''').encode()
    reviewed = lock.get("preparedFilesSHA256")
    if reviewed is not None and helpers.fingerprint({name: helpers.sha(data) for name, data in result.items()}) != reviewed:
        raise RuntimeError("RLottie prepared closure differs from review")
    return result


def prepare(lock_path, cache, destination):
    raw = lock_path.read_bytes()
    if len(raw) > 64 * 1024: raise RuntimeError("Oversized RLottie pin")
    lock = json.loads(raw); validate_lock(lock)
    if "preparedFilesSHA256" not in lock: raise RuntimeError("Missing reviewed RLottie output pin")
    helpers.plain_parent(destination)
    identity = {"lockSHA256": helpers.sha(raw), "recipeSHA256": helpers.sha(RECIPE.read_bytes()),
                "helperSHA256": helpers.sha(helpers.RECIPE.read_bytes())}
    if destination.exists():
        marker = destination / "preparation.json"
        if marker.is_symlink() or not marker.is_file(): raise RuntimeError("Unmarked RLottie output; preserve before preparing")
        hashes = helpers.prepared_hashes(destination)
        if helpers.fingerprint(hashes) != lock["preparedFilesSHA256"] or json.loads(marker.read_bytes()) != dict(identity, preparedFiles=hashes):
            raise RuntimeError("RLottie output, recipe or pin changed; preserve before preparing")
        print("RLottie: verified independent source preparation"); return
    helpers.plain_parent(cache); cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (lock["archiveSHA256"] + ".tar.gz")
    if archive.is_symlink(): raise RuntimeError("RLottie source cache link refused")
    if not archive.exists():
        with urllib.request.urlopen(lock["sourceURL"], timeout=30) as response:
            if not response.url.startswith("https://"): raise RuntimeError("RLottie archive transport downgrade")
            blob = response.read(12 * 1024 * 1024 + 1)
        if len(blob) > 12 * 1024 * 1024 or helpers.sha(blob) != lock["archiveSHA256"]: raise RuntimeError("RLottie archive differs from pin")
        with archive.open("xb") as output: output.write(blob)
    if not archive.is_file() or archive.stat().st_size > 12 * 1024 * 1024: raise RuntimeError("RLottie archive exceeds bounds")
    all_files = helpers.archive_files(archive.read_bytes(), lock)
    if not set(lock["sourceFilesSHA256"]).issubset(all_files): raise RuntimeError("RLottie archive lacks reviewed sources")
    files = build_inputs({name: all_files[name] for name in lock["sourceFilesSHA256"]}, lock)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rlottie-prepared-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "package"; staged.mkdir()
        for name, data in files.items():
            path = staged / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        hashes = helpers.prepared_hashes(staged)
        (staged / "preparation.json").write_text(json.dumps(dict(identity, preparedFiles=hashes), indent=2, sort_keys=True) + "\n")
        if destination.exists() or destination.is_symlink(): raise RuntimeError("RLottie destination appeared")
        staged.rename(destination)
    print("RLottie: prepared reviewed portable source closure")


if __name__ == "__main__":
    prepare(ROOT / "Dependencies/RLottie.lock.json", ROOT / ".local/rlottie-archives", ROOT / ".local/rlottie-codec")
