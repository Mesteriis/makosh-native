#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline exact-source and capture-boundary checks. No source cache required."""
import hashlib
from pathlib import Path
import unittest
from telegram_retention_adaptation import (
    POSTBOX, HISTORY, SOURCE_SHA256, ADAPTED_SHA256, adapt_retention_source, journal_source, _replace,
)
from telegram_selection_adaptation import strip_selection_source
ROOT = Path(__file__).resolve().parent.parent

class RetentionAdaptationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources = {}
        for name in [POSTBOX, HISTORY]:
            path = ROOT / '.local/telegram-engine' / name
            if path.is_symlink():
                raise RuntimeError('Retention fixture symlink refused')
            source = path.read_text()
            cls.sources[name] = strip_selection_source(source) if name == POSTBOX else source

    def testExactHashesAndIdempotency(self):
        for name, source in self.sources.items():
            self.assertIn(hashlib.sha256(source.encode()).hexdigest(), [SOURCE_SHA256[name], ADAPTED_SHA256[name]])
            adapted = adapt_retention_source(name, source)
            self.assertEqual(hashlib.sha256(adapted.encode()).hexdigest(), ADAPTED_SHA256[name])
            self.assertEqual(adapt_retention_source(name, adapted), adapted)
        self.assertIn('public struct MakoshMessageJournalEntry', journal_source())

    def testUnknownAndTamperedSourceFailClosed(self):
        for name, source in self.sources.items():
            for bad in [source + '\n', source.replace('import Foundation', 'import Darwin', 1), 'unknown']:
                with self.assertRaises(ValueError): adapt_retention_source(name, bad)
        with self.assertRaises(ValueError): adapt_retention_source('unknown', '')
        with self.assertRaises(ValueError): _replace('twice twice', 'twice', '')

    def testCentralCapturePrecedesDestructiveMediaRemoval(self):
        adapted = adapt_retention_source(HISTORY, self.sources[HISTORY])
        remove = adapted.split('private func justRemove(')[1].split('func embeddedMediaForIndex')[0]
        self.assertLess(remove.index('makoshJournalCapture(message, removed: true)'), remove.index('removeEmbeddedMedia'))
        update = adapted.split('private func justUpdate(')[1].split('private func justUpdateTimestamp')[0]
        self.assertLess(update.index('makoshJournalCapture(previousMessage, removed: false)'), update.index('removeEmbeddedMedia'))
        self.assertEqual(adapted.count('self.makoshJournalCapture(index:'), 3)
        postbox = adapt_retention_source(POSTBOX, self.sources[POSTBOX])
        self.assertIn('public func makoshArchiveJournal(limit: Int) throws', postbox)
        self.assertIn('public func acknowledgeMakoshArchiveJournal(sequences: [Int64]) throws', postbox)

    def testTableIDsAndNoCacheOrBroadAck(self):
        import re
        source = self.sources[POSTBOX]
        self.assertFalse({9001, 9002} & set(map(int, re.findall(r'tableSpec\((\d+)\)', source))))
        template = journal_source()
        self.assertIn('min(1000, max(0, limit))', template)
        self.assertNotIn('removeRange', template)
        self.assertIn('unique.allSatisfy', template)
        self.assertIn('valueBox.set(Self.metadata', template)
        self.assertNotIn('static var', template)

if __name__ == '__main__': unittest.main()
