#!/usr/bin/env python3
"""Verify that only the two pinned transaction helpers change visibility."""
import hashlib
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent / ".local/telegram-engine"
FIXTURES = [
    ("submodules/TelegramCore/Sources/SyncCore/SyncCore_SynchronizeableChatInputState.swift",
     "func _internal_updateChatInputState(", "245c506f862846061a5c40bdd6b5f7c64ee094773605f97083fe97a81871669b"),
    ("submodules/TelegramCore/Sources/State/SynchronizeChatInputStateOperation.swift",
     "func addSynchronizeChatInputStateOperation(", "b9862d39d04bba8702e9d1f6b175163e3833160711ffcd1292c72e509495b817"),
]


class DraftAdaptationTests(unittest.TestCase):
    def testActualStoredInputChangeInvalidatesLiveViewWithSameTimestamp(self):
        path = ROOT / "submodules/Postbox/Sources/PeerChatInterfaceStateTable.swift"
        source = path.read_text()
        self.assertIn("currentState.overrideChatTimestamp != state.overrideChatTimestamp || currentState.data != state.data", source)

    def testNativeTransactionHelpersArePublicWithUnchangedBodies(self):
        for path, declaration, original_digest in FIXTURES:
            with self.subTest(path=path):
                source = (ROOT / path).read_text()
                self.assertEqual(source.count("public " + declaration), 1)
                original = source.replace("public " + declaration, declaration)
                self.assertEqual(hashlib.sha256(original.encode()).hexdigest(), original_digest)


if __name__ == "__main__":
    unittest.main()
