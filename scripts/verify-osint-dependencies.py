#!/usr/bin/env python3
"""Verify the independent pins of the OSINT module's SSH packages and their retained notices."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent

def verify(root=ROOT, checkouts=True):
    lock = json.loads((root / 'Dependencies/OSINT.lock.json').read_text())
    pins = {p['identity']: p for p in json.loads((root / 'Package.resolved').read_text())['pins']}
    manifest = (root / 'Package.swift').read_text()
    for package in lock['packages']:
        name, revision = package['identity'], package['revision']
        if name not in pins:
            raise ValueError('OSINT package is not resolved')
        if pins[name]['state']['revision'] != revision or pins[name]['location'] != package['url'] or revision not in manifest:
            raise ValueError('OSINT revision differs from independent lock')
        for notice in package['licenses']:
            path = root / 'Dependencies/OSINT' / name / notice['path']
            if hashlib.sha256(path.read_bytes()).hexdigest() != notice['sha256']:
                raise ValueError('Retained OSINT notice changed')
        if checkouts:
            checkout = root / '.build/checkouts' / name
            actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=checkout, text=True).strip()
            changes = subprocess.check_output(['git', 'status', '--porcelain'], cwd=checkout, text=True).strip()
            if actual != revision or changes:
                raise ValueError('OSINT checkout revision/content differs from reviewed pin')
    flowsint = json.loads((root / 'Dependencies/Flowsint.lock.json').read_text())
    for folder in ['Sources/MakoshOSINT']:
        for path in (root / folder).rglob('*.swift'):
            text = path.read_text()
            if '.references/' in text or 'flowsint_core' in text or 'flowsint_enrichers' in text:
                raise ValueError('OSINT module must not depend on a research clone or copy flowsint source')
    return len(lock['packages']), flowsint['tag']

if __name__ == '__main__':
    try:
        count, tag = verify()
        print(f'OSINT dependency verification: {count} exact pins; retained notices valid; flowsint pinned at {tag}, not linked.')
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError):
        raise SystemExit('OSINT dependency verification failed. Check the independent lock, notices and source checkouts.') from None
