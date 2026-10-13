#!/usr/bin/env python3
"""Canonical avatar helper validation, with no reference checkout or source fetch."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('preparation', Path(__file__).with_name('prepare-telegram.py'))
preparation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparation)

class AvatarPreparationTests(unittest.TestCase):
    def fixture(self, root):
        for name, source in [('MakoshRemotePeerSearch.swift', preparation.remote_peer_helper_source()),
                             ('MakoshAvatarEditing.swift', preparation.avatar_helper_source()),
                             ('MakoshGroupMembership.swift', preparation.group_membership_helper_source())]:
            path = root / 'submodules/TelegramCore/Sources/TelegramEngine/Peers' / name
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text(source)
        self.mark(root)
    def mark(self, root):
        (root/'preparation.json').write_text(json.dumps(dict(source_sha=preparation.SHA, source_tree=preparation.TREE,
            source_url=preparation.URL, recipe=preparation.RECIPE, prepared_files=preparation.prepared_files(root))))
    def test_valid_canonical_avatar_helper_is_offline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); self.fixture(root)
            with patch.object(preparation,'DEST',root), patch.object(preparation,'prepare_source',side_effect=AssertionError('fetch forbidden')):
                preparation.main()
    def test_forged_consistent_changed_avatar_helper_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); self.fixture(root)
            (root/'submodules/TelegramCore/Sources/TelegramEngine/Peers/MakoshAvatarEditing.swift').write_text('// changed')
            self.mark(root)
            with patch.object(preparation,'DEST',root), self.assertRaisesRegex(RuntimeError,'avatar helper'):
                preparation.verify_prepared()
    def test_forged_consistent_missing_avatar_helper_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); self.fixture(root)
            (root/'submodules/TelegramCore/Sources/TelegramEngine/Peers/MakoshAvatarEditing.swift').unlink()
            self.mark(root)
            with patch.object(preparation,'DEST',root), self.assertRaisesRegex(RuntimeError,'avatar helper'):
                preparation.verify_prepared()

if __name__=='__main__': unittest.main()
