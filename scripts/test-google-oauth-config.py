#!/usr/bin/env python3
"""Exercise the Google OAuth build preparation with synthetic client values only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("prepare-google-oauth-config.py")
CLIENT_ID = "123456789-synthetic.apps.googleusercontent.com"
SECRET = "GOCSPX-synthetic-secret"


class GoogleOAuthConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.env_file = self.root / "google-oauth.env"
        self.client = self.root / "client.json"
        self.output = self.root / "generated/GoogleOAuthConfiguration.swift"
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith("MAKOSH_GOOGLE_OAUTH_")}

    def write_client(self, kind="installed", redirects=("http://localhost",), secret=SECRET):
        self.client.write_text(json.dumps({kind: {"client_id": CLIENT_ID, "client_secret": secret, "redirect_uris": list(redirects)}}))
        self.client.chmod(0o600)
        self.env_file.write_text(f"MAKOSH_GOOGLE_OAUTH_CLIENT_CONFIG_PATH={self.client}\n")
        self.env_file.chmod(0o600)

    def prepare(self, environment=None):
        return subprocess.run([sys.executable, str(SCRIPT), "--input", str(self.env_file), "--output", str(self.output)],
                              capture_output=True, text=True, env=environment or self.environment)

    def test_missing_input_writes_nil(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.output.read_text()
        self.assertIn("public static let clientID: String? = nil", text)
        self.assertIn("public static let clientSecret: String? = nil", text)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)

    def test_valid_installed_client_writes_constants(self):
        self.write_client()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.output.read_text()
        self.assertIn(f'public static let clientID: String? = "{CLIENT_ID}"', text)
        self.assertIn(f'public static let clientSecret: String? = "{SECRET}"', text)

    def test_environment_pair_wins(self):
        environment = dict(self.environment, MAKOSH_GOOGLE_OAUTH_CLIENT_ID=CLIENT_ID, MAKOSH_GOOGLE_OAUTH_CLIENT_SECRET=SECRET)
        result = self.prepare(environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(CLIENT_ID, self.output.read_text())

    def test_web_client_rejected(self):
        self.write_client(kind="web")
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertIn("#error", self.output.read_text())

    def test_non_loopback_redirect_rejected(self):
        self.write_client(redirects=("https://evil.test/callback",))
        self.assertNotEqual(self.prepare().returncode, 0)

    def test_world_readable_env_rejected(self):
        self.write_client()
        self.env_file.chmod(0o644)
        self.assertNotEqual(self.prepare().returncode, 0)

    def test_rejection_overwrites_previous_constants_with_error(self):
        self.write_client()
        self.assertEqual(self.prepare().returncode, 0)
        self.write_client(secret="")
        self.assertNotEqual(self.prepare().returncode, 0)
        text = self.output.read_text()
        self.assertNotIn(CLIENT_ID, text)
        self.assertIn("#error", text)

    def test_values_never_printed(self):
        self.write_client()
        ok = self.prepare()
        self.write_client(kind="web")
        bad = self.prepare()
        for result in (ok, bad):
            self.assertNotIn(CLIENT_ID, result.stdout + result.stderr)
            self.assertNotIn(SECRET, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
