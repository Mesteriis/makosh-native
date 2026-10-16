#!/usr/bin/env python3
"""Executable archive admission regressions; no native build or account data."""
import unittest,runpy,tarfile,tempfile,hashlib,io
from pathlib import Path

class WhatsAppOpusSourceTests(unittest.TestCase):
    def testTraversalAndLinksAreRejectedBeforeExtraction(self):
        recipe=runpy.run_path(str(Path(__file__).with_name('prepare-whatsapp-opus.py')))
        for name,link in [('opus-1.6.1/../escape',False),('opus-1.6.1/source.c',True)]:
            with tempfile.TemporaryDirectory() as directory:
                path=Path(directory)/'fixture.tar.gz'
                with tarfile.open(path,'w:gz')as archive:
                    member=tarfile.TarInfo(name)
                    if link:member.type=tarfile.SYMTYPE;member.linkname='/private'
                    else:member.size=1
                    archive.addfile(member,None if link else io.BytesIO(b'x'))
                pin={'version':'1.6.1','archiveSHA256':hashlib.sha256(path.read_bytes()).hexdigest()}
                with self.assertRaises(RuntimeError):recipe['sources'](path,pin)
    def testChangedArchiveIsRejected(self):
        recipe=runpy.run_path(str(Path(__file__).with_name('prepare-whatsapp-opus.py')))
        with tempfile.TemporaryDirectory()as directory:
            path=Path(directory)/'changed';path.write_bytes(b'changed')
            with self.assertRaises(RuntimeError):recipe['sources'](path,{'version':'1.6.1','archiveSHA256':'0'*64})
if __name__=='__main__':unittest.main()
