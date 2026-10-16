#!/usr/bin/env python3
"""Reproduce the reviewed SDK adaptation from a checksummed public crate."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT=Path(__file__).resolve().parent.parent

def prepare():
    pin=json.loads((ROOT/'Dependencies/WhatsApp.lock.json').read_text())
    adaptation=pin['engineAdaptation']
    package=next(p for p in pin['packages'] if p['name']==adaptation['package'] and p['version']==adaptation['version'])
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    patch=ROOT/adaptation['patch']
    if sha(patch)!=adaptation['patchSHA256']: raise RuntimeError('SDK patch drift')
    local=ROOT/'.local';local.mkdir(exist_ok=True)
    archive=local/'whatsapp-rust-0.7.0.crate'
    if not archive.exists():
        with urllib.request.urlopen('https://static.crates.io/crates/whatsapp-rust/whatsapp-rust-0.7.0.crate',timeout=60) as response:
            payload=response.read(32*1024*1024+1)
        if hashlib.sha256(payload).hexdigest()!=package['checksum']: raise RuntimeError('SDK download checksum mismatch')
        archive.write_bytes(payload)
    if sha(archive)!=package['checksum']: raise RuntimeError('SDK archive drift')
    destination=local/'whatsapp-engine'
    with tarfile.open(archive) as source:
        members=source.getmembers();expected={}
        for member in members:
            parts=Path(member.name).parts
            if not parts or parts[0]!='whatsapp-rust-0.7.0' or '..' in parts or (not member.isfile() and not member.isdir()): raise RuntimeError('Unsafe SDK archive')
            if member.isfile():
                relative=str(Path(*parts[1:]));expected[relative]=adaptation['files'].get(relative,hashlib.sha256(source.extractfile(member).read()).hexdigest())
        def matches():
            return destination.exists() and {str(p.relative_to(destination)) for p in destination.rglob('*') if p.is_file()}==set(expected) and all(sha(destination/p)==s for p,s in expected.items())
        if matches(): return destination
        with tempfile.TemporaryDirectory(prefix='wa-sdk-',dir=local) as temporary:
            source.extractall(temporary,filter='data')
            prepared=Path(temporary)/'whatsapp-rust-0.7.0'
            subprocess.run(['patch','--batch','--fuzz=0','-p1','-i',str(patch)],cwd=prepared,check=True,stdout=subprocess.DEVNULL)
            if any(sha(prepared/p)!=s for p,s in expected.items()): raise RuntimeError('Prepared SDK source mismatch')
            if destination.exists(): shutil.rmtree(destination) # public generated source only
            shutil.move(prepared,destination)
        if not matches(): raise RuntimeError('Prepared SDK file inventory drift')
    return destination

if __name__=='__main__': prepare()
