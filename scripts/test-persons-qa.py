import importlib.util
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('persons_qa', ROOT/'scripts/run-persons-qa.py')
qa = importlib.util.module_from_spec(spec); spec.loader.exec_module(qa)
class PersonsQATests(unittest.TestCase):
    def test_schema_prefix(self):
        original = {'connectionString': 'postgresql://synthetic@127.0.0.1/test', 'schema': 'makosh', 'archiveSchema': 'makosh_archive'}
        result = qa.isolated_configuration(original, 'abc123')
        self.assertEqual(result['schema'], 'qa_persons_abc123')
        self.assertEqual(result['archiveSchema'], 'qa_persons_abc123')
        self.assertIn('hostaddr=127.0.0.1', result['connectionString'])
        with self.assertRaises(ValueError): qa.isolated_configuration(original, '../bad')
    def test_refuses_remote_host(self):
        with self.assertRaises(ValueError): qa.isolated_configuration({'connectionString': 'host=203.0.113.1'}, 'abc123')
    def test_qa_info_rewrites_identity(self):
        value = qa.qa_info({'CFBundleIdentifier': 'org.makosh.desktop', 'CFBundleExecutable': 'Makosh'})
        self.assertEqual(value['MakoshSyntheticService'], 'persons')
        self.assertTrue(value['MakoshRequiresSyntheticConfiguration'])
        self.assertEqual(value['CFBundleIdentifier'], 'org.makosh.persons.qa')
        self.assertEqual(value['CFBundleName'], 'MakoshPersonsQA')
        with self.assertRaises(ValueError): qa.qa_info({'CFBundleIdentifier': 'other', 'CFBundleExecutable': 'Makosh'})
        launch = qa.launch_command(Path('/q/MakoshPersonsQA.app'), Path('/q/database.json'))
        self.assertEqual(launch, ['/usr/bin/open', '-n', '/q/MakoshPersonsQA.app', '--args', '--persons-synthetic-preview', '--database-config', '/q/database.json'])
    def test_refuses_private_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory); resources = bundle/'Contents/Resources'; resources.mkdir(parents=True)
            qa.verify_resources(bundle)
            (resources/'google-oauth.env').write_text('x')
            with self.assertRaises(ValueError): qa.verify_resources(bundle)
if __name__ == '__main__': unittest.main()
