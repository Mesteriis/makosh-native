#!/usr/bin/env python3
"""Relocate an audited Mach-O dependency closure into an owned application bundle."""
import argparse, hashlib, json, re, shutil, subprocess, sys
from pathlib import Path

def run(*args):
    return subprocess.check_output(args,text=True,stderr=subprocess.PIPE)
def dependencies(binary):
    return [re.sub(r' \(compatibility version.*$', '', line.strip()) for line in run('otool','-L',str(binary)).splitlines()[1:]]
def within(path, root):
    return path == root or root in path.parents

def bundle(app, roots, replacement=None):
    app=app.resolve(); frameworks=app/'Contents/Frameworks'; executables=app/'Contents/MacOS'
    if not executables.is_dir(): raise ValueError('Application executable directory missing')
    roots=[p.resolve() for p in roots]
    helpers=app/'Contents/Helpers'
    starts=list(executables.iterdir()) + (list(frameworks.glob('*.dylib')) if frameworks.exists() else []) + (list(helpers.iterdir()) if helpers.exists() else [])
    starts=[p for p in starts if p.is_file()]
    if not starts: raise ValueError('No executable code')
    planned={}; edges={}; seen=set(); queue=list(starts)
    while queue:
        binary=queue.pop(0).resolve()
        if binary in seen: continue
        seen.add(binary); run('lipo','-verify_arch','arm64',str(binary)); edges[binary]=[]
        for dependency in dependencies(binary):
            if dependency.startswith(('/usr/lib/','/System/Library/')): continue
            if dependency.startswith('@loader_path/'):
                source=binary.parent/dependency.removeprefix('@loader_path/')
            elif dependency.startswith('@executable_path/'):
                source=executables/dependency.removeprefix('@executable_path/')
            elif dependency.startswith('@rpath/'):
                source=frameworks/dependency.removeprefix('@rpath/')
            elif dependency.startswith('/'):
                source=Path(dependency)
            else: raise ValueError('Unresolved dependency kind')
            if source.name == 'libpq.5.dylib' and replacement is not None: source=replacement
            source=source.resolve()
            if not source.is_file(): raise ValueError('Dependency is missing: '+source.name)
            if not within(source,app) and not any(within(source,r) for r in roots): raise ValueError('Dependency outside reviewed roots: '+source.name)
            name=Path(dependency).name
            if name in planned and planned[name] != source:
                if hashlib.sha256(planned[name].read_bytes()).digest()!=hashlib.sha256(source.read_bytes()).digest(): raise ValueError('Conflicting dependency basename: '+name)
            planned[name]=source; edges[binary].append((dependency,name)); queue.append(source)
    # Preflight completes before any original executable is changed.
    frameworks.mkdir(parents=True,exist_ok=True)
    destinations={p.resolve():p for p in starts}
    for name,source in planned.items():
        destination=frameworks/name
        if source != destination.resolve(): shutil.copy2(source,destination)
        destinations[source]=destination
    for source, links in edges.items():
        destination=destinations[source]
        if destination.suffix=='.dylib': run('install_name_tool','-id','@rpath/'+destination.name,str(destination))
        prefix='@executable_path/../Frameworks/' if destination.parent==executables else ('@loader_path/../Frameworks/' if destination.parent==helpers else '@loader_path/')
        for old,name in links:
            new=prefix+name
            if old!=new: run('install_name_tool','-change',old,new,str(destination))
    for binary in sorted(set(destinations.values())):
        for dep in dependencies(binary):
            if dep.startswith('/') and not dep.startswith(('/usr/lib/','/System/Library/')): raise ValueError('External runtime path remained')
        if binary.suffix=='.dylib' or binary.parent==helpers: run('codesign','--force','--sign','-',str(binary))
    inventory=[{'name':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(frameworks.glob('*.dylib'))]
    resource=app/'Contents/Resources'; resource.mkdir(parents=True,exist_ok=True)
    (resource/'runtime-libraries.json').write_text(json.dumps(inventory,indent=2)+'\n')
    print('Runtime closure bundled: '+str(len(inventory))+' ARM64 libraries')

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--bundle',type=Path,required=True); parser.add_argument('--allow-root',type=Path,action='append',required=True); parser.add_argument('--replace-libpq',type=Path)
    args=parser.parse_args()
    try: bundle(args.bundle,args.allow_root,args.replace_libpq)
    except (ValueError,OSError,subprocess.CalledProcessError) as error:
        print('Runtime packaging refused: '+str(error),file=sys.stderr); return 1
    return 0
if __name__=='__main__': sys.exit(main())
