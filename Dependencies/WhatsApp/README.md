# Separate WhatsApp protocol worker

MakoshWhatsAppWorker is a separate AGPL-3.0-only executable. No Rust code links
into Makosh's Swift executable. The public main application's licensing stays
unchanged. This worker adapts WhatsApp Zen (MIT); wacore-libsignal's Signal
Messenger AGPL source headers override its package's MIT declaration in our
license review. Original headers remain in registry-source in the accompanying
source archive. Dependencies/WhatsApp.lock.json lists the 31 affected files and
the precise package checksums, licenses, notices and reviewed build scripts.

The distribution must include MakoshWhatsAppWorker-Source.tar.gz and the license
texts. A normal Makosh build includes that source artifact in Resources and also
leaves a sibling copy in .build. The archive contains this crate, all 277 target
crate sources, the reviewed SDK patch and its prepared output, the independent lock/recipe and notices. It contains no account,
API pair, Keychain material, machine configuration or reference checkout.

Build with Apple Silicon macOS, Xcode command-line tools, Rust 1.97.0 and
Homebrew openssl@3 and CMake. From the source archive root (it includes the prepared public SDK at
`.local/whatsapp-engine`, as required by the Cargo patch path):

    python3 scripts/prepare-whatsapp-opus.py
    OPENSSL_DIR="$(brew --prefix openssl@3)" MACOSX_DEPLOYMENT_TARGET=26.0 \
      LIBOPUS_NO_PKG=1 OPUS_STATIC=1 OPUS_LIB_DIR="$PWD/.local/whatsapp-opus-install" \
      cargo build --locked --release --manifest-path Dependencies/WhatsApp/Cargo.toml

Cargo retrieves exact checksummed public registry packages from Cargo.lock. The
registry-source directory contains their corresponding source for inspection
and preservation; it is not an automatically executed vendor directory. In the
full Makosh checkout, scripts/prepare-whatsapp.py verifies the active dependency
graph, every published source file against its crate archive, excluded features,
notices and build scripts before building. It does not access .references. The SDK preparation uses its public crate
checksum, exact patch hash and per-file output hashes; see patches/README.md.
Use --test for offline native regressions and --sources for the source artifact.

IPC v1: private stdin/stdout, unsigned 32-bit big-endian byte length followed by
UTF-8 JSON. Requests ≤2MiB, replies ≤8MiB. One worker owns one account lease.
Envelope: {"op":"open"|"call"|"close","request":...}. Open request contains
version=1, absolute private directory and 32 key bytes. Open performs no network
connection. Call accepts snapshot/connect/disconnect/chats/messages/journal/ack and
explicit perform/command_result/call_media;
unsupported commands fail closed. Reply: {version:1,ok:true,data:...} or a fixed
public error code. QR lives in memory and expires. stdout is never a log;
stderr is suppressed by the private parent; no upstream logger is initialized.

Closing stdin gracefully closes the library session. Explicit close first
revokes further commands, awaits disconnect/flush and emits its receipt. The
parent enforces a bounded IPC wait; a failed/hung child is stopped with files
retained, never replaced or silently relinked. Each received chat message commits to
an encrypted FULL-synchronous SQLCipher journal before its protocol ack.
PostgreSQL archive and projection commit before the parent acknowledges the
journal sequence. Ack only advances a watermark; raw protocol and journal
records have no pruning or TTL. Block2 adds bounded media and personal call workflows, source-scoped commands,
receipts and retained status projection. Status acknowledgement follows the
consumer hook; expiry changes presentation only. No real network acceptance is claimed.


Native calls use independently pinned official Opus1.6.1, statically linked;
its archive, complete source, license and preparation recipe accompany this source
artifact. The registry audiopus_sys0.2.2 FFI has the INFO unmaintained advisory
[RUSTSEC-2026-0150](https://rustsec.org/advisories/RUSTSEC-2026-0150).
Its legacy bundled codec/CMake path is not executed. Source/build flags and an
actual native version regression bind the worker to the reviewed codec. This
mitigates that build boundary; it is not a claim that the FFI is maintained or an
exhaustive vulnerability audit. The official source/checksum is from
[Opus downloads](https://opus-codec.org/downloads/).
