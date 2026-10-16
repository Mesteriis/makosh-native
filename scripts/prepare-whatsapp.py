#!/usr/bin/env python3
"""Build the pinned separate worker. No research checkout or user session is read."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import runpy
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parent.parent
CRATE = ROOT / "Dependencies/WhatsApp"
LOCAL = ROOT / ".local"
PIN = ROOT / "Dependencies/WhatsApp.lock.json"

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(args, env, **kwargs):
    return subprocess.run(args, cwd=ROOT, env=env, check=True, **kwargs)

def prepare(test=False, sources=False):
    pin = json.loads(PIN.read_text())
    engine=runpy.run_path(str(ROOT/'scripts/prepare-whatsapp-engine.py'))['prepare']()
    if platform.machine() != "arm64" or sys.platform != "darwin":
        raise RuntimeError("WhatsApp worker requires Apple Silicon macOS")
    if digest(CRATE / "Cargo.lock") != pin["cargoLockSHA256"]:
        raise RuntimeError("WhatsApp Cargo.lock differs from reviewed pin")
    env = dict(os.environ)
    env.update(CARGO_HOME=str(LOCAL / "whatsapp-cargo"), CARGO_TARGET_DIR=str(LOCAL / "whatsapp-build"), MACOSX_DEPLOYMENT_TARGET=pin["deploymentTarget"])
    env.pop("RUSTFLAGS", None); env.pop("CARGO_ENCODED_RUSTFLAGS", None)
    # Build the independently pinned native Opus, never a machine-local codec.
    for name in ["LIBOPUS_LIB_DIR","OPUS_LIB_DIR","LIBOPUS_STATIC","OPUS_STATIC"]: env.pop(name,None)
    native_opus=pin["nativeOpus"]
    if digest(ROOT/native_opus["pin"])!=native_opus["sha256"]: raise RuntimeError("Native Opus pin drift")
    opus_library=runpy.run_path(str(ROOT/'scripts/prepare-whatsapp-opus.py'))['prepare']()
    env.update(LIBOPUS_NO_PKG="1",OPUS_STATIC="1",OPUS_LIB_DIR=str(opus_library.parent))
    for parent in [CRATE, *CRATE.parents, LOCAL / "whatsapp-cargo"]:
        if any((parent / name).exists() for name in [".cargo/config", ".cargo/config.toml", "config", "config.toml"]):
            raise RuntimeError("Unreviewed Cargo configuration is present")
    version=run(["rustc", "--version"],env,capture_output=True,text=True).stdout
    if not version.startswith("rustc " + pin["toolchain"] + " "):
        raise RuntimeError("Install the pinned Rust " + pin["toolchain"] + " toolchain")
    env["OPENSSL_DIR"]=run(["brew","--prefix","openssl@3"],env,capture_output=True,text=True).stdout.strip()
    args=["--manifest-path",str(CRATE/"Cargo.toml"),"--locked"]
    run(["cargo","fetch",*args],env)
    meta=json.loads(run(["cargo","metadata",*args,"--offline","--filter-platform",pin["target"],"--format-version","1"],env,capture_output=True,text=True).stdout)
    # audiopus_sys does not track these environment inputs. Invalidate only its
    # owned target cache when the reviewed native link material changes.
    stamp=LOCAL/"whatsapp-build/native-opus-stamp.json"
    current={"pin":native_opus["sha256"],"library":digest(opus_library/"libopus.a"),"path":str(opus_library)}
    if not stamp.exists() or json.loads(stamp.read_text())!=current:
        run(["cargo","clean","--manifest-path",str(CRATE/"Cargo.toml"),"--package","audiopus_sys","--offline"],env)
        stamp.parent.mkdir(parents=True,exist_ok=True);stamp.write_text(json.dumps(current,sort_keys=True))
    active={node["id"] for node in meta["resolve"]["nodes"]}
    packages={(p["name"],p["version"]):p for p in meta["packages"] if p["id"] in active and p["name"]!="makosh-whatsapp"}
    if set(packages)!={(p["name"],p["version"]) for p in pin["packages"]}:
        raise RuntimeError("Unreviewed WhatsApp dependency graph")
    for node in meta["resolve"]["nodes"]:
        if any(f in pin["excludedFeatures"] for f in node["features"]):
            raise RuntimeError("Excluded protocol feature enabled")
    for package in pin["packages"]:
        actual=packages[(package["name"],package["version"])]
        node=next(n for n in meta["resolve"]["nodes"] if n["id"]==actual["id"])
        if sorted(node["features"])!=package["features"]: raise RuntimeError("Unreviewed dependency features")
        if actual["license"]!=package["declaredLicense"]: raise RuntimeError("License drift")
        base=Path(actual["manifest_path"]).parent
        for item in package["buildScripts"]+package["AGPLSourceHeaders"]:
            if digest(base/item["path"])!=item["sha256"]: raise RuntimeError("Reviewed source drift")
        # Registry sources may be writable locally. Validate every published file,
        # not just Cargo's version string or an old build stamp.
        if base!=engine:
            if actual['source'] is None: raise RuntimeError('Unreviewed local dependency')
            archive=base.parent.parent.parent/"cache"/base.parent.name/(base.name+".crate")
            if digest(archive)!=package["checksum"]: raise RuntimeError("Registry checksum drift")
            with tarfile.open(archive) as published:
                for member in published.getmembers():
                    if not member.isfile(): continue
                    parts=Path(member.name).parts
                    if len(parts)<2 or parts[0]!=base.name or ".." in parts: raise RuntimeError("Invalid registry archive path")
                    stream=published.extractfile(member)
                    if stream is None or digest(base/Path(*parts[1:]))!=hashlib.sha256(stream.read()).hexdigest():
                        raise RuntimeError("Registry source drift")
        for item in package["notices"]:
            if digest(ROOT/item["path"])!=item["sha256"]: raise RuntimeError("Notice drift")
    for item in pin["notices"]:
        if digest(ROOT/item["path"])!=item["sha256"]: raise RuntimeError("Worker notice drift")
    if test: run(["cargo","test",*args,"--offline","-j","4"],env)
    run(["cargo","build",*args,"--offline","--release","--bin","MakoshWhatsAppWorker","-j","4"],env)
    output=LOCAL/"whatsapp-runtime";output.mkdir(parents=True,exist_ok=True)
    binary=output/"MakoshWhatsAppWorker"
    temporary=output/'MakoshWhatsAppWorker.next'
    shutil.copy2(LOCAL/"whatsapp-build/release/MakoshWhatsAppWorker",temporary)
    os.replace(temporary,binary)
    run(["codesign","--force","--sign","-",str(binary)],env)
    if sources:
        archive=ROOT/".build/MakoshWhatsAppWorker-Source.tar.gz";archive.parent.mkdir(exist_ok=True)
        with tarfile.open(archive,"w:gz") as target:
            for path in [CRATE,PIN,ROOT/"scripts/prepare-whatsapp.py",ROOT/"scripts/prepare-whatsapp-engine.py",ROOT/"LICENSES/WhatsApp-Zen-MIT.txt",ROOT/"LICENSES/Makosh-MIT.txt",ROOT/"LICENSES/WhatsApp-Worker-AGPL-3.0.txt",ROOT/"LICENSES/WhatsApp-dependencies",ROOT/"Dependencies/WhatsAppOpus.lock.json",ROOT/"scripts/prepare-whatsapp-opus.py",LOCAL/"whatsapp-opus-source",LOCAL/"whatsapp-opus-1.6.1.tar.gz",engine]:
                target.add(path,arcname=str(path.relative_to(ROOT)))
            for package in packages.values():
                base=Path(package["manifest_path"]).parent
                target.add(base,arcname="registry-source/"+package["name"]+"-"+package["version"])
        print("Separate corresponding source: .build/MakoshWhatsAppWorker-Source.tar.gz")
    print("WhatsApp worker: pinned graph, notices and native build verified")

if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--test",action="store_true");parser.add_argument("--sources",action="store_true");options=parser.parse_args()
    try: prepare(options.test,options.sources)
    except (OSError,ValueError,RuntimeError,subprocess.CalledProcessError) as error:
        # Public build diagnostics only; this recipe never opens runtime account data.
        raise SystemExit("WhatsApp preparation failed: "+str(error)) from None
