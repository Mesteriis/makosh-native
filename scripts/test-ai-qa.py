import importlib.util
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ai_qa', ROOT/'scripts/run-ai-qa.py')
qa = importlib.util.module_from_spec(spec); spec.loader.exec_module(qa)
class AIQATests(unittest.TestCase):
    def test_isolated_schema_and_marker(self):
        original = {'connectionString': 'postgresql://synthetic@127.0.0.1/test', 'schema': 'makosh', 'archiveSchema': 'makosh_archive'}
        result = qa.isolated_configuration(original, 'abc123')
        self.assertEqual(result['schema'], 'qa_ai_abc123')
        self.assertEqual(result['archiveSchema'], 'qa_ai_abc123')
        self.assertIn('hostaddr=127.0.0.1', result['connectionString'])
        with self.assertRaises(ValueError): qa.isolated_configuration({'connectionString': 'host=203.0.113.1'}, 'abc123')
        with self.assertRaises(ValueError): qa.isolated_configuration(original, '../bad')
        value = qa.qa_info({'CFBundleIdentifier': 'org.makosh.desktop', 'CFBundleExecutable': 'Makosh'})
        self.assertEqual(value['MakoshSyntheticService'], 'ai')
        self.assertTrue(value['MakoshRequiresSyntheticConfiguration'])
        self.assertEqual(value['CFBundleIdentifier'], 'org.makosh.ai.qa')
        with self.assertRaises(ValueError): qa.qa_info({'CFBundleIdentifier': 'other', 'CFBundleExecutable': 'Makosh'})
    def test_launch_uses_only_ai_flags(self):
        launch = qa.launch_command(Path('/q/MakoshAIQA.app'), Path('/q/database.json'))
        self.assertEqual(launch, ['/usr/bin/open', '-n', '/q/MakoshAIQA.app', '--args', '--ai-synthetic-preview', '--database-config', '/q/database.json'])
    def test_private_inputs_are_not_bundled(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory); resources = bundle/'Contents/Resources'; resources.mkdir(parents=True)
            qa.verify_resources(bundle)
            (resources/'s3.json').write_text('{}')
            with self.assertRaises(ValueError): qa.verify_resources(bundle)
if __name__ == '__main__': unittest.main()
