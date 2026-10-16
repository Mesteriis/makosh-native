#!/usr/bin/env python3
"""Build reviewed native Opus for the separate Rust worker, without installers."""
from pathlib import Path
import hashlib,json,re,os,shutil,subprocess,tarfile,urllib.request
ROOT=Path(__file__).resolve().parent.parent
LOCAL=ROOT/'.local'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def sources(archive,pin):
    if sha(archive)!=pin['archiveSHA256']:raise RuntimeError('WhatsApp Opus archive drift')
    output={};total=0
    with tarfile.open(archive) as source:
        for member in source:
            parts=Path(member.name).parts
            if not parts or parts[0]!='opus-'+pin['version'] or '..' in parts or (not member.isfile() and not member.isdir()):raise RuntimeError('Unsafe Opus archive')
            if not member.isfile():continue
            if member.size<0 or member.size>32*1024*1024:raise RuntimeError('Oversized Opus member')
            total+=member.size
            if total>128*1024*1024:raise RuntimeError('Oversized Opus source')
            relative=Path(*parts[1:])
            if relative in output:raise RuntimeError('Duplicate Opus member')
            output[relative]=source.extractfile(member).read()
    return output

def prepare():
    pin=json.loads((ROOT/'Dependencies/WhatsAppOpus.lock.json').read_text())
    if pin['schemaVersion']!=1 or not re.fullmatch(r'\d+\.\d+\.\d+',pin['version']) or pin['url']!='https://downloads.xiph.org/releases/opus/opus-'+pin['version']+'.tar.gz':raise RuntimeError('Invalid Opus pin')
    LOCAL.mkdir(exist_ok=True);archive=LOCAL/('whatsapp-opus-'+pin['version']+'.tar.gz')
    if not archive.exists():
        with urllib.request.urlopen(pin['url'],timeout=30) as response:payload=response.read(32*1024*1024+1)
        if len(payload)>32*1024*1024 or hashlib.sha256(payload).hexdigest()!=pin['archiveSHA256']:raise RuntimeError('Opus download checksum mismatch')
        archive.write_bytes(payload)
    files=sources(archive,pin)
    if hashlib.sha256(files[Path('COPYING')]).hexdigest()!=pin['licenseSHA256']:raise RuntimeError('Opus license drift')
    source=LOCAL/'whatsapp-opus-source'
    expected={str(p):hashlib.sha256(b).hexdigest()for p,b in files.items()}
    if source.is_symlink() or any(p.is_symlink() for p in source.rglob('*')):raise RuntimeError('Unsafe Opus source link')
    actual={str(p.relative_to(source)):sha(p)for p in source.rglob('*')if p.is_file()}if source.exists()else{}
    if actual!=expected:
        if source.exists():shutil.rmtree(source) # generated public source only
        source.mkdir()
        for path,payload in files.items():target=source/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(payload)
    build=LOCAL/'whatsapp-opus-build';install=LOCAL/'whatsapp-opus-install';env=dict(os.environ)
    for key in ['CMAKE_TOOLCHAIN_FILE','CMAKE_PROJECT_INCLUDE','CMAKE_PROJECT_INCLUDE_BEFORE','CC','CFLAGS','CXXFLAGS','LDFLAGS']:env.pop(key,None)
    if build.is_symlink() or install.is_symlink():raise RuntimeError('Unsafe Opus build link')
    args=['cmake','--fresh','-S',str(source),'-B',str(build),'-DCMAKE_INSTALL_PREFIX='+str(install)]
    args += ['-D'+key+'='+value for key,value in pin['cmakeOptions'].items()]
    subprocess.run(args,cwd=ROOT,env=env,check=True)
    subprocess.run(['cmake','--build',str(build),'-j','4'],cwd=ROOT,env=env,check=True)
    subprocess.run(['cmake','--install',str(build)],cwd=ROOT,env=env,check=True)
    if not (install/'lib/libopus.a').is_file():raise RuntimeError('Missing static Opus')
    return install/'lib'
if __name__=='__main__':prepare()
