"""Loopback-only multi-connection IDLE teardown fixture. No real mail."""
import json
from pathlib import Path
import socketserver
import ssl
import sys
import threading

root=Path(sys.argv[3]); lock=threading.Lock(); state={'active':0,'idle':0}
def update(key,delta):
    with lock:
        state[key]+=delta
        temporary=root/'result.tmp'; temporary.write_text(json.dumps(state)); temporary.replace(root/'result.json')
class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        connection=self.request; connection.settimeout(10); update('active',1)
        def write(value): connection.sendall(value.encode())
        try:
            reader=connection.makefile('rb'); write('* OK Synthetic ready\r\n')
            while True:
                line=reader.readline()
                if not line: break
                command=line.decode().strip(); tag,_,verb=command.partition(' '); verb=verb.upper()
                if verb=='STARTTLS':
                    write(tag+' OK TLS\r\n'); reader.close()
                    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(root/'cert.pem',root/'key.pem')
                    connection=context.wrap_socket(connection,server_side=True); reader=connection.makefile('rb')
                elif verb.startswith('LOGIN'): write(tag+' OK logged in\r\n')
                elif verb.startswith('LIST'): write('* LIST (\\Inbox) "/" "INBOX"\r\n* LIST () "/" "Other"\r\n'+tag+' OK listed\r\n')
                elif verb=='CAPABILITY': write('* CAPABILITY IMAP4rev1 IDLE\r\n'+tag+' OK capabilities\r\n')
                elif verb.startswith('SELECT'): write('* 0 EXISTS\r\n* OK [UIDVALIDITY 97] valid\r\n'+tag+' OK selected\r\n')
                elif verb=='IDLE':
                    write('+ idling\r\n'); update('idle',1); (root/'idle-started').write_text('ready')
                    done=reader.readline()
                    if done.strip().upper()==b'DONE': write(tag+' OK done\r\n')
                else: write(tag+' OK synthetic\r\n')
        except (OSError,ValueError): pass
        finally:
            try: reader.close(); connection.close()
            finally: update('active',-1)
class Server(socketserver.ThreadingTCPServer):
    daemon_threads=True
    allow_reuse_address=True
with Server(('127.0.0.1',0),Handler) as server:
    (root/'port').write_text(str(server.server_address[1])); server.serve_forever()
