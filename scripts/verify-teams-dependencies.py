#!/usr/bin/env python3
"""Offline provenance check for the native Teams contract port, independent of research clones."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REFERENCE_CLIENT_ID = '66ebad71-1604-48fc-a086-0d4caa24988b'
REVISION = '9c8a72c32369f9d9bd15b793099522a80070a063'
RETAINED = {
    'Dependencies/Teams/Reference/auth.rs': '078899cfdee98579fa572b82eab5c74132afebdd4e791d3b91bdcc7744fc2100',
    'Dependencies/Teams/Reference/graph.rs': '0b0948f59bc5130b9cf338b8f6b017bc22a2f822e6d8c2fba1512684df2d6e98',
    'LICENSES/Teams-cli-MIT.txt': 'f46c9ce38950d6eaca881c4c7f65fe3d9f56aba7640f8fabf52a4aafbc545480',
}

def verify(root=ROOT):
    lock = json.loads((root / 'Dependencies/Teams.lock.json').read_text())
    if lock['source'] != {'url': 'https://github.com/rvben/teams-cli', 'revision': REVISION, 'license': 'MIT'}:
        raise ValueError('Unreviewed Teams source')
    retained = {entry['path']: entry['sha256'] for entry in lock['retainedSource'] + lock['notices']}
    if retained != RETAINED or lock['linkedRustDependencies']:
        raise ValueError('Unexpected retained source or linked Rust dependency')
    for path, digest in RETAINED.items():
        if hashlib.sha256((root / path).read_bytes()).hexdigest() != digest:
            raise ValueError('Reviewed Teams source/notice changed')
    for path in (root / 'Sources/MakoshTeams').rglob('*.swift'):
        text = path.read_text()
        if '.references/' in text or 'makosh_old' in text or REFERENCE_CLIENT_ID.lower() in text.lower():
            raise ValueError('Teams runtime uses research configuration or upstream public client')
    return REVISION

if __name__ == '__main__':
    try:
        print('Teams provenance valid: ' + verify() + '; native Swift port, no Rust runtime dependency.')
    except (ValueError, OSError, KeyError):
        raise SystemExit('Teams provenance verification failed; inspect owned pin, sources and notices.') from None
