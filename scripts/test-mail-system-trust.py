#!/usr/bin/env python3
"""BIO-to-BIO TLS tests; no external network, accounts or system trust mutations."""
import ctypes, os, ssl, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def probe(library, cert, key, ca, host):
    api=ctypes.CDLL(library)
    api.mail_tls_create.argtypes=[ctypes.c_char_p,ctypes.c_char_p]; api.mail_tls_create.restype=ctypes.c_void_p
    api.mail_tls_handshake.argtypes=[ctypes.c_void_p]; api.mail_tls_handshake.restype=ctypes.c_int
    api.mail_tls_drain.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t]; api.mail_tls_drain.restype=ctypes.c_int
    api.mail_tls_feed.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t]; api.mail_tls_feed.restype=ctypes.c_int
    api.mail_tls_free.argtypes=[ctypes.c_void_p]
    session=api.mail_tls_create(host.encode(),None if ca=='system' else ca.encode())
    if not session: return False
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert,key)
    incoming,outgoing=ssl.MemoryBIO(),ssl.MemoryBIO(); server=context.wrap_bio(incoming,outgoing,server_side=True)
    buffer=ctypes.create_string_buffer(65536)
    try:
        for _ in range(100):
            result=api.mail_tls_handshake(session)
            if result==1: return True
            if result<0: return False
            while (count:=api.mail_tls_drain(session,buffer,len(buffer)))>0: incoming.write(buffer.raw[:count])
            try: server.do_handshake()
            except ssl.SSLWantReadError: pass
            except ssl.SSLError: return False
            while outgoing.pending:
                data=outgoing.read(); api.mail_tls_feed(session,data,len(data))
        return False
    finally: api.mail_tls_free(session)

class MailSystemTrustTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary=tempfile.TemporaryDirectory(); cls.root=Path(cls.temporary.name)
        cls.cert=cls.root/'cert.pem'; cls.key=cls.root/'key.pem'; cls.library=cls.root/'mail-tls.dylib'
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost','-keyout',str(cls.key),'-out',str(cls.cert)],check=True,capture_output=True)
        flags=subprocess.check_output(['pkg-config','--cflags','--libs','openssl'],text=True).split()
        subprocess.run(['clang','-dynamiclib',str(ROOT/'Sources/CMailTLS/MailTLS.c'),'-I'+str(ROOT/'Sources/CMailTLS/include'),*flags,'-framework','Security','-framework','CoreFoundation','-o',str(cls.library)],check=True,capture_output=True)
    @classmethod
    def tearDownClass(cls): cls.temporary.cleanup()
    def accepted(self, ca, host='localhost'):
        env=dict(os.environ); env['SSL_CERT_FILE']=str(self.cert); env['SSL_CERT_DIR']=str(self.root/'nonexistent')
        result=subprocess.run([sys.executable,__file__,'probe',str(self.library),str(self.cert),str(self.key),ca,host],env=env,capture_output=True,text=True,check=True)
        return result.stdout.strip()=='accepted'
    def testSystemTrustRejectsEnvironmentInjectedSelfSignedRoot(self): self.assertFalse(self.accepted('system'))
    def testExplicitSyntheticCAIsAccepted(self): self.assertTrue(self.accepted(str(self.cert)))
    def testExplicitCAStillEnforcesHostname(self): self.assertFalse(self.accepted(str(self.cert),'wrong.invalid'))
if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='probe': print('accepted' if probe(*sys.argv[2:]) else 'rejected')
    else: unittest.main()
