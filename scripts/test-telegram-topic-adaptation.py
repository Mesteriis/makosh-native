#!/usr/bin/env python3
"""Check prepared topic adaptations, inverse provenance and tamper rejection."""
import hashlib
from pathlib import Path
import unittest
from telegram_topic_adaptation import TOPIC_SOURCES, adapt_topic_source

ROOT = Path(__file__).resolve().parent.parent / ".local/telegram-engine"


class TopicAdaptationTests(unittest.TestCase):
    def testPreparedSourcesAndIdempotence(self):
        for path, (_, adapted, _, _) in TOPIC_SOURCES.items():
            source = (ROOT / path).read_text()
            self.assertEqual(hashlib.sha256(source.encode()).hexdigest(), adapted)
            self.assertEqual(adapt_topic_source(path, source), source)

    def testInversePreservesExactPinnedSource(self):
        for path, (original, _, replacements, suffix) in TOPIC_SOURCES.items():
            source = (ROOT / path).read_text()
            if suffix:
                self.assertTrue(source.endswith(suffix))
                source = source[:-len(suffix)]
            for old, new, count in reversed(replacements):
                self.assertEqual(source.count(new), count)
                source = source.replace(new, old)
            self.assertEqual(hashlib.sha256(source.encode()).hexdigest(), original)
            self.assertEqual(adapt_topic_source(path, source), (ROOT / path).read_text())

    def testUnknownSourceIsRejected(self):
        for path in TOPIC_SOURCES:
            with self.assertRaises(ValueError):
                adapt_topic_source(path, (ROOT / path).read_text() + "\nchanged\n")


if __name__ == "__main__":
    unittest.main()
