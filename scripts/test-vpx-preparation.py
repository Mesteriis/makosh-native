#!/usr/bin/env python3
import importlib.util
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("vpx_preparation", ROOT / "scripts/prepare-vpx.py")
prep = importlib.util.module_from_spec(spec); spec.loader.exec_module(prep)

class VPXPreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock = json.loads((ROOT / "Dependencies/VPX.lock.json").read_text())
        archive = ROOT / ".local/vpx-archives" / (cls.lock["archiveSHA256"] + ".tar.gz")
        all_files = prep.archive_files(archive.read_bytes())
        cls.files = {name: all_files[name] for name in cls.lock["sourceFilesSHA256"]}

    def testPreparedPortableDecoderRetainsExactSourcesLegalGrantAndPublicAPI(self):
        result = prep.build_inputs(self.files, self.lock)
        self.assertEqual(result.get("Sources/CVPX/vpx/vpx_decoder.h"), self.files["vpx/vpx_decoder.h"])
        self.assertEqual(result.get("Licenses/LICENSE"), self.files["LICENSE"])
        self.assertEqual(result.get("Licenses/PATENTS"), self.files["PATENTS"])
        self.assertEqual(len([name for name in result if name.endswith(".c")]), 49)
        self.assertIn("Sources/CVPX/vp9_rtcd.h", result)
        self.assertIn("Sources/CVPX/include/CVPX.h", result)
        self.assertIn(".c11", result.get("Package.swift", b"").decode())
        self.assertFalse(any(name.endswith((".sh", ".m", ".mm", ".S", ".asm")) for name in result))

    def testIndependentPreparationReusesOnlyVerifiedOutputOffline(self):
        with tempfile.TemporaryDirectory() as temporary:
            dest=Path(temporary)/"prepared"
            cache=ROOT/".local/vpx-archives"
            prep.prepare(ROOT/"Dependencies/VPX.lock.json", cache, dest)
            self.assertTrue((dest/"Package.swift").is_file())
            if not (dest/"Package.swift").is_file(): return
            first=(dest/"preparation.json").read_bytes()
            with patch("urllib.request.urlopen", side_effect=AssertionError("offline reuse downloaded")):
                prep.prepare(ROOT/"Dependencies/VPX.lock.json", Path(temporary)/"absent-cache", dest)
            self.assertEqual((dest/"preparation.json").read_bytes(), first)

    def testModifiedMissingExtraAndEscapingInputsAreRejected(self):
        for changed in [dict(self.files, **{"LICENSE": b"changed"}),
                        {n: b for n, b in self.files.items() if n != "PATENTS"},
                        dict(self.files, **{"installer.sh": b"exit 0"}),
                        dict(self.files, **{"../escape.h": b"no"})]:
            with self.subTest(count=len(changed)), self.assertRaises((ValueError, RuntimeError)):
                prep.build_inputs(changed, self.lock)
        for key, value in [("revision", "0"*40), ("sourceURL", "https://example.invalid/archive"),
                           ("sources", self.lock["sources"] + ["vp9/encoder/injected.c"])]:
            changed = copy.deepcopy(self.lock); changed[key] = value
            with self.subTest(key=key), self.assertRaises((ValueError, RuntimeError)):
                prep.build_inputs(self.files, changed)

    def testOfflineReuseRefusesTamperedMissingExtraLinkedOrUnmarkedOutput(self):
        for mutation in ["modified", "missing", "extra", "linked", "marker"]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                dest=Path(temporary)/"prepared"
                prep.prepare(ROOT/"Dependencies/VPX.lock.json", ROOT/".local/vpx-archives", dest)
                target=dest/"Sources/CVPX/vpx/vpx_decoder.h"
                if mutation == "modified": target.write_bytes(b"modified")
                elif mutation == "missing": target.unlink()
                elif mutation == "extra": (dest/"extra.h").write_bytes(b"extra")
                elif mutation == "linked": target.unlink(); target.symlink_to(ROOT/"LICENSE")
                else: (dest/"preparation.json").unlink()
                with patch("urllib.request.urlopen", side_effect=AssertionError("must not download")), self.assertRaises((ValueError, RuntimeError)):
                    prep.prepare(ROOT/"Dependencies/VPX.lock.json", Path(temporary)/"absent-cache", dest)

if __name__ == "__main__": unittest.main()
