#!/usr/bin/env python3
"""Prepare Makosh's locked Telegram engine independently of research checkouts.

No upstream installer is executed. Only committed SwiftPM packages are copied
from a separate bare source cache. No credentials or account data are read.
"""
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
from telegram_search_adaptation import adapt_search_source
from telegram_retention_adaptation import POSTBOX, HISTORY, adapt_retention_source, journal_source
from telegram_read_adaptation import READ_SYNC, adapt_read_source
from telegram_enqueue_adaptation import ENQUEUE, adapt_enqueue_source
from telegram_selection_adaptation import adapt_selection_source
from telegram_delete_adaptation import DELETE, adapt_delete_source
from telegram_draft_adaptation import DRAFT_HELPERS, adapt_draft_source
from telegram_topic_adaptation import TOPIC_SOURCES, adapt_topic_source

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / "Dependencies/TelegramEngine.lock.json").read_text())
if LOCK["schemaVersion"] != 1:
    raise RuntimeError("Unsupported Telegram dependency lock version")
if not all(re.fullmatch(r"[0-9a-f]{40}", LOCK[key]) for key in ("revision", "tree")):
    raise RuntimeError("Telegram dependency lock needs full commit and tree hashes")
SOURCE = ROOT / ".local/telegram-source.git"
DEST = ROOT / ".local/telegram-engine"
SHA = LOCK["revision"]
URL = LOCK["sourceURL"]
TREE = LOCK["tree"]
RECIPE = 14


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def source_git(*args, source=None):
    return ["git", "--no-replace-objects", "--git-dir", str(source or SOURCE), *args]


def verify_source(source):
    if source.is_symlink() or run(*source_git("rev-parse", "--is-bare-repository", source=source)) != "true":
        raise RuntimeError("Telegram source cache must be a separate bare repository")
    if run(*source_git("rev-parse", f"{SHA}^{{tree}}", source=source)) != TREE:
        raise RuntimeError("Telegram engine tree differs from the locked official-equivalent tree")


def prepare_source():
    if SOURCE.is_symlink():
        raise RuntimeError("Telegram source cache symlinks are refused")
    if SOURCE.exists():
        verify_source(SOURCE)
        return
    SOURCE.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="telegram-source-", dir=SOURCE.parent) as staging:
        source = Path(staging) / "repository.git"
        run("git", "init", "--bare", "--quiet", "--initial-branch=main", str(source))
        run(*source_git("fetch", "--depth", "1", "--no-tags", URL, SHA, source=source))
        if run(*source_git("rev-parse", "FETCH_HEAD", source=source)) != SHA:
            raise RuntimeError("Fetched Telegram source differs from locked revision")
        verify_source(source)
        source.rename(SOURCE)


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


def verify_prepared():
    if DEST.is_symlink():
        raise RuntimeError("Prepared engine directory symlinks are refused")
    if not DEST.exists():
        return False
    marker = DEST / "preparation.json"
    if marker.is_symlink() or not marker.is_file():
        raise RuntimeError("Existing engine directory has no regular preparation record")
    record = json.loads(marker.read_text())
    if (record.get("source_sha"), record.get("source_tree"), record.get("source_url"), record.get("recipe")) != (SHA, TREE, URL, RECIPE):
        raise RuntimeError("Existing engine preparation uses another pin or recipe; preserve/rename it before preparing again")
    if prepared_files(DEST) != record["prepared_files"]:
        raise RuntimeError("Prepared engine file set or content changed; preserve it before preparing again")
    return True


def main():
    # A verified prepared engine is sufficient for an offline repeat build.
    if verify_prepared():
        print("Telegram engine: pinned preparation verified")
        return
    prepare_source()

    pending = list(LOCK["packageRoots"])
    packages = set()
    pattern = re.compile(r'\.package\(name:\s*"[^"]+",\s*path:\s*"([^"]+)"\)')
    while pending:
        relative = pending.pop()
        if relative in packages:
            continue
        package = SOURCE / relative
        manifest = run(*source_git("show", f"{SHA}:{relative}/Package.swift"))
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
    archive = subprocess.check_output(source_git("archive", SHA, *sorted(packages), "README.md"))
    extract_committed(archive, DEST)
    search = DEST / "submodules/TelegramCore/Sources/TelegramEngine/Messages/SearchMessages.swift"
    search.write_text(adapt_search_source(search.read_text()))
    for relative in (POSTBOX, HISTORY):
        source = DEST / relative
        source.write_text(adapt_retention_source(relative, source.read_text()))
    postbox = DEST / POSTBOX
    postbox.write_text(adapt_selection_source(postbox.read_text()))
    (DEST / "submodules/Postbox/Sources/MakoshMessageJournal.swift").write_text(journal_source())
    read_sync = DEST / READ_SYNC
    read_sync.write_text(adapt_read_source(read_sync.read_text()))
    enqueue = DEST / ENQUEUE
    enqueue.write_text(adapt_enqueue_source(enqueue.read_text()))
    delete = DEST / DELETE
    delete.write_text(adapt_delete_source(delete.read_text()))
    for relative in DRAFT_HELPERS:
        source = DEST / relative
        source.write_text(adapt_draft_source(relative, source.read_text()))
    for relative in TOPIC_SOURCES:
        source = DEST / relative
        source.write_text(adapt_topic_source(relative, source.read_text()))
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
    (DEST / "preparation.json").write_text(json.dumps({"source_url": URL, "source_sha": SHA, "source_tree": TREE,
        "recipe": RECIPE, "packages": sorted(packages), "prepared_files": files,
        "adaptations": ["ManagedFile relative SSignalKit path", "Postbox never deletes session on open failure",
                        "OpenSSLEncryption SwiftPM uses EncryptionProvider and Homebrew OpenSSL 3",
                        "Authorization neither reads iCloud nor stores future-login tokens",
                        "Message search reports RPC failure without consuming either history cursor",
                        "Postbox records message snapshots before overwrite/removal in a durable same-transaction archive journal",
                        "Postbox restores all pending read synchronization operations using an integer-key table scan",
                        "Account and local outgoing enqueue share the native transaction core, admission and owned pending-upload receipt; inherited source fees are excluded from forwards",
                        "Postbox exposes a bounded cached native-ID range lookup without history fetches",
                        "Selected-message fresh admission and exact-ID deletion share one Postbox transaction",
                        "Existing native draft update and synchronization-operation helpers are public for same-transaction local/cloud persistence",
                        "Native seed rendering and forum operations validate bounded topic wire structure before legacy Postbox decoding",
                        "FlatSerialization generated with pinned official flatc 24.12.23"]}, indent=2) + "\n")
    print(f"Telegram engine: prepared {len(packages)} pinned packages in ignored local storage")


if __name__ == "__main__":
    main()
