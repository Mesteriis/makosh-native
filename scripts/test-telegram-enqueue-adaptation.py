#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline source pin checks; encrypted receipt/reopen tests live in XCTest."""
import hashlib
from pathlib import Path
import unittest
from telegram_enqueue_adaptation import ENQUEUE, SOURCE_SHA256, ADAPTED_SHA256, adapt_enqueue_source


class EnqueueAdaptationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parent.parent / ".local/telegram-engine" / ENQUEUE
        if path.is_symlink():
            raise RuntimeError("Enqueue source fixture symlink refused")
        cls.source = path.read_text()

    def testExactPinAndIdempotency(self):
        self.assertIn(hashlib.sha256(self.source.encode()).hexdigest(), [SOURCE_SHA256, ADAPTED_SHA256])
        adapted = adapt_enqueue_source(self.source)
        self.assertEqual(hashlib.sha256(adapted.encode()).hexdigest(), ADAPTED_SHA256)
        self.assertEqual(adapt_enqueue_source(adapted), adapted)

    def testUnknownAndTamperedSourceFailClosed(self):
        for changed in [self.source + "\n", self.source.replace("import Foundation", "import Darwin", 1), "unknown"]:
            with self.assertRaises(ValueError):
                adapt_enqueue_source(changed)


if __name__ == "__main__":
    unittest.main()
