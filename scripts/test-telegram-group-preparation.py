#!/usr/bin/env python3
"""Execute canonical group/journal bridge cache checks on disposable fixtures."""
import importlib.util
import json
import os
import py_compile
import shutil
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('preparation',Path(__file__).with_name('prepare-telegram.py'))
preparation=importlib.util.module_from_spec(spec);spec.loader.exec_module(preparation)
class GroupPreparationTests(unittest.TestCase):
    def fixture(self,root):
        for name,source in [('MakoshRemotePeerSearch.swift',preparation.remote_peer_helper_source()),
                            ('MakoshAvatarEditing.swift',preparation.avatar_helper_source()),
                            ('MakoshGroupMembership.swift',preparation.group_membership_helper_source())]:
            path=root/'submodules/TelegramCore/Sources/TelegramEngine/Peers'/name
            path.parent.mkdir(parents=True,exist_ok=True);path.write_text(source)
        self.marker(root)
    def marker(self,root):
        (root/'preparation.json').write_text(json.dumps(dict(source_sha=preparation.SHA,source_tree=preparation.TREE,
            source_url=preparation.URL,recipe=preparation.RECIPE,prepared_files=preparation.prepared_files(root))))
    def test_valid_group_helper_reuses_offline_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);self.fixture(root)
            with patch.object(preparation,'DEST',root),patch.object(preparation,'prepare_source',side_effect=AssertionError('fetch forbidden')):
                preparation.main()
    def test_forged_consistent_changed_group_helper_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);self.fixture(root)
            (root/'submodules/TelegramCore/Sources/TelegramEngine/Peers/MakoshGroupMembership.swift').write_text('// changed')
            self.marker(root)
            with patch.object(preparation,'DEST',root),self.assertRaisesRegex(RuntimeError,'group helper'):
                preparation.verify_prepared()
    def test_forged_consistent_missing_group_helper_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);self.fixture(root)
            (root/'submodules/TelegramCore/Sources/TelegramEngine/Peers/MakoshGroupMembership.swift').unlink()
            self.marker(root)
            with patch.object(preparation,'DEST',root),self.assertRaisesRegex(RuntimeError,'group helper'):
                preparation.verify_prepared()
    def test_cli_ignores_stale_same_timestamp_recipe_bytecode(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);scripts=root/'scripts';scripts.mkdir()
            for source in Path(__file__).parent.glob('*.py'):
                shutil.copy2(source,scripts/source.name)
            (root/'Dependencies').mkdir()
            shutil.copy2(preparation.ROOT/'Dependencies/TelegramEngine.lock.json',root/'Dependencies/TelegramEngine.lock.json')
            helper=scripts/'telegram_remote_peer_adaptation.py'
            helper.write_text('def remote_peer_helper_source(): return "source-v1"\n')
            before=helper.stat()
            cache=scripts/'__pycache__'/('telegram_remote_peer_adaptation.'+sys.implementation.cache_tag+'.pyc')
            cache.parent.mkdir()
            py_compile.compile(str(helper),cfile=str(cache),doraise=True,invalidation_mode=py_compile.PycInvalidationMode.TIMESTAMP)
            helper.write_text('def remote_peer_helper_source(): return "source-v2"\n')
            os.utime(helper,ns=(before.st_atime_ns,before.st_mtime_ns))
            engine=root/'.local/telegram-engine';self.fixture(engine)
            (engine/'submodules/TelegramCore/Sources/TelegramEngine/Peers/MakoshRemotePeerSearch.swift').write_text('source-v2')
            self.marker(engine)
            result=subprocess.run([sys.executable,str(scripts/'prepare-telegram.py')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertFalse((root/'.local/telegram-source.git').exists())
            self.assertFalse((root/'.references').exists())

if __name__=='__main__':unittest.main()
