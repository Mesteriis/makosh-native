#!/usr/bin/env python3
"""Exercise the offline Telemost provenance verifier against independent fixtures."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("telemost_dependencies", ROOT / "scripts/verify-telemost-dependencies.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProvenanceTests(unittest.TestCase):
    def fixture(self, root):
        lock = {
            "source": {"url": "https://github.com/Bezooom/yandex-messenger-native", "revision": "f0a237c6016088a8e3816dde2e56c06e4a47c5eb", "license": "MIT", "role": "research-only"},
            "runtime": {"implementation": "native-swift-official-rest", "externalDependencies": []},
        }
        (root / "Dependencies").mkdir()
        (root / "Sources/MakoshTelemost").mkdir(parents=True)
        (root / "Dependencies/Telemost.lock.json").write_text(json.dumps(lock))
        return lock

    def test_valid_without_research_clone(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            self.fixture(root)
            self.assertEqual(module.verify(root), "f0a237c6016088a8e3816dde2e56c06e4a47c5eb")

    def test_reject_unreviewed_pin_or_runtime_dependency(self):
        for field in ("revision", "dependencies"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as name:
                root = Path(name); lock = self.fixture(root)
                if field == "revision": lock["source"]["revision"] = "0" * 40
                else: lock["runtime"]["externalDependencies"] = ["gstreamer"]
                (root / "Dependencies/Telemost.lock.json").write_text(json.dumps(lock))
                with self.assertRaises(ValueError): module.verify(root)

    def test_runtime_cannot_depend_on_reference_folder(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); self.fixture(root)
            (root / "Sources/MakoshTelemost/Bad.swift").write_text('let path = ".references/yandex-messenger-native"')
            with self.assertRaises(ValueError): module.verify(root)


if __name__ == "__main__":
    unittest.main()
