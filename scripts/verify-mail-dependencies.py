#!/usr/bin/env python3
"""Verify the independent mail dependency pins and retained notices, without references."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent

def verify(root=ROOT, checkouts=True):
    lock = json.loads((root / 'Dependencies/Mail.lock.json').read_text())
    pins = {p['identity']: p for p in json.loads((root / 'Package.resolved').read_text())['pins']}
    expected = {p['identity'] for p in lock['packages']}
    if set(pins) != expected:
        raise ValueError('Unexpected or missing resolved dependency')
    manifest = (root / 'Package.swift').read_text()
    for package in lock['packages']:
        name, revision = package['identity'], package['revision']
        if pins[name]['state']['revision'] != revision or pins[name]['location'] != package['url'] or revision not in manifest:
            raise ValueError('Mail revision differs from independent lock')
        for notice in package['licenses']:
            path = root / 'Dependencies/Mail' / name / notice['path']
            if hashlib.sha256(path.read_bytes()).hexdigest() != notice['sha256']:
                raise ValueError('Retained mail notice changed')
        if checkouts:
            checkout = root / '.build/checkouts' / name
            actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=checkout, text=True).strip()
            changes = subprocess.check_output(['git', 'status', '--porcelain'], cwd=checkout, text=True).strip()
            if actual != revision or changes:
                raise ValueError('Mail checkout revision/content differs from reviewed pin')
    for notice in lock['notices']:
        path = root / notice['path']
        if hashlib.sha256(path.read_bytes()).hexdigest() != notice['sha256']:
            raise ValueError('Ported source notice changed')
    if 'product(name: "NIOSSL"' in manifest:
        raise ValueError('Excluded BoringSSL must not be linked into the GPL application')
    for folder in ['Sources/MakoshMail', 'Sources/CMailTLS', 'Sources/CMailOpenSSL']:
        for path in (root / folder).rglob('*'):
            if path.is_file() and '.references/' in path.read_text():
                raise ValueError('Mail runtime depends on a research clone')
    return len(expected)

if __name__ == '__main__':
    try:
        print(f'Mail dependency verification: {verify()} exact pins; retained notices valid; BoringSSL product excluded.')
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError):
        raise SystemExit('Mail dependency verification failed. Check the independent lock, notices and source checkouts.') from None
