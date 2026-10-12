#!/usr/bin/env python3
"""Verify exact native adaptation composition and fail-closed source drift."""
import hashlib
import os
import subprocess
import tempfile
from pathlib import Path
import unittest
from telegram_code_highlight_adaptation import SOURCE_SHA256, ADAPTED_SHA256, adapt_code_highlight_source


class CodeHighlightAdaptationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(os.environ.get("MAKOSH_HIGHLIGHT_TEST_SOURCE_ROOT",
            Path(__file__).resolve().parent.parent / ".local/code-highlight-engine"))

    def fixture(self, path):
        relative = "src/" + path.removeprefix("libprisma/") if path.startswith("libprisma/") else path
        source = self.root / relative
        if source.is_symlink():
            raise RuntimeError("Native highlighter fixture symlink refused")
        return source.read_bytes()

    def testPinnedInputProducesReviewedIdempotentAdaptation(self):
        for path in SOURCE_SHA256:
            with self.subTest(path=path):
                source = self.fixture(path)
                try:
                    adapted = adapt_code_highlight_source(path, source)
                except ValueError:
                    self.fail("The reviewed pinned input must be accepted for adaptation")
                self.assertEqual(hashlib.sha256(adapted).hexdigest(), ADAPTED_SHA256[path])
                self.assertEqual(adapt_code_highlight_source(path, adapted), adapted)
                self.assertNotEqual(hashlib.sha256(adapted).hexdigest(), SOURCE_SHA256[path])

    # Deleting the constructor's sentinel guard leaks when its second allocation fails.
    def testNativeTokenListAllocationFailureReleasesAlreadyOwnedSentinel(self):
        root = Path(__file__).resolve().parent.parent
        fixture = root / "Tests/MakoshCodeHighlightFixtures/TokenListAllocationFailure.cpp"
        with tempfile.TemporaryDirectory(prefix="makosh-highlight-allocation-") as temp:
            executable = Path(temp) / "allocation-failure"
            compiled = subprocess.run(["clang++", "-std=c++17", "-I", str(self.root / "src"),
                "-I", str(root / "Sources/MakoshCodeHighlight"), str(self.root / "src/TokenList.cpp"),
                str(fixture), "-o", str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(executed.returncode, 0, executed.stderr)

    def testTamperedAndUnknownInputsCannotPublishAdaptation(self):
        for path in SOURCE_SHA256:
            source = self.fixture(path)
            for changed in [source + b"\n", source[:-1], b"unknown"]:
                with self.subTest(path=path), self.assertRaises(ValueError):
                    adapt_code_highlight_source(path, changed)
        with self.assertRaises(ValueError):
            adapt_code_highlight_source("../outside", b"unknown")


if __name__ == "__main__":
    unittest.main()
