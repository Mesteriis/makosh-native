#!/usr/bin/env python3
"""Verify canonical native secret bridges against disposable warm-cache records."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from telegram_secret_chat_adaptation import secret_chat_helper_source
from telegram_preparation_test_support import write_secret_native_fixture

spec = importlib.util.spec_from_file_location('preparation', Path(__file__).with_name('prepare-telegram.py'))
preparation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparation)

class SecretPreparationTests(unittest.TestCase):
    def fixture(self, root):
        for name, source in [('MakoshRemotePeerSearch.swift', preparation.remote_peer_helper_source()),
                             ('MakoshAvatarEditing.swift', preparation.avatar_helper_source()),
                             ('MakoshGroupMembership.swift', preparation.group_membership_helper_source()),
                             ('MakoshSecretChat.swift', secret_chat_helper_source())]:
            path = root / 'submodules/TelegramCore/Sources/TelegramEngine/Peers' / name
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text(source)
        write_secret_native_fixture(root, preparation)
        self.marker(root)
    def marker(self, root):
        (root / 'preparation.json').write_text(json.dumps(dict(source_sha=preparation.SHA, source_tree=preparation.TREE,
            source_url=preparation.URL, recipe=preparation.RECIPE, prepared_files=preparation.prepared_files(root))))
    def test_valid_secret_helper_reuses_cache_without_fetch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            with patch.object(preparation, 'DEST', root), patch.object(preparation, 'prepare_source', side_effect=AssertionError('fetch forbidden')):
                preparation.main()
    def test_forged_consistent_changed_secret_helper_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            (root / 'submodules/TelegramCore/Sources/TelegramEngine/Peers/MakoshSecretChat.swift').write_text('// forged')
            self.marker(root)
            with patch.object(preparation, 'DEST', root), self.assertRaisesRegex(RuntimeError, 'secret helper'):
                preparation.verify_prepared()
    def test_forged_consistent_missing_secret_helper_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            (root / 'submodules/TelegramCore/Sources/TelegramEngine/Peers/MakoshSecretChat.swift').unlink()
            self.marker(root)
            with patch.object(preparation, 'DEST', root), self.assertRaisesRegex(RuntimeError, 'secret helper'):
                preparation.verify_prepared()
    def test_forged_consistent_native_crypto_source_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            path = root / 'submodules/TelegramCore/Sources/TelegramEngine/Peers/CreateSecretChat.swift'
            path.write_text(path.read_text() + '\n// forged entropy implementation\n')
            self.marker(root)
            with patch.object(preparation, 'DEST', root), self.assertRaisesRegex(RuntimeError, 'secret native source'):
                preparation.verify_prepared()
    def test_forged_consistent_missing_native_source_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.fixture(root)
            (root / 'submodules/TelegramCore/Sources/State/ManagedSecretChatOutgoingOperations.swift').unlink()
            self.marker(root)
            with patch.object(preparation, 'DEST', root), self.assertRaisesRegex(RuntimeError, 'secret native source'):
                preparation.verify_prepared()

if __name__ == '__main__': unittest.main()
