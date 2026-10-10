#!/usr/bin/env python3
"""Prepare the exact TelegramSwift engine gitlink in ignored local storage.

No upstream installer is executed. Only reviewed SwiftPM packages are copied;
the original checkout is never patched. No credentials or account data are read.
"""
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / ".references/TelegramSwift/submodules/telegram-ios"
DEST = ROOT / ".local/telegram-engine"
SHA = "a24bbe45f9861f736a79916a50898512f751e0dc"
URL = "https://github.com/overtake/Telegram-iOS.git"
TREE = "0beebf847c66e5d1bcfe3e2d7f28054ca7b8fbe0"
RECIPE = 2


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def replace_exact(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise RuntimeError(f"Unexpected upstream patch context: {path.name}")
    path.write_text(text.replace(old, new))


def prepared_files(directory):
    files = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("Prepared engine contains a symlink")
        if path.is_file() and path != directory / "preparation.json":
            files[str(path.relative_to(directory))] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif not path.is_dir() and not path.is_file():
            raise RuntimeError("Prepared engine contains a special file")
    return files


def extract_committed(archive, destination):
    """Extract regular Git blobs only; never import untracked working-tree files."""
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
        members = source.getmembers()
        for member in members:
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or not (member.isdir() or member.isfile()):
                raise RuntimeError("Unsupported path or file type in pinned Git archive")
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as payload:
                    target.write_bytes(payload.read())


def main():
    if not (SOURCE / ".git").exists():
        SOURCE.mkdir(parents=True, exist_ok=True)
        run("git", "init", str(SOURCE))
        run("git", "-C", str(SOURCE), "remote", "add", "origin", URL)
        run("git", "-C", str(SOURCE), "fetch", "--depth", "1", "origin", SHA)
        run("git", "-C", str(SOURCE), "checkout", "--detach", "FETCH_HEAD")
    if run("git", "-C", str(SOURCE), "rev-parse", "HEAD") != SHA:
        raise RuntimeError("Telegram engine checkout differs from pinned gitlink")
    if run("git", "-C", str(SOURCE), "rev-parse", "HEAD^{tree}") != TREE:
        raise RuntimeError("Telegram engine tree differs from verified official ancestor")
    if run("git", "-C", str(SOURCE), "status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError("Telegram engine checkout has tracked modifications")
    marker = DEST / "preparation.json"
    if DEST.exists():
        if not marker.exists():
            raise RuntimeError("Existing engine directory has no preparation record")
        record = json.loads(marker.read_text())
        if record["source_sha"] != SHA or record.get("recipe") != RECIPE:
            raise RuntimeError("Existing engine preparation uses another revision or recipe; preserve/rename it before preparing again")
        if prepared_files(DEST) != record["prepared_files"]:
            raise RuntimeError("Prepared engine file set or content changed; preserve it before preparing again")
        print("Telegram engine: pinned preparation verified")
        return

    pending = ["submodules/TelegramCore", "submodules/OpenSSLEncryptionProvider"]
    packages = set()
    pattern = re.compile(r'\.package\(name:\s*"[^"]+",\s*path:\s*"([^"]+)"\)')
    while pending:
        relative = pending.pop()
        if relative in packages:
            continue
        package = SOURCE / relative
        manifest = run("git", "-C", str(SOURCE), "show", f"HEAD:{relative}/Package.swift")
        active_manifest = "\n".join(line for line in manifest.splitlines() if not line.lstrip().startswith("//"))
        if ".package(url:" in active_manifest:
            raise RuntimeError("Unreviewed remote dependency in engine package")
        packages.add(relative)
        for dependency in pattern.findall(active_manifest):
            if relative == "submodules/ManagedFile":
                dependency = "../SSignalKit"
            target = (package / dependency).resolve()
            if not target.is_relative_to(SOURCE.resolve()):
                raise RuntimeError("Engine dependency escapes pinned checkout")
            pending.append(str(target.relative_to(SOURCE.resolve())))
    DEST.mkdir(parents=True)
    archive = subprocess.check_output(["git", "-C", str(SOURCE), "archive", "HEAD", *sorted(packages), "README.md"])
    extract_committed(archive, DEST)
    replace_exact(DEST / "submodules/ManagedFile/Package.swift",
                  '../../submodules/telegram-ios/submodules/SSignalKit', '../SSignalKit')
    replace_exact(DEST / "submodules/TelegramCore/Sources/Account/Account.swift",
                  'removeDatabaseOnError: !supplementary', 'removeDatabaseOnError: false')
    authorization = DEST / "submodules/TelegramCore/Sources/Authorization.swift"
    auth_text = authorization.read_text()
    start = auth_text.index('func storeFutureLoginToken(')
    end = auth_text.index('public struct AuthorizationCodePushNotificationConfiguration', start)
    auth_text = auth_text[:start] + '''// Makosh: no iCloud or reusable future-login tokens; this session is separate.
func storeFutureLoginToken(accountManager: AccountManager<TelegramAccountManagerTypes>, token: Data) {}

''' + auth_text[end:]
    cloud_block = '''    var cloudValue: [Data] = []
    if let list = NSUbiquitousKeyValueStore.default.object(forKey: "T_SLTokens") as? [String] {
        cloudValue = list.compactMap { string -> Data? in
            guard let stringData = string.data(using: .utf8) else {
                return nil
            }
            return Data(base64Encoded: stringData)
        }
    }
'''
    if auth_text.count(cloud_block) != 1:
        raise RuntimeError("Unexpected authorization cloud-token patch context")
    authorization.write_text(auth_text.replace(cloud_block, '    let cloudValue: [Data] = []\n'))
    provider = DEST / "submodules/OpenSSLEncryptionProvider"
    (provider / "Package.swift").write_text('''// swift-tools-version:5.5
// Makosh build adaptation of the pinned Telegram-iOS package manifest.
import PackageDescription
let package = Package(name: "OpenSSLEncryption", platforms: [.macOS(.v10_13)],
    products: [.library(name: "OpenSSLEncryption", targets: ["OpenSSLEncryption"])],
    dependencies: [.package(name: "EncryptionProvider", path: "../EncryptionProvider")],
    targets: [
        .systemLibrary(name: "COpenSSL", path: "COpenSSL", pkgConfig: "openssl", providers: [.brew(["openssl@3"])]),
        .target(name: "OpenSSLEncryption", dependencies: ["COpenSSL", .product(name: "EncryptionProvider", package: "EncryptionProvider")],
                path: ".", exclude: ["BUILD", "COpenSSL"], publicHeadersPath: "PublicHeaders")])
''')
    headers = provider / "COpenSSL"
    headers.mkdir()
    (headers / "module.modulemap").write_text('module COpenSSL [system] { header "shim.h" link "crypto" export * }\n')
    (headers / "shim.h").write_text('#include <openssl/bn.h>\n#include <openssl/rsa.h>\n#include <openssl/pem.h>\n')
    subprocess.run([sys.executable, str(ROOT / "scripts/prepare-telegram-flatc.py")], check=True)
    flatc = ROOT / ".local/telegram-flatc/build/flatc"
    if run(str(flatc), "--version") != "flatc version 24.12.23":
        raise RuntimeError("Unexpected FlatBuffers compiler version")
    serialization = DEST / "submodules/TelegramCore/FlatSerialization"
    generated = serialization / "Sources"
    generated.mkdir()
    subprocess.run([str(flatc), "--require-explicit-ids", "--swift", "-o", str(generated),
                    *[str(p) for p in sorted((serialization / "Models").glob("*.fbs"))]], check=True)
    (DEST / "README.md").rename(DEST / "UPSTREAM-README.md")
    files = prepared_files(DEST)
    marker.write_text(json.dumps({"source_url": URL, "source_sha": SHA, "source_tree": TREE,
        "recipe": RECIPE, "packages": sorted(packages), "prepared_files": files,
        "adaptations": ["ManagedFile relative SSignalKit path", "Postbox never deletes session on open failure",
                        "OpenSSLEncryption SwiftPM uses EncryptionProvider and Homebrew OpenSSL 3",
                        "Authorization neither reads iCloud nor stores future-login tokens",
                        "FlatSerialization generated with pinned official flatc 24.12.23"]}, indent=2) + "\n")
    print(f"Telegram engine: prepared {len(packages)} pinned packages in ignored local storage")


if __name__ == "__main__":
    main()
