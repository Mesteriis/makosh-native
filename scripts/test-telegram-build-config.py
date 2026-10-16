#!/usr/bin/env python3
"""Exercise actual private build artifacts with synthetic API credentials only."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("prepare-telegram-build-config.py")
ID = "1234567"
HASH = "a1" * 16


class TelegramBuildConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.input = self.root / "build.env"
        self.output = self.root / "generated/TelegramBuildConfiguration.swift"
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("MAKOSH_TELEGRAM_API_")}

    def write_input(self, payload=None):
        self.input.write_text(payload or f"MAKOSH_TELEGRAM_API_ID={ID}\nMAKOSH_TELEGRAM_API_HASH={HASH}\n")
        self.input.chmod(0o600)

    def prepare(self, *flags, environment=None):
        result = subprocess.run([sys.executable, str(SCRIPT), "--input", str(self.input),
                                 "--output", str(self.output), *flags],
                                env=environment or self.environment, capture_output=True, text=True, timeout=10)
        self.assertNotIn(HASH, result.stdout + result.stderr)
        self.assertNotIn(ID, result.stdout + result.stderr)
        return result

    def test_private_generated_artifact_is_stable_and_input_is_preserved(self):
        self.write_input()
        original = self.input.read_bytes()
        self.assertEqual(self.prepare().returncode, 0)
        self.assertTrue(self.output.is_file(), "No compiled configuration source was generated")
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.output.parent.stat().st_mode & 0o777, 0o700)
        timestamp = self.output.stat().st_mtime_ns
        self.assertEqual(self.prepare().returncode, 0)
        self.assertEqual(self.output.stat().st_mtime_ns, timestamp)
        self.assertEqual(self.input.read_bytes(), original)

    def test_absent_pair_fails_unless_unconfigured_mode_is_explicit(self):
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertEqual(self.prepare("--allow-unconfigured").returncode, 0)
        self.assertTrue(self.output.is_file())

    def test_environment_pair_wins_without_opening_local_input(self):
        os.mkfifo(self.input, 0o600)
        environment = dict(self.environment, MAKOSH_TELEGRAM_API_ID=ID, MAKOSH_TELEGRAM_API_HASH=HASH)
        self.assertEqual(self.prepare(environment=environment).returncode, 0)

    def test_partial_or_invalid_environment_never_falls_back_or_reuses_stale_pair(self):
        self.write_input()
        self.assertEqual(self.prepare().returncode, 0)
        for values in ({"MAKOSH_TELEGRAM_API_ID": ID},
                       {"MAKOSH_TELEGRAM_API_HASH": HASH},
                       {"MAKOSH_TELEGRAM_API_ID": "0", "MAKOSH_TELEGRAM_API_HASH": HASH},
                       {"MAKOSH_TELEGRAM_API_ID": ID, "MAKOSH_TELEGRAM_API_HASH": "$(touch injected)"}):
            with self.subTest(values=list(values)):
                self.assertNotEqual(self.prepare("--allow-unconfigured", environment=dict(self.environment, **values)).returncode, 0)
                self.assertNotIn(HASH, self.output.read_text() if self.output.exists() else "")

    def test_unsafe_local_inputs_fail_closed_without_blocking(self):
        for mutation in ("public", "symlink", "fifo", "oversize", "duplicate", "extra", "invalid", "nonascii"):
            with self.subTest(mutation=mutation):
                self.input.unlink(missing_ok=True)
                self.write_input()
                if mutation == "public": self.input.chmod(0o644)
                elif mutation == "symlink":
                    target = self.root / "target.env"
                    self.input.rename(target); self.input.symlink_to(target)
                elif mutation == "fifo":
                    self.input.unlink(); os.mkfifo(self.input, 0o600)
                elif mutation == "oversize": self.input.write_bytes(b"x" * 8193)
                elif mutation == "duplicate": self.write_input(self.input.read_text() + f"MAKOSH_TELEGRAM_API_ID={ID}\n")
                elif mutation == "extra": self.write_input(self.input.read_text() + "UNRELATED=private-marker\n")
                elif mutation == "invalid": self.write_input(f"MAKOSH_TELEGRAM_API_ID=2147483648\nMAKOSH_TELEGRAM_API_HASH={HASH}\n")
                else: self.write_input(f"MAKOSH_TELEGRAM_API_ID=１２３\nMAKOSH_TELEGRAM_API_HASH={HASH}\n")
                self.assertNotEqual(self.prepare("--allow-unconfigured").returncode, 0)

    def test_symlink_output_does_not_overwrite_unrelated_file(self):
        self.write_input()
        target = self.root / "preserved"
        target.write_text("keep")
        self.output.parent.mkdir(mode=0o700)
        self.output.symlink_to(target)
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertEqual(target.read_text(), "keep")

    @unittest.skipIf(os.environ.get("MAKOSH_SKIP_SWIFT_PROBE") == "1", "Swift compiler slot reserved by another gate")
    def test_compiled_pair_runs_after_build_input_and_generated_source_are_removed(self):
        for configured in (True, False):
            with self.subTest(configured=configured):
                self.input.unlink(missing_ok=True)
                if configured: self.write_input()
                self.assertEqual(self.prepare(*([] if configured else ["--allow-unconfigured"])).returncode, 0)
                probe = self.root / "main.swift"
                expression = (f'MakoshBuildConfiguration.telegramAPIID == {ID} && MakoshBuildConfiguration.telegramAPIHash == "{HASH}"'
                              if configured else 'MakoshBuildConfiguration.telegramAPIID == nil && MakoshBuildConfiguration.telegramAPIHash == nil')
                probe.write_text('precondition(' + expression + ')\nprint("compiled configuration verified")\n')
                executable = self.root / "probe"
                result = subprocess.run(["swiftc", str(self.output), str(probe), "-o", str(executable)], capture_output=True, timeout=60)
                self.assertEqual(result.returncode, 0, "Generated configuration did not compile")
                self.input.unlink(missing_ok=True); self.output.unlink(); probe.unlink()
                result = subprocess.run([str(executable)], capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"compiled configuration verified\n")


if __name__ == "__main__": unittest.main()
