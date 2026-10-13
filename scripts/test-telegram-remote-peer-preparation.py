#!/usr/bin/env python3
"""Execute cached-preparation checks against disposable source/marker fixtures."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("remote_search_preparation", Path(__file__).with_name("prepare-telegram.py"))
preparation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparation)


class RemotePeerPreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        previous = preparation.DEST
        self.addCleanup(setattr, preparation, "DEST", previous)
        preparation.DEST = self.root
        self.helper = self.root / "submodules/TelegramCore/Sources/TelegramEngine/Peers/MakoshRemotePeerSearch.swift"
        self.helper.parent.mkdir(parents=True)
        self.helper.write_text(preparation.remote_peer_helper_source())
        self.helper.with_name("MakoshAvatarEditing.swift").write_text(preparation.avatar_helper_source())
        self.helper.with_name("MakoshGroupMembership.swift").write_text(preparation.group_membership_helper_source())
        self.marker()
        self.assertTrue(preparation.verify_prepared())

    def marker(self):
        files = {str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in self.root.rglob("*") if p.is_file() and p.name != "preparation.json"}
        (self.root / "preparation.json").write_text(json.dumps({"source_sha": preparation.SHA,
            "source_tree": preparation.TREE, "source_url": preparation.URL,
            "recipe": preparation.RECIPE, "prepared_files": files}))

    def test_identical_cached_helper_is_reused_without_source_fetch(self):
        self.assertTrue(preparation.verify_prepared())

    def test_changed_helper_is_refused_even_when_marker_hash_matches(self):
        self.helper.write_text("// replacement source with a consistent marker\n")
        self.marker()
        with self.assertRaises(RuntimeError):
            preparation.verify_prepared()

    def test_omitted_helper_is_refused_even_when_marker_file_set_matches(self):
        self.helper.unlink()
        self.marker()
        with self.assertRaises(RuntimeError):
            preparation.verify_prepared()


if __name__ == "__main__":
    unittest.main()
