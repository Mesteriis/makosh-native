#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Pin, archive and adaptation boundaries; no network, devices or accounts."""
import hashlib, importlib.util, io, json, subprocess, tarfile, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('voip', ROOT / 'scripts/prepare-telegram-voip.py')
voip = importlib.util.module_from_spec(spec); spec.loader.exec_module(voip)

class VoipPreparationTests(unittest.TestCase):
    def test_origin_and_submodule_revision_cannot_be_replaced(self):
        lock = json.loads((ROOT / 'Dependencies/TelegramVoip.lock.json').read_text())
        voip.validate_lock(lock)
        for index, field, replacement in [(0, 'url', 'https://example.invalid/source.git'), (2, 'revision', '0' * 40)]:
            changed = json.loads(json.dumps(lock)); changed['components'][index][field] = replacement
            with self.assertRaises(ValueError): voip.validate_lock(changed)

    def test_archive_rejects_paths_duplicates_and_symlinks_before_output(self):
        for names, symlink in [(['../escape'], False), (['/absolute'], False), (['same', 'same'], False), (['link'], True)]:
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode='w') as archive:
                for name in names:
                    info = tarfile.TarInfo(name)
                    if symlink: info.type = tarfile.SYMTYPE; info.linkname = '/etc/passwd'; archive.addfile(info)
                    else: info.size = 3; archive.addfile(info, io.BytesIO(b'own'))
            with self.assertRaises(ValueError): voip.archive_files(data.getvalue())

    def test_changed_source_is_refused_even_when_local_marker_agrees(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); (root / 'one').write_bytes(b'approved')
            expected = voip.fingerprint({'one': hashlib.sha256(b'approved').hexdigest()})
            component = {'preparedFingerprint': expected, 'fileCount': 1}
            voip.verify_component(root, component)
            (root / 'one').write_bytes(b'replaced')
            (root / '.marker.json').write_text(json.dumps({'one': hashlib.sha256(b'replaced').hexdigest()}))
            with self.assertRaises(ValueError): voip.verify_component(root, component)

    def test_only_reviewed_vpx_build_generators_become_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            generators = ['configure', 'build/make/version.sh', 'build/make/rtcd.pl', 'build/make/gen_asm_deps.sh']
            for name in generators + ['README']:
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'synthetic'); path.chmod(0o644)
            voip.vpx_build_permissions(root)
            for name in generators: self.assertEqual((root / name).stat().st_mode & 0o777, 0o755)
            self.assertEqual((root / 'README').stat().st_mode & 0o777, 0o644)

    def test_native_adaptation_requires_exact_source_and_is_idempotent(self):
        for path, record in voip.ADAPTATIONS.items():
            cache = ROOT / ('.local/tg-owt-source.git' if path.startswith('owt/') else '.local/tgcalls-source.git')
            revision = 'be39b8c8d0db1f377118f813f0c4bd331d341d5e' if path.startswith('owt/') else '5ddc3ccf2086127722a06e3d836698fcd717f11b'
            relative = path.partition('/')[2]
            source = subprocess.check_output(['git', '--no-replace-objects', '--git-dir=' + str(cache), 'show', revision + ':' + relative])
            result = voip.adapt(path, source)
            self.assertEqual(hashlib.sha256(result).hexdigest(), record['output'])
            self.assertEqual(voip.adapt(path, result), result)
            with self.assertRaises(ValueError): voip.adapt(path, source + b'\n// changed\n')

if __name__ == '__main__': unittest.main()
