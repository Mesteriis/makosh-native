#!/usr/bin/env python3
"""Offline regressions for committed-source extraction and cache integrity."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from telegram_preparation_test_support import write_secret_native_fixture

spec = importlib.util.spec_from_file_location("preparation", Path(__file__).with_name("prepare-telegram.py"))
preparation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparation)
api_spec = importlib.util.spec_from_file_location("api_import", Path(__file__).with_name("import-telegram-api.py"))
api_import = importlib.util.module_from_spec(api_spec)
api_spec.loader.exec_module(api_import)


class PreparationTests(unittest.TestCase):
    def test_two_step_adaptation_refuses_unreviewed_upstream_context(self):
        with self.assertRaises(RuntimeError):
            preparation.adapt_two_step_source("// synthetic changed upstream implementation")

    def prepared_fixture(self, root):
        destination = root / "engine"
        destination.mkdir()
        (destination / "One.swift").write_text("// synthetic\n")
        helper = destination / "submodules/TelegramCore/Sources/TelegramEngine/Peers/MakoshRemotePeerSearch.swift"
        helper.parent.mkdir(parents=True)
        helper.write_text(preparation.remote_peer_helper_source())
        helper.with_name("MakoshAvatarEditing.swift").write_text(preparation.avatar_helper_source())
        helper.with_name("MakoshGroupMembership.swift").write_text(preparation.group_membership_helper_source())
        helper.with_name("MakoshSecretChat.swift").write_text(preparation.secret_chat_helper_source())
        write_secret_native_fixture(destination, preparation)
        record = {"source_sha": preparation.SHA, "source_tree": preparation.TREE,
                  "source_url": preparation.URL, "recipe": preparation.RECIPE,
                  "prepared_files": preparation.prepared_files(destination)}
        (destination / "preparation.json").write_text(json.dumps(record))
        return destination, record

    def test_warm_preparation_needs_neither_source_nor_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination, _ = self.prepared_fixture(root)
            source = root / "missing-source.git"
            with patch.object(preparation, "DEST", destination), patch.object(preparation, "SOURCE", source), \
                 patch.object(preparation, "prepare_source", side_effect=AssertionError("must not fetch")):
                preparation.main()
            self.assertFalse(source.exists())
            self.assertFalse((root / ".references").exists())

    def test_changed_prepared_input_fails_before_source_fetch(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination, _ = self.prepared_fixture(Path(temporary))
            (destination / "One.swift").write_text("changed")
            with patch.object(preparation, "DEST", destination), \
                 patch.object(preparation, "prepare_source", side_effect=AssertionError("must not fetch")), \
                 self.assertRaisesRegex(RuntimeError, "file set or content changed"):
                preparation.main()

    def test_prepared_metadata_must_match_complete_pin(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination, record = self.prepared_fixture(Path(temporary))
            for key in ("source_sha", "source_tree", "source_url", "recipe"):
                changed = dict(record, **{key: "wrong"})
                (destination / "preparation.json").write_text(json.dumps(changed))
                with self.subTest(key=key), patch.object(preparation, "DEST", destination), \
                     self.assertRaisesRegex(RuntimeError, "another pin or recipe"):
                    preparation.verify_prepared()

    def source_fixture(self, root):
        source = root / "upstream"
        source.mkdir()
        def git(*args):
            return subprocess.check_output(["git", "-C", str(source), *args], stderr=subprocess.DEVNULL).decode().strip()
        git("init")
        (source / "Tracked.swift").write_text("// committed synthetic source\n")
        git("add", "Tracked.swift")
        git("-c", "user.name=Preparation Test", "-c", "user.email=synthetic@example.invalid", "commit", "-m", "fixture")
        return source, git("rev-parse", "HEAD"), git("rev-parse", "HEAD^{tree}")

    def test_cold_source_fetch_is_separate_bare_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            upstream, revision, tree = self.source_fixture(root)
            cache = root / "cache/source.git"
            with patch.object(preparation, "SOURCE", cache), patch.object(preparation, "URL", str(upstream)), \
                 patch.object(preparation, "SHA", revision), patch.object(preparation, "TREE", tree):
                preparation.prepare_source()
                self.assertEqual(preparation.run(*preparation.source_git("rev-parse", "--is-bare-repository")), "true")
                self.assertEqual(preparation.run(*preparation.source_git("show", f"{revision}:Tracked.swift")),
                                 "// committed synthetic source")
                with patch.object(preparation, "run", wraps=preparation.run) as calls:
                    preparation.prepare_source()
                self.assertFalse(any("fetch" in call.args for call in calls.call_args_list))
            self.assertFalse((cache / "Tracked.swift").exists())
            self.assertFalse((root / ".references").exists())

    def test_wrong_source_tree_never_publishes_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            upstream, revision, _ = self.source_fixture(root)
            cache = root / "cache/source.git"
            with patch.object(preparation, "SOURCE", cache), patch.object(preparation, "URL", str(upstream)), \
                 patch.object(preparation, "SHA", revision), patch.object(preparation, "TREE", "0" * 40), \
                 self.assertRaisesRegex(RuntimeError, "tree differs"):
                preparation.prepare_source()
            self.assertFalse(cache.exists())
            self.assertEqual(list(cache.parent.iterdir()), [])

    def test_source_cache_symlink_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "preserved"
            target.mkdir()
            cache = root / "source.git"
            cache.symlink_to(target, target_is_directory=True)
            with patch.object(preparation, "SOURCE", cache), self.assertRaisesRegex(RuntimeError, "symlinks"):
                preparation.prepare_source()
            self.assertEqual(list(target.iterdir()), [])

    def test_source_replacement_refs_cannot_override_pin(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            upstream, revision, tree = self.source_fixture(root)
            cache = root / "cache/source.git"
            with patch.object(preparation, "SOURCE", cache), patch.object(preparation, "URL", str(upstream)), \
                 patch.object(preparation, "SHA", revision), patch.object(preparation, "TREE", tree):
                preparation.prepare_source()
                (upstream / "Tracked.swift").write_text("// replacement must not enter build\n")
                subprocess.run(["git", "-C", str(upstream), "-c", "user.name=Preparation Test",
                                "-c", "user.email=synthetic@example.invalid", "commit", "-am", "replacement"],
                               check=True, stdout=subprocess.DEVNULL)
                replacement = preparation.run("git", "-C", str(upstream), "rev-parse", "HEAD")
                preparation.run(*preparation.source_git("fetch", "--quiet", str(upstream), replacement))
                preparation.run(*preparation.source_git("replace", revision, replacement))
                preparation.verify_source(cache)
                self.assertEqual(preparation.run(*preparation.source_git("show", f"{revision}:Tracked.swift")),
                                 "// committed synthetic source")

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
