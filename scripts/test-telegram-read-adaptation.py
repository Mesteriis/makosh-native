#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline pin/tamper checks; actual read/reopen behavior is tested in Postbox."""
import hashlib
from pathlib import Path
import unittest
from telegram_read_adaptation import READ_SYNC, SOURCE_SHA256, ADAPTED_SHA256, adapt_read_source


class ReadAdaptationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parent.parent / ".local/telegram-engine" / READ_SYNC
        if path.is_symlink():
            raise RuntimeError("Read synchronization fixture symlink refused")
        cls.source = path.read_text()

    def testExactPinAndIdempotency(self):
        self.assertIn(hashlib.sha256(self.source.encode()).hexdigest(), [SOURCE_SHA256, ADAPTED_SHA256])
        adapted = adapt_read_source(self.source)
        self.assertEqual(hashlib.sha256(adapted.encode()).hexdigest(), ADAPTED_SHA256)
        self.assertEqual(adapt_read_source(adapted), adapted)

    def testUnknownAndTamperedSourceFailClosed(self):
        for changed in [self.source + "\n", self.source.replace("import Foundation", "import Darwin", 1), "unknown"]:
            with self.assertRaises(ValueError):
                adapt_read_source(changed)


if __name__ == "__main__":
    unittest.main()
