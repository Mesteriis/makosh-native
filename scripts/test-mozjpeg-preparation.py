#!/usr/bin/env python3
"""Local committed fixtures exercise the locked portable JPEG preparation."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

RECIPE = Path(__file__).with_name("prepare-mozjpeg.py")


def sha(data):
    return hashlib.sha256(data).hexdigest()


class MozjpegPreparationTests(unittest.TestCase):
    def fixture(self, root, source_link=False):
        self.assertTrue(RECIPE.is_file(), "Pinned JPEG preparation is missing")
        spec = importlib.util.spec_from_file_location("jpeg_preparation", RECIPE)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        upstream = root / "upstream"; source = upstream / "codec"; source.mkdir(parents=True)
        files = {"fixture.c": b'#include "fragment.c"\nint fixture(void) { return 9; }\n',
            "fragment.c": b"/* included C fragment, not a compilation unit */\n", "fixture.h": b"int fixture(void);\n",
            "LICENSE.md": b"Synthetic BSD notice\n", "README.ijg": b"Synthetic IJG notice\n",
            "README-mozilla.txt": b"Synthetic provenance\n", "simd/nasm/jsimdext.inc": b"Synthetic zlib notice\n",
            "CMakeLists.txt": b"set(JPEG_SOURCES fixture.c)\n",
            "jconfig.h.in": b"#define JPEG_LIB_VERSION @JPEG_LIB_VERSION@\n#cmakedefine WITH_SIMD 1\n",
            "jconfigint.h.in": b'#define BUILD "@BUILD@"\n#define SIZEOF_SIZE_T @SIZE_T@\n',
            "jversion.h.in": b'#define JCOPYRIGHT_SHORT "Copyright @COPYRIGHT_YEAR@"\n'}
        for name, data in files.items():
            target = source / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        (source / "configure").write_bytes(b"UPSTREAM INSTALLER MUST NEVER EXECUTE\n")
        if source_link:
            (source / "fixture.c").unlink(); (source / "fixture.c").symlink_to("fixture.h")
        def git(*args):
            return subprocess.check_output(["git", "-C", str(upstream), *args], stderr=subprocess.DEVNULL).decode().strip()
        git("init", "--quiet"); git("add", ".")
        git("-c", "user.name=JPEG fixture", "-c", "user.email=synthetic@example.invalid", "commit", "--quiet", "-m", "fixture")
        manifest = b'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MakoshMozjpeg", platforms: [.macOS("26.0")],
    products: [.library(name: "CMozjpeg", targets: ["CMozjpeg"])],
    targets: [.target(name: "CMozjpeg", path: "Sources/CMozjpeg",
        sources: ["fixture.c"], publicHeadersPath: "include",
        cSettings: [.headerSearchPath(".")])], cLanguageStandard: .c99)
'''
        expected = {"Package.swift": manifest,
            "Sources/CMozjpeg/include/CMozjpeg.h": b"#include <stddef.h>\n#include <stdio.h>\n#include \"jpeglib.h\"\n",
            "Sources/CMozjpeg/include/module.modulemap": b'module CMozjpeg { header "CMozjpeg.h" export * }\n'}
        for name, data in files.items():
            if name.endswith((".c", ".h")): expected["Sources/CMozjpeg/" + name] = data
            else: expected["Provenance/" + name] = data
        expected.update({"Sources/CMozjpeg/include/jconfig.h": b"#define JPEG_LIB_VERSION 80\n/* #undef WITH_SIMD */\n",
            "Sources/CMozjpeg/jconfigint.h": b'#define BUILD "makosh-pinned"\n#define SIZEOF_SIZE_T 8\n',
            "Sources/CMozjpeg/jversion.h": b'#define JCOPYRIGHT_SHORT "Copyright 1991-2023"\n'})
        lock = dict(schemaVersion=1, sourceURL=str(upstream), revision=git("rev-parse", "HEAD"),
            tree=git("rev-parse", "HEAD^{tree}"), sourcePath="codec", version="4.1.4", sources=["fixture.c"],
            sourceFilesSHA256={name: sha(data) for name, data in sorted(files.items())},
            preparedFilesSHA256=sha(json.dumps({name: sha(data) for name, data in expected.items()}, sort_keys=True, separators=(",", ":")).encode()))
        path = root / "lock.json"; path.write_text(json.dumps(lock))
        return module, path, root / "cache.git", root / "prepared", lock, expected

    # Missing locked selection, altered bytes, or executing upstream configure breaks this real output check.
    def test_exact_sources_and_notices_prepare_without_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            module, lock, cache, destination, _, expected = self.fixture(Path(temporary))
            module.prepare(lock, cache, destination)
            for name, data in expected.items(): self.assertEqual((destination / name).read_bytes(), data)
            self.assertFalse((destination / "configure").exists())
            self.assertFalse((destination.parent / ".references").exists())

    # An unnecessary source/network dependency during authenticated warm reuse breaks this.
    def test_warm_reuse_without_source_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            module, lock, cache, destination, _, _ = self.fixture(Path(temporary))
            module.prepare(lock, cache, destination)
            module.prepare(lock, destination.parent / "missing.git", destination)
            self.assertFalse((destination.parent / "missing.git").exists())

    # A writable marker must not legitimize tampered generated/compiled input or extra files.
    def test_changed_output_is_refused_and_preserved(self):
        for mutation in ["changed", "missing", "extra", "symlink"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                module, lock, cache, destination, _, _ = self.fixture(Path(temporary))
                module.prepare(lock, cache, destination)
                target = destination / "Sources/CMozjpeg/fixture.c"
                if mutation == "changed": target.write_bytes(b"tampered")
                elif mutation == "missing": target.unlink()
                elif mutation == "extra": (destination / "extra.c").write_bytes(b"tampered")
                else: target.unlink(); target.symlink_to(lock)
                with self.assertRaises(RuntimeError): module.prepare(lock, cache, destination)
                self.assertTrue(destination.exists())

    # Each authoritative provenance pin must reject before an artifact is published.
    def test_changed_pins_fail_closed(self):
        for field in ["tree", "sourceFilesSHA256", "preparedFilesSHA256"]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                module, path, cache, destination, lock, _ = self.fixture(Path(temporary))
                lock[field] = {name: "0" * 64 for name in lock[field]} if isinstance(lock[field], dict) else "0" * len(lock[field])
                path.write_text(json.dumps(lock))
                with self.assertRaises(RuntimeError): module.prepare(path, cache, destination)
                self.assertFalse(destination.exists())

    # Path traversal and repository symlink blobs must not enter the build.
    def test_unsafe_paths_and_source_modes_refuse(self):
        for link in [False, True]:
            with self.subTest(source_link=link), tempfile.TemporaryDirectory() as temporary:
                module, path, cache, destination, lock, _ = self.fixture(Path(temporary), source_link=link)
                if not link: lock["sourcePath"] = "../escape"; path.write_text(json.dumps(lock))
                with self.assertRaises(RuntimeError): module.prepare(path, cache, destination)
                self.assertFalse(destination.exists())


if __name__ == "__main__": unittest.main()
