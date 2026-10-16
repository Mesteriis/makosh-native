import importlib.util
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('telemost_qa', ROOT/'scripts/run-telemost-qa.py')
qa = importlib.util.module_from_spec(spec); spec.loader.exec_module(qa)
class TelemostQATests(unittest.TestCase):
    def test_fresh_run_and_required_marker(self):
        original = {'connectionString': 'postgresql://synthetic@127.0.0.1/test', 'schema': 'makosh', 'archiveSchema': 'makosh_archive'}
        result = qa.isolated_configuration(original, 'abc123')
        self.assertTrue(result['schema'].startswith('qa_telemost_'))
        self.assertTrue(result['archiveSchema'].startswith('qa_telemost_'))
        with self.assertRaises(ValueError): qa.isolated_configuration({'connectionString': 'host=203.0.113.1'}, 'abc123')
        with self.assertRaises(ValueError): qa.isolated_configuration(original, '../bad')
        value = qa.qa_info({'CFBundleIdentifier': 'org.makosh.desktop', 'CFBundleExecutable': 'Makosh'})
        self.assertEqual(value['MakoshSyntheticService'], 'telemost')
        self.assertTrue(value['MakoshRequiresSyntheticConfiguration'])
        self.assertEqual(value['CFBundleIdentifier'], 'org.makosh.telemost.qa')
    def test_bundle_contains_provenance_without_private_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            with self.assertRaises(ValueError): qa.verify_resources(bundle)
            root = bundle/'Contents/Resources/Licenses'; root.mkdir(parents=True)
            (root/'Telemost.lock.json').write_bytes((ROOT/'Dependencies/Telemost.lock.json').read_bytes())
            (root/'Telemost-README.md').write_bytes((ROOT/'Dependencies/Telemost/README.md').read_bytes())
            qa.verify_resources(bundle)
            (root/'database.json').write_text('{}')
            with self.assertRaises(ValueError): qa.verify_resources(bundle)
if __name__ == '__main__': unittest.main()
