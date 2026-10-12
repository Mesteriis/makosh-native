#!/usr/bin/env python3
import importlib.util
import io
import gzip
import tarfile
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
        archive = ROOT / ".local/vpx-archives" / (cls.lock["archiveContentSHA256"] + ".tar.gz")
        if not archive.exists():
            archive = archive.with_name(cls.lock["archiveSHA256"] + ".tar.gz")
        all_files = prep.archive_files(archive.read_bytes())
        cls.all_files = all_files
        cls.files = {name: all_files[name] for name in cls.lock["sourceFilesSHA256"]}

    def repacked(self, files=None, timestamp=1):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            for name, data in sorted((self.all_files if files is None else files).items()):
                info = tarfile.TarInfo(name); info.size = len(data); info.mtime = timestamp
                archive.addfile(info, io.BytesIO(data))
        return stream.getvalue()

    def testRegeneratedArchiveMetadataCannotRejectExactReviewedSourceContent(self):
        # Gitiles assigns changing tar timestamps to an immutable source revision.
        for timestamp in [1, 2_000_000_000]:
            try: actual = prep.archive_files(self.repacked(timestamp=timestamp))
            except ValueError as error: self.fail("Exact reviewed source rejected after tar metadata regeneration: " + str(error))
            self.assertEqual(actual, self.all_files)

    def testRegeneratedArchiveStillRejectsChangedUncompiledMissingAndExtraFiles(self):
        name = next(n for n in self.all_files if n not in self.files)
        candidates = [dict(self.all_files, **{name: self.all_files[name] + b"changed"}),
            {n: b for n,b in self.all_files.items() if n != name},
            dict(self.all_files, **{"unexpected-source.txt": b"extra"})]
        for candidate in candidates:
            with self.subTest(count=len(candidate)), self.assertRaises(ValueError):
                prep.archive_files(self.repacked(candidate))

    def testOversizedGzipExpansionIsRejectedBeforeTarMetadataParsing(self):
        bomb = gzip.compress(b"0" * (64 * 1024 * 1024 + 1))
        with patch.object(tarfile, "open", side_effect=AssertionError("parsed unbounded tar")), self.assertRaisesRegex(ValueError, "expanded bounds"):
            prep.archive_files(bomb)

    def testColdDownloadedRegeneratedArchiveProducesReviewedPackageAndReusesOffline(self):
        class Response(io.BytesIO):
            url = prep.URL
        with tempfile.TemporaryDirectory() as temporary:
            dest = Path(temporary) / "prepared"
            with patch("urllib.request.urlopen", return_value=Response(self.repacked())):
                try: prep.prepare(ROOT / "Dependencies/VPX.lock.json", Path(temporary) / "cache", dest)
                except ValueError as error: self.fail("Fresh valid source preparation failed: " + str(error))
            self.assertEqual((dest / "Sources/CVPX/vpx/vpx_decoder.h").read_bytes(), self.files["vpx/vpx_decoder.h"])
            self.assertEqual((dest / "Licenses/PATENTS").read_bytes(), self.files["PATENTS"])
            with patch("urllib.request.urlopen", side_effect=AssertionError("offline reuse downloaded")):
                prep.prepare(ROOT / "Dependencies/VPX.lock.json", Path(temporary) / "absent-cache", dest)

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
