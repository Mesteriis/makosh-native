#!/usr/bin/env python3
"""Guard the PgBouncer development layer: pinned build, session pooling, private local configuration."""
import configparser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
PGBOUNCER = ROOT / "scripts/pgbouncer"
CONFIGURE = ROOT / "scripts/configure-dev-db.py"
COMPOSE = ROOT / "compose.yaml"
# PostgreSQL max_connections = 100; the pool budget leaves room for direct diagnostic sessions on 55439.
POOL_BUDGET = 90


def compose_service(name):
    """Return the lines of one top-level compose service without a YAML dependency."""
    lines = COMPOSE.read_text().splitlines()
    start = lines.index(f"  {name}:")
    body = []
    for line in lines[start + 1:]:
        if line.strip() and not line.startswith("    "):
            break
        body.append(line)
    return body


class PgBouncerConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.ini = configparser.ConfigParser(interpolation=None)
        self.ini.read(PGBOUNCER / "pgbouncer.ini")
        self.pool = self.ini["pgbouncer"]

    def test_session_pooling_and_reset_are_kept_for_session_leases(self):
        self.assertEqual(self.pool["pool_mode"], "session")
        self.assertEqual(self.pool["server_reset_query"], "DISCARD ALL")
        self.assertEqual(self.pool["auth_type"], "scram-sha-256")
        self.assertEqual(self.pool["listen_port"], "6432")
        self.assertEqual(self.ini["databases"]["makosh"], "host=postgres port=5432 dbname=makosh")

    def test_pool_budget_leaves_direct_diagnostic_connections(self):
        default = int(self.pool["default_pool_size"])
        reserve = int(self.pool["reserve_pool_size"])
        self.assertEqual(default, 80)
        self.assertEqual(reserve, 10)
        self.assertLessEqual(default + reserve, POOL_BUDGET)


class PgBouncerImageTests(unittest.TestCase):
    def setUp(self):
        self.dockerfile = (PGBOUNCER / "Dockerfile").read_text()

    def test_base_image_is_pinned_by_digest(self):
        self.assertRegex(self.dockerfile, r"(?m)^FROM pgvector/pgvector:[0-9A-Za-z.\-]+@sha256:[0-9a-f]{64}$")

    def test_package_is_pinned_and_installed_from_the_snapshot_archive(self):
        self.assertIn("pgbouncer=1.24.1-1+deb13u2", self.dockerfile)
        self.assertRegex(self.dockerfile, r"snapshot\.debian\.org/archive/debian/\d{8}T\d{6}Z/")
        self.assertIn("Acquire::Check-Valid-Until=false", self.dockerfile)
        self.assertNotIn("deb.debian.org", self.dockerfile)
        self.assertNotIn("apt.postgresql.org", self.dockerfile)


class ComposeTests(unittest.TestCase):
    def setUp(self):
        self.service = compose_service("pgbouncer")
        self.text = "\n".join(self.service)

    def test_pool_listens_on_loopback_only(self):
        ports = [line.strip() for line in self.service if re.match(r'\s+- "\d', line)]
        self.assertEqual(ports, ['- "127.0.0.1:55441:6432"'])

    def test_container_is_hardened_and_waits_for_healthy_postgres(self):
        self.assertIn("read_only: true", self.text)
        self.assertIn('security_opt: ["no-new-privileges:true"]', self.text)
        self.assertRegex(self.text, r"depends_on:\n\s+postgres:\n\s+condition: service_healthy")
        self.assertIn('cap_drop: ["ALL"]', self.text)
        self.assertIn("image: makosh-pgbouncer:1.24.1-deb13u2", self.text)


class ConfigureDevDBTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.output = self.home / "local"
        self.environment = {"HOME": str(self.home), "PATH": os.environ.get("PATH", "")}

    def configure(self):
        result = subprocess.run([sys.executable, "-I", str(CONFIGURE), "--output-dir", str(self.output)],
                                cwd=self.home, env=self.environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def password(self):
        return json.loads((self.output / "postgres-settings.json").read_text())["password"]

    def test_generated_files_are_private_and_route_through_the_pool(self):
        result = self.configure()
        password = self.password()
        self.assertEqual(len(password), 64)
        for name in ["postgres-settings.json", "postgres.env", "pgbouncer-users.txt",
                     "postgres-app.json", "postgres-direct.json"]:
            path = self.output / name
            self.assertTrue(path.is_file(), name)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600, name)
        self.assertNotIn(password, result.stdout + result.stderr)
        application = json.loads((self.output / "postgres-app.json").read_text())
        direct = json.loads((self.output / "postgres-direct.json").read_text())
        self.assertIn("host=127.0.0.1 port=55441 ", application["connectionString"])
        self.assertIn("host=127.0.0.1 port=55439 ", direct["connectionString"])
        self.assertEqual(application["schema"], "makosh")
        self.assertEqual(direct["schema"], "makosh")
        self.assertEqual((self.output / "pgbouncer-users.txt").read_text(), f'"makosh" "{password}"\n')
        self.assertEqual((self.output / "postgres.env").read_text(), f"MAKOSH_POSTGRES_PASSWORD={password}\n")

    def test_second_run_keeps_the_existing_password(self):
        self.configure()
        password = self.password()
        self.configure()
        self.assertEqual(self.password(), password)
        self.assertIn(password, (self.output / "pgbouncer-users.txt").read_text())

    def test_default_output_directory_is_the_repository_local_directory(self):
        source = CONFIGURE.read_text()
        self.assertIn('default=root / ".local"', source)


if __name__ == "__main__":
    unittest.main()
