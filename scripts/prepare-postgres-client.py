#!/usr/bin/env python3
"""Build the reviewed portable libpq client only. No server or installer is run."""
import hashlib, json, os, shutil, subprocess, sys, tarfile, urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def inventory(root):
    result={}
    for path in sorted(root.rglob('*')):
        if path.is_symlink(): raise ValueError('Unexpected source symlink')
        if path.is_file(): result[str(path.relative_to(root))]=digest(path)
    return result

def main():
    lock_path=ROOT/'Dependencies/MacRuntime.lock.json'; lock=json.loads(lock_path.read_text()); pg=lock['postgresql']; ssl=lock['openssl']
    prefix=ROOT/'.local/postgres-client'; prefix.mkdir(parents=True,exist_ok=True)
    source=prefix/'source'/('postgresql-'+pg['version']); state_path=prefix/'verified.json'; library=prefix/'lib/libpq.5.dylib'
    recipe=hashlib.sha256(Path(__file__).read_bytes()+lock_path.read_bytes()).hexdigest()
    for item in [pg,ssl]:
        if digest(ROOT/item['copyright'])!=item['copyrightSHA256']: raise ValueError('Runtime copyright pin mismatch')
    openssl_prefix=Path(subprocess.check_output(['brew','--prefix','openssl@3'],text=True).strip())
    if subprocess.check_output(['pkg-config','--modversion','openssl'],text=True).strip()!=ssl['version']: raise ValueError('Unreviewed OpenSSL version')
    if digest(openssl_prefix/'LICENSE.txt')!=ssl['copyrightSHA256']: raise ValueError('Installed OpenSSL copyright mismatch')
    if state_path.exists():
        state=json.loads(state_path.read_text())
        if state['source']!=inventory(source): raise ValueError('Prepared PostgreSQL source changed; preserve it and repair the recipe')
        if state['recipe']==recipe and library.is_file() and digest(library)==state['library']:
            print('Portable libpq '+pg['version']+': pinned source/runtime verified'); return 0
    archive=prefix/'source.tar.bz2'
    if not archive.exists():
        with urllib.request.urlopen(pg['url'],timeout=45) as response: data=response.read(60*1024*1024+1)
        if len(data)>60*1024*1024: raise ValueError('Source archive too large')
        if hashlib.sha256(data).hexdigest()!=pg['sha256']: raise ValueError('PostgreSQL archive checksum mismatch')
        archive.write_bytes(data)
    if digest(archive)!=pg['sha256']: raise ValueError('Cached source archive checksum mismatch')
    if not source.exists():
        with tarfile.open(archive) as stream: stream.extractall(prefix/'source',filter='data')
    if digest(source/'COPYRIGHT')!=pg['copyrightSHA256']: raise ValueError('PostgreSQL source copyright mismatch')
    before=inventory(source)
    build=prefix/'build'; build.mkdir(exist_ok=True)
    env=dict(os.environ); bison=subprocess.check_output(['brew','--prefix','bison'],text=True).strip()
    env['PATH']=bison+'/bin:'+env['PATH']; env['CFLAGS']='-O2 -mmacosx-version-min=26.0'
    env['CPPFLAGS']='-I'+str(openssl_prefix/'include'); env['LDFLAGS']='-L'+str(openssl_prefix/'lib')+' -mmacosx-version-min=26.0'
    flags=['--prefix='+str(prefix),'--with-ssl=openssl','--without-gssapi','--without-ldap','--without-icu','--without-readline','--without-zlib','--without-lz4','--without-zstd']
    with (prefix/'preparation.log').open('w') as log:
        subprocess.run([str(source/'configure'),*flags],cwd=build,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        subprocess.run(['make','-C','src/interfaces/libpq','-j4'],cwd=build,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    if before!=inventory(source): raise ValueError('Build modified pinned source')
    library.parent.mkdir(exist_ok=True); shutil.copy2(build/'src/interfaces/libpq/libpq.5.dylib',library)
    dependencies=subprocess.check_output(['otool','-L',str(library)],text=True)
    if any(value in dependencies for value in ['krb5','ldap','libcurl']): raise ValueError('Unreviewed portable runtime dependency')
    subprocess.run(['lipo','-verify_arch','arm64',str(library)],check=True,capture_output=True)
    state_path.write_text(json.dumps({'recipe':recipe,'source':before,'library':digest(library)},indent=2)+'\n')
    print('Portable libpq '+pg['version']+': client built; GSSAPI/LDAP/server excluded')
    return 0
if __name__=='__main__':
    try: sys.exit(main())
    except (OSError,ValueError,subprocess.CalledProcessError) as error:
        print('Portable PostgreSQL preparation refused: '+str(error),file=sys.stderr); sys.exit(1)
