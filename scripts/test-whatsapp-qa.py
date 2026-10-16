import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('whatsapp_qa',ROOT/'scripts/run-whatsapp-qa.py')
qa=importlib.util.module_from_spec(spec);spec.loader.exec_module(qa)
class WhatsAppQATests(unittest.TestCase):
 def test_fresh_owned_run_and_matching_code(self):
  value=qa.isolated_configuration({'connectionString':'postgresql://synthetic@127.0.0.1/fixture'},'abc123')
  self.assertTrue(value['schema'].startswith('qa_whatsapp_'));self.assertTrue(value['archiveSchema'].startswith('qa_whatsapp_'));self.assertIn('hostaddr=127.0.0.1',value['connectionString'])
  for connection in ['host=203.0.113.1','host=127.0.0.1 service=private','host=localhost hostaddr=203.0.113.1']:
   with self.assertRaises(ValueError):qa.isolated_configuration({'connectionString':connection},'abc123')
  marker=qa.qa_info({'CFBundleIdentifier':'org.makosh.desktop','CFBundleExecutable':'Makosh'})
  self.assertEqual(marker['MakoshSyntheticService'],'whatsapp');self.assertTrue(marker['MakoshRequiresSyntheticConfiguration'])
  with tempfile.TemporaryDirectory() as directory:
   path=Path(directory)/'binary';header=struct.pack('<IIIIIIII',0xfeedfacf,0x0100000c,0,2,1,152,0,0)
   command=bytearray(152);struct.pack_into('<II',command,0,0x19,152);struct.pack_into('<I',command,64,1);command[72:88]=b'__text'+b'\0'*10;command[88:104]=b'__TEXT'+b'\0'*10;struct.pack_into('<Q',command,112,4);struct.pack_into('<I',command,120,184)
   path.write_bytes(header+command+b'test');first=qa.text_hash(path);path.write_bytes(header+command+b'next');self.assertNotEqual(first,qa.text_hash(path))
 def test_source_notices_and_no_private_resources(self):
  with tempfile.TemporaryDirectory() as directory:
   bundle=Path(directory);licenses=bundle/'Contents/Resources/Licenses';licenses.mkdir(parents=True)
   with self.assertRaises(ValueError):qa.verify_resources(bundle)
   (licenses/'WhatsAppWorker-README.md').write_bytes((ROOT/'Dependencies/WhatsApp/README.md').read_bytes());(bundle/'Contents/Resources/MakoshWhatsAppWorker-Source.tar.gz').write_bytes(b'synthetic-source-test')
   qa.verify_resources(bundle)
   for name in ['database.json','storage.json','api.json','session.db','session.json','tokens.json']:
    p=licenses/name;p.write_bytes(b'{}')
    with self.assertRaises(ValueError):qa.verify_resources(bundle)
    p.unlink()
 def test_storage_requires_pinned_loopback(self):
  source={'endpoint':'http://localhost:9000','region':'local','bucket':'qa-whatsapp','accessKeyID':'synthetic','secretAccessKey':'synthetic'}
  self.assertEqual(qa.isolated_storage(source)['endpoint'],'http://127.0.0.1:9000')
  for endpoint in ['https://example.test','http://127.0.0.1:9000/path','http://user@127.0.0.1:9000','http://127.0.0.1:9000?redirect=yes']:
   with self.assertRaises(ValueError):qa.isolated_storage(dict(source,endpoint=endpoint))
if __name__=='__main__':unittest.main()
