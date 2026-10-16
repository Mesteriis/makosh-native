#!/usr/bin/env python3
"""Isolation and executable identity of the Teams QA launcher; no account/device access."""
import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("teams_qa", ROOT / "scripts/run-teams-qa.py")
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)

class TeamsQATests(unittest.TestCase):
    def testConfigurationCannotRebindApplicationOrArchiveToProduction(self):
        original = {"connectionString": "postgresql://synthetic@127.0.0.1/test", "schema": "makosh", "archiveSchema": "makosh_archive"}
        value = qa.isolated_configuration(original, "abc123")
        self.assertTrue(value["schema"].startswith("qa_teams_"))
        self.assertTrue(value["archiveSchema"].startswith("qa_teams_"))
        self.assertNotEqual(value["schema"], value["archiveSchema"])
        self.assertEqual(original["schema"], "makosh")
        with self.assertRaises(ValueError): qa.isolated_configuration({"connectionString": "postgresql://synthetic@example.invalid/db"}, "abc123")
        with self.assertRaises(ValueError): qa.isolated_configuration(original, '";DROP SCHEMA x')
    def testNativeKeywordConfigurationKeepsQuotedValuesAndPinsLocalAddress(self):
        original = {"connectionString": "host=127.0.0.1 dbname=qa user=synthetic password='owned test \\\\ value' connect_timeout=5"}
        value = qa.isolated_configuration(original, "abc123")
        self.assertEqual(qa.connection_options(value["connectionString"])["hostaddr"], "127.0.0.1")
        self.assertEqual(qa.connection_options(value["connectionString"])["password"], qa.connection_options(original["connectionString"])["password"])
        with self.assertRaises(ValueError): qa.isolated_configuration({"connectionString": "host=127.0.0.1 hostaddr=203.0.113.1"}, "abc123")
    def testBundleRequiresTeamsModeAndHasSeparateIdentity(self):
        original = {"CFBundleIdentifier": "org.makosh.desktop", "CFBundleExecutable": "Makosh"}
        value = qa.qa_info(original)
        self.assertEqual(value["CFBundleIdentifier"], "org.makosh.teams.qa")
        self.assertTrue(value["MakoshRequiresSyntheticConfiguration"])
        self.assertEqual(value["MakoshSyntheticService"], "teams")
        self.assertEqual(original["CFBundleIdentifier"], "org.makosh.desktop")
        with self.assertRaises(ValueError): qa.qa_info({"CFBundleIdentifier": "unrelated"})
    def testResigningRetainsExactARM64ExecutableText(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / "fixture.c"; binary = root / "fixture"
            source.write_text("int main(void){return 0;}\n")
            subprocess.run(["clang", "-arch", "arm64", str(source), "-o", str(binary)], check=True, capture_output=True)
            before = qa.text_hash(binary)
            subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True, capture_output=True)
            self.assertEqual(qa.text_hash(binary), before)
            self.assertEqual(len(before), 64)

if __name__ == "__main__": unittest.main()
