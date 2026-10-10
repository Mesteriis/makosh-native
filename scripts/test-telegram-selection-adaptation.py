#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exact composition checks; encrypted cache-range behavior is covered in XCTest."""
import hashlib
from pathlib import Path
import unittest
from telegram_selection_adaptation import (
    POSTBOX, SOURCE_SHA256, ADAPTED_SHA256, adapt_selection_source, strip_selection_source,
)


class SelectionAdaptationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parent.parent / ".local/telegram-engine" / POSTBOX
        if path.is_symlink():
            raise RuntimeError("Selection source fixture symlink refused")
        cls.source = path.read_text()

    def testExactCompositionAndIdempotency(self):
        adapted = adapt_selection_source(self.source)
        self.assertEqual(hashlib.sha256(adapted.encode()).hexdigest(), ADAPTED_SHA256)
        self.assertEqual(adapt_selection_source(adapted), adapted)
        journal = strip_selection_source(adapted)
        self.assertEqual(hashlib.sha256(journal.encode()).hexdigest(), SOURCE_SHA256)
        self.assertEqual(adapt_selection_source(journal), adapted)
        self.assertIn("public func makoshArchiveJournal", journal)

    def testUnknownAndTamperedCompositionFailClosed(self):
        for changed in [self.source + "\n", self.source.replace("limit <= 200", "limit <= 201"), "unknown"]:
            with self.assertRaises(ValueError):
                adapt_selection_source(changed)
            with self.assertRaises(ValueError):
                strip_selection_source(changed)


if __name__ == "__main__":
    unittest.main()
