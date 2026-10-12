#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("rlottie_preparation", ROOT / "scripts/prepare-rlottie.py")
prep = importlib.util.module_from_spec(spec); spec.loader.exec_module(prep)


class RLottiePreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock = json.loads((ROOT / "Dependencies/RLottie.lock.json").read_text())
        archive = ROOT / ".local/rlottie-archives" / (cls.lock["archiveSHA256"] + ".tar.gz")
        all_files = prep.helpers.archive_files(archive.read_bytes(), cls.lock)
        cls.files = {name: all_files[name] for name in cls.lock["sourceFilesSHA256"]}

    def testPortableClosureIncludesReviewedNoticesAndDisablesExternalImagesAndThreads(self):
        result = prep.build_inputs(self.files, self.lock)
        self.assertEqual(result.get("Sources/CRLottie/inc/rlottie.h"), self.files["inc/rlottie.h"])
        self.assertEqual(result.get("Licenses/COPYING.LGPL"), self.files["licenses/COPYING.LGPL"])
        manifest = result.get("Package.swift", b"").decode()
        for flag in ["LOTTIE_IMAGE_MODULE_DISABLED", "LOTTIE_THREAD_SAFE", "LOTTIE_DISABLE_ARM_NEON"]:
            self.assertIn(flag, manifest)
        self.assertIn('pixman_region_selfcheck(x)', manifest)
        for flag in ["LOTTIE_THREAD_SUPPORT", "LOTTIE_LOGGING_SUPPORT", "LOTTIE_CACHE_SUPPORT"]:
            self.assertNotIn(flag, manifest)
        self.assertFalse(any(path.endswith((".m", ".mm", ".js", ".sh")) for path in result))
        self.assertEqual(len([name for name in result if name.endswith(".cpp")]), 31)

    def testSourceDriftMissingExtraAndEscapingPathsFailBeforePackageProduction(self):
        for files in [dict(self.files, **{"inc/rlottie.h": b"changed"}),
                      {n: b for n, b in self.files.items() if n != "licenses/COPYING.FTL"},
                      dict(self.files, **{"src/install.sh": b"exit 0"}),
                      dict(self.files, **{"../escape": b"no"})]:
            with self.subTest(count=len(files)), self.assertRaises((ValueError, RuntimeError)):
                prep.build_inputs(files, self.lock)

    def testUnreviewedArchiveOriginAndSourceUnitAreRejected(self):
        for change in ["origin", "unit"]:
            lock = copy.deepcopy(self.lock)
            if change == "origin": lock["sourceURL"] = "https://example.invalid/renderer.tar.gz"
            else: lock["sources"].append("src/install.cpp")
            with self.subTest(change=change), self.assertRaises((ValueError, RuntimeError)):
                prep.build_inputs(self.files, lock)


if __name__ == "__main__":
    unittest.main()
