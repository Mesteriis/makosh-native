"""Owned loopback-only IMAP/SMTP fixture. Never reads a user's mailbox or credentials."""
import json
import os
import socket
import ssl
import sys
import time
import re
from pathlib import Path

mode, scenario, directory = sys.argv[1:4]
root = Path(directory)
listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(1)
listener.settimeout(12)
def publish(name, value):
    temporary = root / (name + '.tmp')
    temporary.write_text(value)
    os.replace(temporary, root / name)

publish('port', str(listener.getsockname()[1]))
count = {'data': 0, 'append': 0, 'commands': 0, 'move': 0, 'idle': 0, 'idle_done': 0}

def secure(sock):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(root / 'cert.pem'), str(root / 'key.pem'))
    return context.wrap_socket(sock, server_side=True)

try:
    connection, _ = listener.accept()
    connection.settimeout(12)
    if scenario == 'tls':
        connection = secure(connection)
    reader = connection.makefile('rb')
    def write(value):
        connection.sendall(value if isinstance(value, bytes) else value.encode())
    if mode == 'imap':
        write('* OK fixture ready\r\n')
        while line := reader.readline():
            count['commands'] += 1
            tag, command = line.decode().rstrip().split(' ', 1)
            verb = command.upper()
            if verb == 'CAPABILITY':
                write(f'* CAPABILITY IMAP4rev1 {"IDLE" if scenario.startswith("idle-") else ""}\r\n{tag} OK capability\r\n')
            elif verb == 'IDLE':
                count['idle'] += 1
                write('+ idling\r\n')
                publish('idle-started', 'ready')
                if scenario == 'idle-change':
                    time.sleep(0.05)
                    write('* 2 EXISTS\r\n')
                if reader.readline().strip() != b'DONE':
                    raise RuntimeError('Expected DONE before any new command')
                count['idle_done'] += 1
                write(f'{tag} OK idle finished\r\n')
            elif verb == 'STARTTLS':
                write(f'{tag} OK Begin TLS\r\n')
                reader.close()
                connection = secure(connection)
                reader = connection.makefile('rb')
            elif verb.startswith('LOGIN'):
                write(f'{tag} '+('NO rejected' if scenario == 'auth-reject' else 'OK logged in')+'\r\n')
            elif verb.startswith('LIST'):
                extra = '* LIST () "/" "&BB8EQAQ4BDIENQRC-"\r\n* LIST () "/" "R&-D"\r\n' if scenario == 'localized' else '* LIST (\\Drafts) "/" "Drafts"\r\n' if 'draft-' in scenario else ''
                if scenario in ['rule-starttls', 'rule-big-starttls']: extra += '* LIST (\\Trash) "/" "Trash"\r\n'
                write(f'* LIST (\\Inbox) "/" "INBOX"\r\n* LIST (\\Sent) "/" "Sent"\r\n{extra}{tag} OK listed\r\n')
            elif verb.startswith('SELECT'):
                if scenario == 'hold-select':
                    publish('select-held', 'ready')
                    deadline = time.monotonic() + 8
                    while not (root / 'release-select').exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                if scenario == 'localized':
                    if not any(name in command for name in ['&BB8EQAQ4BDIENQRC-', 'R&-D']):
                        write(f'{tag} NO wrong wire mailbox\r\n'); continue
                    count['localized_select'] = count.get('localized_select', 0) + 1
                validity = 98 if scenario == 'new-validity' else 97
                total = 51 if scenario == 'backlog-starttls' else 0 if scenario == 'removed' and count['commands'] > 5 else 1
                write(f'* {total} EXISTS\r\n* OK [UIDVALIDITY {validity}] valid\r\n{tag} OK selected\r\n')
            elif 'SEARCH' in verb:
                if scenario == 'backlog-starttls':
                    match = re.search(r'UID (\d+):', verb)
                    lower = int(match.group(1)) if match else 1
                    write('* SEARCH '+ ' '.join(str(i) for i in range(lower,52))+f'\r\n{tag} OK found\r\n')
                else: write(f'* SEARCH 11\r\n{tag} OK found\r\n')
            elif 'FETCH' in verb and 'BODY' in verb:
                count['body_fetch'] = count.get('body_fetch', 0) + 1
                raw = b'Content-Type: text/plain; charset=utf-8\r\n\r\nMail fixture body'
                if scenario == 'rule-big-starttls': raw += b'x' * (32 * 1024 * 1024)
                if 'draft-' in scenario:
                    raw = b'Content-Type: multipart/mixed; boundary=fixture\r\n\r\n--fixture\r\nContent-Type: text/plain\r\n\r\nMail fixture body\r\n--fixture\r\nContent-Type: text/html\r\n\r\n<p><strong>Mail fixture body</strong></p>\r\n--fixture\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename="same.bin"\r\nContent-Transfer-Encoding: base64\r\n\r\nAQID\r\n--fixture\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename="same.bin"\r\nContent-Transfer-Encoding: base64\r\n\r\nBAUG\r\n--fixture--\r\n'
                write(b'* 1 FETCH (UID 11 BODY[] {'+str(len(raw)).encode()+b'}\r\n'+raw+b')\r\n'+tag.encode()+b' OK fetched\r\n')
            elif 'FETCH' in verb:
                if scenario == 'backlog-starttls':
                    identifiers = command.split()[2 if verb.startswith('UID FETCH') else 1]
                    selected = set()
                    for item in identifiers.split(','):
                        bounds = item.split(':'); first = int(bounds[0]); last = int(bounds[-1]) if bounds[-1] != '*' else 51
                        selected.update(range(first,last+1))
                    for i in sorted(selected.intersection(range(1,52))):
                        if 'ENVELOPE' in verb:
                            write(f'* {i} FETCH (UID {i} FLAGS () ENVELOPE ("Thu, 15 Oct 2026 01:00:00 +0200" "Fixture {i}" (("Tester" NIL "sender" "example.invalid")) NIL NIL ((NIL NIL "qa" "example.invalid")) NIL NIL NIL "<fixture-{i}@example.invalid>"))\r\n')
                        else: write(f'* {i} FETCH (UID {i} FLAGS ())\r\n')
                    write(f'{tag} OK fetched\r\n'); continue
                if scenario == 'removed' and count['commands'] > 5:
                    write(f'{tag} OK no matching UID\r\n')
                    continue
                recipients = '(("QA First" NIL "qa" "example.invalid") ("QA Second" NIL "second" "example.invalid")) (("Copy Name" NIL "copy" "example.invalid")) (("Hidden Name" NIL "hidden" "example.invalid"))' if 'draft-' in scenario else '((NIL NIL "qa" "example.invalid")) NIL NIL'
                write('* 1 FETCH (UID 11 FLAGS (\\Seen) ENVELOPE ("Thu, 15 Oct 2026 01:00:00 +0200" "Fixture" (("Tester" NIL "sender" "example.invalid")) NIL NIL '+recipients+' NIL "<fixture@example.invalid>"))\r\n')
                write(f'{tag} OK fetched\r\n')
            elif 'APPEND' in verb:
                count['append'] += 1
                size = int(command.rsplit('{',1)[1].rstrip('}').rstrip('+'))
                if not command.endswith('+}'):
                    write('+ ready\r\n')
                reader.read(size)
                reader.readline()
                if 'append-drop' in scenario or 'draft-drop' in scenario:
                    break
                write(f'{tag} OK [APPENDUID 97 12] appended\r\n')
            elif 'STORE' in verb or 'MOVE' in verb:
                if 'MOVE' in verb: count['move'] += 1
                write(f'{tag} OK changed\r\n')
            else:
                write(f'{tag} BAD unsupported\r\n')
    else:
        write('220 fixture ready\r\n')
        auth_step = 0
        while line := reader.readline():
            count['commands'] += 1
            verb = line.decode().strip().upper()
            if auth_step:
                write('334 UGFzc3dvcmQ6\r\n' if auth_step == 1 else '235 authenticated\r\n')
                auth_step = 2 if auth_step == 1 else 0
            elif verb.startswith('EHLO'):
                write('250-fixture\r\n250 AUTH LOGIN\r\n')
            elif verb == 'STARTTLS':
                write('220 Begin TLS\r\n')
                reader.close()
                connection = secure(connection)
                reader = connection.makefile('rb')
            elif verb == 'AUTH LOGIN':
                if scenario == 'hold-auth-starttls':
                    publish('auth-held', 'ready')
                    deadline = time.monotonic() + 8
                    while not (root / 'release-auth').exists() and time.monotonic() < deadline: time.sleep(0.01)
                if scenario == 'auth-reject': write('535 denied\r\n')
                else: write('334 VXNlcm5hbWU6\r\n'); auth_step = 1
            elif verb.startswith(('MAIL FROM:', 'RCPT TO:')):
                write('250 ok\r\n')
            elif verb == 'DATA':
                write('354 ready\r\n')
                wire = bytearray()
                while (data := reader.readline()) not in (b'.\r\n', b''):
                    wire.extend(data)
                (root / 'data.eml').write_bytes(wire)
                count['data'] += 1
                if scenario == 'data-drop': break
                write('550 rejected\r\n' if scenario == 'data-reject' else '220 unexpected\r\n' if scenario == 'data-weird' else '250 accepted\r\n')
            elif verb == 'QUIT':
                break
    reader.close()
    connection.close()
except (OSError, ValueError, ssl.SSLError) as error:
    count['fixture_error'] = type(error).__name__
finally:
    publish('result.json', json.dumps(count))
    listener.close()
