#!/usr/bin/env python3
"""Synthetic archives exercise trust and offline reuse, without upstream tools."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("opusfile_preparation", Path(__file__).with_name("prepare-opusfile.py"))
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)


class OpusFilePreparationTests(unittest.TestCase):
    def test_compilation_inputs_match_independently_frozen_review(self):
        # Freeze the reviewed module flags/paths, ABI types and source membership,
        # independently of the positive archive fixture's expected-output builder.
        self.assertEqual(p.helpers.sha(p.MANIFEST), "650992a5b3b70d7bede425f7e8cb9656a4ca74f8ea987e1ec948c55945022bdd")
        self.assertEqual(p.helpers.sha(p.CONFIG), "8330645812c135ca678218428f7e2d26fd1bc887957e9a1d5bbf61e09d4bade2")
        self.assertEqual(p.helpers.fingerprint(p.INPUTS), "8d31baf4f42b42cb71909ca50e6bbad9723e58a51b80b1121789d055719d9817")

    def test_changed_imported_helper_refuses_warm_reuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, cache, dest, _, _ = self.fixture(Path(tmp))
            original = p.helpers.RECIPE
            helper = Path(tmp) / "helper.py"; helper.write_bytes(original.read_bytes())
            try:
                p.helpers.RECIPE = helper
                p.prepare(path, cache, dest)
                helper.write_bytes(b"different reviewed helper recipe\n")
                with self.assertRaises(RuntimeError): p.prepare(path, cache, dest)
            finally: p.helpers.RECIPE = original

    def fixture(self, root, unsafe=None):
        cache = root / "cache"; cache.mkdir()
        lock = {"schemaVersion": 1, "archives": {}, "preparedFilesSHA256": "0" * 64}
        expected = {"Package.swift": p.MANIFEST, "Sources/COgg/include/ogg/config_types.h": p.CONFIG}
        for key, names in p.INPUTS.items():
            files = {name: ("/* Synthetic " + name + " */\n").encode() for name in names}
            files.update({"COPYING": b"Synthetic BSD3 notice\n", "Makefile.am": b"synthetic source manifest\n",
                          "configure": b"MUST NEVER EXECUTE\n", "src/http.c": b"MUST NEVER COMPILE\n"})
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
                for name, data in files.items():
                    item = tarfile.TarInfo(p.ROOTS[key] + "/" + name); item.size = len(data)
                    tar.addfile(item, io.BytesIO(data))
                if unsafe and key == "ogg":
                    item = tarfile.TarInfo(unsafe); item.size = 1
                    tar.addfile(item, io.BytesIO(b"x"))
            blob = buffer.getvalue()
            entry = {"sourceURL": p.URLS[key], "archiveRoot": p.ROOTS[key], "archiveSHA256": p.helpers.sha(blob),
                     "licenseSHA256": p.helpers.sha(files["COPYING"]), "manifestSHA256": p.helpers.sha(files["Makefile.am"])}
            lock["archives"][key] = entry
            (cache / (entry["archiveSHA256"] + ".tar.gz")).write_bytes(blob)
            target = "COgg" if key == "ogg" else "COpusFile"
            expected.update({"Sources/" + target + "/" + name: files[name] for name in names})
            expected["Licenses/" + key + ".txt"] = files["COPYING"]
            expected["Provenance/" + key + "-Makefile.am"] = files["Makefile.am"]
        lock["preparedFilesSHA256"] = p.helpers.fingerprint({name: p.helpers.sha(data) for name, data in expected.items()})
        path = root / "lock.json"; path.write_text(json.dumps(lock))
        return path, cache, root / "prepared", lock, expected

    def test_exact_sources_and_notices_prepare_without_tools_or_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, cache, dest, _, expected = self.fixture(Path(tmp)); p.prepare(path, cache, dest)
            self.assertTrue(dest.is_dir(), "Pinned sources are missing")
            actual = {str(f.relative_to(dest)): f.read_bytes() for f in dest.rglob("*") if f.is_file() and f.name != "preparation.json"}
            self.assertEqual(actual, expected)
            self.assertFalse((dest / "Sources/COpusFile/src/http.c").exists())

    def test_warm_reuse_needs_neither_network_nor_archive_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, cache, dest, _, _ = self.fixture(Path(tmp)); p.prepare(path, cache, dest)
            self.assertTrue(dest.is_dir())
            p.prepare(path, Path(tmp) / "absent-cache", dest)
            self.assertFalse((Path(tmp) / "absent-cache").exists())

    def test_corrupt_missing_extra_and_link_outputs_are_refused(self):
        for mutation in ["corrupt", "missing", "extra", "link"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                path, cache, dest, _, _ = self.fixture(Path(tmp)); p.prepare(path, cache, dest)
                self.assertTrue(dest.is_dir())
                item = dest / "Sources/COpusFile/src/info.c"
                if mutation == "corrupt": item.write_bytes(b"changed")
                elif mutation == "missing": item.unlink()
                elif mutation == "extra": (dest / "extra").write_bytes(b"x")
                else: item.unlink(); item.symlink_to(path)
                with self.assertRaises(RuntimeError): p.prepare(path, cache, dest)

    def test_changed_blob_license_manifest_or_file_set_never_publishes(self):
        for field in ["archiveSHA256", "licenseSHA256", "manifestSHA256", "preparedFilesSHA256"]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                path, cache, dest, lock, _ = self.fixture(Path(tmp))
                if field == "archiveSHA256":
                    entry = lock["archives"]["ogg"]
                    (cache / (entry["archiveSHA256"] + ".tar.gz")).write_bytes(b"corrupt")
                elif field == "preparedFilesSHA256": lock[field] = "0" * 64
                else: lock["archives"]["ogg"][field] = "0" * 64
                path.write_text(json.dumps(lock))
                with self.assertRaises(RuntimeError): p.prepare(path, cache, dest)
                self.assertFalse(dest.exists())

    def test_unsafe_tar_and_unmarked_destinations_are_preserved(self):
        for name in ["libogg-1.3.6/../../escape", "other/root"]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                path, cache, dest, _, _ = self.fixture(Path(tmp), unsafe=name)
                with self.assertRaises(RuntimeError): p.prepare(path, cache, dest)
                self.assertFalse(dest.exists()); self.assertFalse((Path(tmp) / "escape").exists())
        with tempfile.TemporaryDirectory() as tmp:
            path, cache, dest, _, _ = self.fixture(Path(tmp)); dest.mkdir()
            (dest / "user.txt").write_bytes(b"keep")
            with self.assertRaises(RuntimeError): p.prepare(path, cache, dest)
            self.assertEqual((dest / "user.txt").read_bytes(), b"keep")


if __name__ == "__main__": unittest.main()
