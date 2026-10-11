#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pinned composition checks; encrypted native behavior is exercised by XCTest."""
import hashlib
from pathlib import Path
import unittest
from telegram_delete_adaptation import (
    DELETE, SOURCE_SHA256, ADAPTED_SHA256, adapt_delete_source, strip_delete_source,
)


class SelectedDeleteAdaptationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parent.parent / ".local/telegram-engine" / DELETE
        if path.is_symlink():
            raise RuntimeError("Selected-delete source fixture symlink refused")
        cls.source = path.read_text()

    def testExactCompositionAndIdempotency(self):
        adapted = adapt_delete_source(self.source)
        self.assertEqual(hashlib.sha256(adapted.encode()).hexdigest(), ADAPTED_SHA256)
        self.assertEqual(adapt_delete_source(adapted), adapted)
        original = strip_delete_source(adapted)
        self.assertEqual(hashlib.sha256(original.encode()).hexdigest(), SOURCE_SHA256)
        self.assertEqual(adapt_delete_source(original), adapted)

    def testUnknownAndTamperedCompositionFailClosed(self):
        for changed in [self.source + "\n", self.source.replace("deleteAllInGroup: false", "deleteAllInGroup: true"), "unknown"]:
            with self.assertRaises(ValueError):
                adapt_delete_source(changed)
            with self.assertRaises(ValueError):
                strip_delete_source(changed)


if __name__ == "__main__":
    unittest.main()
