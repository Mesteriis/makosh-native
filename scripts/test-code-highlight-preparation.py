#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("code_highlight_preparation", ROOT / "scripts/prepare-code-highlight.py")
PREP = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(PREP)


class CodeHighlightPreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock = json.loads((ROOT / "Dependencies/CodeHighlight.lock.json").read_text())
        cls.sources = {}
        for name, pin in cls.lock["dependencies"].items():
            cache = ROOT / (".local/code-highlight-" + name + "-source.git")
            for path, digest in pin["sourceFilesSHA256"].items():
                data = subprocess.check_output(["git", "--no-replace-objects", "--git-dir", str(cache), "show", pin["revision"] + ":" + path])
                if hashlib.sha256(data).hexdigest() != digest: raise RuntimeError("Pinned fixture differs")
                cls.sources[("regex/" if name == "regex" else "") + path] = data

    def testBuildContainsCompletePinnedGrammarAndOnlyPortableCompilationUnits(self):
        result = PREP.build_inputs(self.lock, self.sources)
        self.assertIn("Package.swift", result)
        for name in ["Highlight", "LanguageTree", "SyntaxHighlighter", "TokenList"]:
            self.assertIn("src/" + name + ".cpp", result)
        self.assertEqual(result.get("Provenance/grammars.dat"), self.sources["libprisma/grammars.dat"])
        self.assertFalse(any(path.endswith((".m", ".mm", ".js", ".sh")) for path in result))
        self.assertEqual(result.get("LICENSES/Prisma-MIT.notice"), self.sources["LICENSE"])

    def testOfflineReuseRejectsChangedRecipeAdapterBudgetOrLicense(self):
        for changed in ["scripts/prepare-code-highlight.py", "scripts/telegram_code_highlight_adaptation.py",
                        "Sources/MakoshCodeHighlight/MakoshPrismaBudget.h", "LICENSES/Boost-1.0.notice"]:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for name in ["scripts/prepare-code-highlight.py", "scripts/telegram_code_highlight_adaptation.py",
                             "Sources/MakoshCodeHighlight/MakoshPrismaBudget.h", "LICENSES/Boost-1.0.notice",
                             "Dependencies/CodeHighlight.lock.json"]:
                    target=root/name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes((ROOT/name).read_bytes())
                with patch.object(PREP, "ROOT", root), patch.object(PREP, "DEST", root/".local/prepared"), \
                     patch.object(PREP, "LOCK_PATH", root/"Dependencies/CodeHighlight.lock.json"), \
                     patch.object(PREP, "RECIPE", root/"scripts/prepare-code-highlight.py", create=True), \
                     patch.object(PREP, "pinned_sources", return_value=self.sources):
                    PREP.prepare()
                    PREP.prepare()
                    path=root/changed; path.write_bytes(path.read_bytes()+b"\n/* reviewed input changed */\n")
                    with self.assertRaises((ValueError, RuntimeError)):
                        PREP.prepare()

    def testTamperedMissingExtraAndUnsafeInputsFailBeforeProducingPackage(self):
        for changed in [dict(self.sources, **{"libprisma/grammars.dat": b"tampered"}),
                        {k: v for k, v in self.sources.items() if k != "LICENSE"},
                        dict(self.sources, **{"libprisma/installer.sh": b"exit 0"}),
                        dict(self.sources, **{"../escape": b"no"})]:
            with self.subTest(changed=len(changed)), self.assertRaises((ValueError, RuntimeError)):
                PREP.build_inputs(self.lock, changed)


if __name__ == "__main__":
    unittest.main()
