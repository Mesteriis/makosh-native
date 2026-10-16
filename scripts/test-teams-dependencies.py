#!/usr/bin/env python3
"""Exercise the owned Teams provenance gate without a research checkout."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('teams_verify', ROOT / 'scripts/verify-teams-dependencies.py')
verify_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_module)


class TeamsDependenciesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ['Dependencies/Teams', 'Sources/MakoshTeams']:
            shutil.copytree(ROOT / path, self.root / path)
        for path in ['Dependencies/Teams.lock.json', 'LICENSES/Teams-cli-MIT.txt']:
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, self.root / path)

    def test_offline_independent_provenance(self):
        self.assertEqual(verify_module.verify(self.root), '9c8a72c32369f9d9bd15b793099522a80070a063')

    def test_changed_reviewed_source_rejected(self):
        with (self.root / 'Dependencies/Teams/Reference/graph.rs').open('a') as out:
            out.write('\n// mutation\n')
        with self.assertRaises(ValueError):
            verify_module.verify(self.root)

    def test_changed_license_rejected(self):
        (self.root / 'LICENSES/Teams-cli-MIT.txt').write_text('MIT without attribution')
        with self.assertRaises(ValueError):
            verify_module.verify(self.root)

    def test_runtime_reference_dependency_rejected(self):
        (self.root / 'Sources/MakoshTeams/Unsafe.swift').write_text('let path = ".references/teams-cli/config.json"')
        with self.assertRaises(ValueError):
            verify_module.verify(self.root)

    def test_reference_client_identifier_rejected(self):
        # The public identifier is not a Makosh registration; fixture lives only in temporary test source.
        identifier = verify_module.REFERENCE_CLIENT_ID
        (self.root / 'Sources/MakoshTeams/Unsafe.swift').write_text('let client = "' + identifier + '"')
        with self.assertRaises(ValueError):
            verify_module.verify(self.root)


if __name__ == '__main__':
    unittest.main()
