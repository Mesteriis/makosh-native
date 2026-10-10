#!/usr/bin/env python3
"""Offline regressions for committed-source extraction and cache integrity."""
import importlib.util
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("preparation", Path(__file__).with_name("prepare-telegram.py"))
preparation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparation)
api_spec = importlib.util.spec_from_file_location("api_import", Path(__file__).with_name("import-telegram-api.py"))
api_import = importlib.util.module_from_spec(api_spec)
api_spec.loader.exec_module(api_import)


class PreparationTests(unittest.TestCase):
    def test_git_archive_excludes_untracked_build_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "source", root / "prepared"
            source.mkdir()
            def git(*args):
                return subprocess.check_output(["git", "-C", str(source), *args], stderr=subprocess.DEVNULL)
            git("init")
            (source / "package").mkdir()
            (source / "package/Tracked.swift").write_text("// committed\n")
            git("add", "package")
            git("-c", "user.name=Preparation Test", "-c", "user.email=synthetic@example.invalid", "commit", "-m", "fixture")
            (source / "package/Injected.swift").write_text("// untracked\n")
            preparation.extract_committed(git("archive", "HEAD", "package"), destination)
            self.assertEqual((destination / "package/Tracked.swift").read_text(), "// committed\n")
            self.assertFalse((destination / "package/Injected.swift").exists())

    def test_cache_fingerprint_detects_extra_changed_and_missing_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "One.swift"
            source.write_text("original")
            initial = preparation.prepared_files(root)
            (root / "Two.swift").write_text("extra")
            self.assertNotEqual(initial, preparation.prepared_files(root))
            (root / "Two.swift").unlink()
            source.write_text("changed")
            self.assertNotEqual(initial, preparation.prepared_files(root))
            source.unlink()
            self.assertNotEqual(initial, preparation.prepared_files(root))

    def test_refuses_archive_links_and_traversal(self):
        for name, kind in [("../escape", tarfile.REGTYPE), ("/escape", tarfile.REGTYPE), ("link", tarfile.SYMTYPE)]:
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w") as archive:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = "../escape"
                archive.addfile(member)
            with tempfile.TemporaryDirectory() as temporary, self.assertRaises(RuntimeError):
                preparation.extract_committed(buffer.getvalue(), Path(temporary))

    def test_refuses_cache_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "target").write_text("synthetic")
            (root / "link").symlink_to(root / "target")
            with self.assertRaises(RuntimeError):
                preparation.prepared_files(root)


class APIImportTests(unittest.TestCase):
    def test_selects_only_api_fields_and_never_evaluates_shell(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".env"
            path.write_text('OTHER_PRIVATE_SETTING=synthetic-ignored\nexport HERMES_TELEGRAM_API_ID="123" # comment\nHERMES_TELEGRAM_API_HASH=' + "a" * 32 + '\n')
            self.assertEqual(api_import.read_api(path), {"apiID": "123", "apiHash": "a" * 32})
            sentinel = Path(temporary) / "must-not-exist"
            path.write_text('HERMES_TELEGRAM_API_ID=123\nHERMES_TELEGRAM_API_HASH="$(touch ' + str(sentinel) + ')"\n')
            with self.assertRaises(ValueError):
                api_import.read_api(path)
            self.assertFalse(sentinel.exists())

    def test_rejects_ambiguous_duplicate_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ".env"
            path.write_text('HERMES_TELEGRAM_API_ID=123\nHERMES_TELEGRAM_API_ID=456\nHERMES_TELEGRAM_API_HASH=' + "a" * 32 + '\n')
            with self.assertRaises(ValueError):
                api_import.read_api(path)

    def test_installs_private_file_and_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "private/api.json"
            configuration = {"apiID": "123", "apiHash": "a" * 32}
            api_import.install(configuration, path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            original = path.read_bytes()
            with self.assertRaises(ValueError):
                api_import.install({"apiID": "456"}, path)
            self.assertEqual(path.read_bytes(), original)

    def test_refuses_destination_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "api.json"
            target = Path(temporary) / "target.json"
            target.write_text("synthetic-preserved")
            path.symlink_to(target)
            with self.assertRaises(ValueError):
                api_import.install({"apiID": "123"}, path)
            self.assertEqual(target.read_text(), "synthetic-preserved")


if __name__ == "__main__":
    unittest.main()
