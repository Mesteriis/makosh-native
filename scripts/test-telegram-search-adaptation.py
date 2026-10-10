#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline prepared-source checks; explicitly opt into raw bare-cache checks via env."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import unittest
from telegram_search_adaptation import adapt_search_source, SOURCE_SHA256, ADAPTED_SHA256, _replace

ROOT = Path(__file__).resolve().parent.parent
RAW_SOURCE = os.environ.get("MAKOSH_TEST_TELEGRAM_SOURCE")
PREPARED = ROOT / ".local/telegram-engine/submodules/TelegramCore/Sources/TelegramEngine/Messages/SearchMessages.swift"
REVISION = "a24bbe45f9861f736a79916a50898512f751e0dc"
PATH = "submodules/TelegramCore/Sources/TelegramEngine/Messages/SearchMessages.swift"


class SearchAdaptationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = None
        if RAW_SOURCE:
            source = Path(RAW_SOURCE)
            def git(*args):
                return subprocess.check_output(["git", "--no-replace-objects", "--git-dir", str(source), *args], text=True)
            if source.is_symlink() or git("rev-parse", "--is-bare-repository").strip() != "true":
                raise RuntimeError("A separate bare source cache is required")
            cls.source = git("show", f"{REVISION}:{PATH}")
            cls.adapted = adapt_search_source(cls.source)
        else:
            if PREPARED.is_symlink():
                raise RuntimeError("Prepared search source symlinks are refused")
            cls.adapted = PREPARED.read_text()
            if hashlib.sha256(cls.adapted.encode()).hexdigest() != ADAPTED_SHA256:
                raise RuntimeError("Run preparation before checking adapted Telegram search source")

    def testPinnedDigestAndIdempotency(self):
        if self.source is not None:
            self.assertEqual(hashlib.sha256(self.source.encode()).hexdigest(), SOURCE_SHA256)
        self.assertEqual(hashlib.sha256(self.adapted.encode()).hexdigest(), ADAPTED_SHA256)
        self.assertEqual(adapt_search_source(self.adapted), self.adapted)

    def testDriftAndTamperingFailClosed(self):
        for text in (self.adapted + "\n", "unknown source",
                     self.adapted.replace("searchFailed: true", "searchFailed: false")):
            with self.assertRaises(ValueError):
                adapt_search_source(text)
        for text in ("", "anchor anchor"):
            with self.assertRaises(ValueError):
                _replace(text, "anchor", "replacement")

    def testOnlyMainSearchCatchBoundariesChange(self):
        marker = "func _internal_searchHashtagPosts("
        suffix = self.adapted.split(marker)[1]
        self.assertEqual(hashlib.sha256(suffix.encode()).hexdigest(),
            "4288d61fcd1ad90be5f95c06f55dc6ef25bc1e4836ddde5319a5b716600c47ee")
        if self.source is not None:
            self.assertEqual(self.source.split(marker)[1], suffix)
        body = self.adapted.split("func _internal_searchMessages(")[1].split(marker)[0]
        self.assertEqual(body.count("|> `catch`"), 4)
        self.assertEqual(body.count("return .single(.failed)"), 3)
        self.assertEqual(body.count("return .single((.failed, .skipped))"), 3)
        self.assertEqual(body.count(".single(.skipped)"), 6)
        self.assertIn("makoshSearchFailure(previous: state, main: result, additional: additionalResult)", body)
        self.assertNotIn("map(Optional.init)", body)
        self.assertNotIn("Api.messages.Messages?", body)
        # Saved-reaction and secret local early-return paths remain normal.
        adapted_local = body.split("    let remoteSearchResult:")[0]
        self.assertEqual(hashlib.sha256(adapted_local.encode()).hexdigest(),
            "60c7e40eaa8aaa7415f639f8e8a92cbfd15139378dc4b42ca043f9fd4fe92b8d")
        if self.source is not None:
            original_local = self.source.split("func _internal_searchMessages(")[1].split("    let remoteSearchResult:")[0]
            self.assertEqual(original_local, adapted_local)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
