# Makosh licensing and third-party notices

The combined Telegram-enabled application is distributed under **GNU GPL v3**
([LICENSE](LICENSE)). Independently authored Makosh sources remain available
under [MIT](LICENSES/Makosh-MIT.txt); that grant does not relicense upstream code
or make the combined executable MIT. Upstream notices remain in prepared source.

## Telegram engine provenance

The selected reference is [overtake/TelegramSwift](https://github.com/overtake/TelegramSwift)
at `579cebbf0c01fd41b712eff3647fa7f69db9665d`. Its `submodules/telegram-ios`
gitlink pins [overtake/Telegram-iOS](https://github.com/overtake/Telegram-iOS)
at `a24bbe45f9861f736a79916a50898512f751e0dc`.

That entire Git tree is identical to official TelegramMessenger/Telegram-iOS
commit [`0699602bbc2756d1feaeb67df485e376dce44ad2`](https://github.com/TelegramMessenger/Telegram-iOS/tree/0699602bbc2756d1feaeb67df485e376dce44ad2):
tree `0beebf847c66e5d1bcfe3e2d7f28054ca7b8fbe0`, zero differing blobs,
including all 21 selected SwiftPM manifests. This resolves the fork-specific
license uncertainty for the selected engine source. The [official Telegram
source page](https://telegram.org/apps) grants the iOS source under GPL v2 or
later; Makosh elects GPL v3 for the combination. The outer macOS TelegramSwift
UI is GPL v2 and is **not copied or linked**. No Telegram branding assets,
embedded API credentials, private configuration or existing account databases
are imported. Makosh is an unofficial client.

`Dependencies/TelegramEngine.lock.json` independently pins that same source for
Makosh builds. `scripts/prepare-telegram.py` fetches the exact commit into its
own ignored bare Git cache, checks SHA/tree, copies only committed regular files,
adapts a separate ignored working copy and records every prepared file's SHA256.
Reuse requires an identical file set, content and full source pin; it needs no
research checkout or source-cache/network access. The research references are
never patched or consulted by the build. The preparation record lists all selected
packages: TelegramCore (including FlatBuffers/FlatSerialization), Postbox,
SSignalKit, MtProtoKit, TelegramApi, CryptoUtils, NetworkLogging, Reachability/
LegacyReachability, DarwinDirStat, EncryptionProvider, Emoji, MurMurHash32,
Crc32, SQLCipher, StringTransliteration, ManagedFile, RangeSet, and
OpenSSLEncryptionProvider.

Build adaptations in the generated copy:

- Correct ManagedFile's relative SSignalKit dependency.
- Prevent Postbox from deleting the session database after an open failure.
- Disable iCloud login-token reads and future-login-token storage.
- Distinguish message-search RPC failure from an empty/completed result, preserving
  both search cursors on failure. The bounded GPL adaptation is tracked in
  `scripts/telegram_search_adaptation.py`; preparation verifies input and output hashes.
- Record message snapshots before overwrite/removal and after central history
  writes in the same Postbox transaction. Recipe 4 adds the durable journal in
  `scripts/telegram-retention/MakoshMessageJournal.swift` through the hash-checked
  `scripts/telegram_retention_adaptation.py`. Both are GPL-3.0-or-later engine
  adaptations. Exact-sequence acknowledgement follows independent archive commit;
  this does not claim capture of updates optimized before Postbox or media bytes.
- Link OpenSSLEncryptionProvider explicitly to Homebrew OpenSSL 3, using its
  Apache-2.0 implementation rather than the upstream Bazel BoringSSL target.
- Generate FlatSerialization using official `flatc 24.12.23`; source archive
  SHA256 `c5cd6a605ff20350c7faa19d8eeb599df6117ea4aabd16ac58a7eb5ba82df4e7`,
  as pinned in the upstream `MODULE.bazel`. Generator source is downloaded,
  checksum-verified and built locally; unknown cached binaries are refused.

## Included license texts and attributions

| Component | License / retained notice |
| --- | --- |
| Telegram-iOS general engine source and Makosh engine adaptations | GPL v2-or-later, GPL v3 elected; [GPL v3 text](LICENSES/GPL-3.0.txt) |
| Google FlatBuffers, including local build tool | [Apache 2.0](LICENSES/Apache-2.0.txt), [source copyright header](LICENSES/FlatBuffers-Google-Apache-header.notice) |
| Swift RangeSet, Apple Inc. and Swift project authors | [Apache 2.0 with Runtime Library Exception](LICENSES/Swift-Apache-2.0-with-Runtime-Library-Exception.txt), [source header](LICENSES/RangeSet-source-header.notice) |
| Postbox's SQLite.swift-derived database wrapper, Stephen Celis | [MIT copyright and grant](LICENSES/SQLite-swift-Stephen-Celis-MIT.notice) |
| SQLCipher portions, Zetetic LLC | [BSD 3-Clause copyright and grant](LICENSES/SQLCipher-Zetetic-BSD-3-Clause.notice) |
| SQLite portions | Public domain; original blessing retained in prepared `sqlite3.c` |
| Apple Reachability sample portions | [Apple sample-code license](LICENSES/Apple-Reachability-LICENSE.txt); wrapper source retains its upstream notices |
| Dynamically linked local OpenSSL 3 (verified local version 3.6.4) | [Release license](LICENSES/OpenSSL-3.6.4-LICENSE.txt), Apache 2.0; source: [official release](https://github.com/openssl/openssl/tree/openssl-3.6.4) |
| Independently authored Makosh code | [MIT](LICENSES/Makosh-MIT.txt) |

Apache 2.0 is compatible with GPL v3 according to the [Apache licensing FAQ](https://www.apache.org/foundation/license-faq.html#GPL).
Full GPL text was obtained from the GNU project's [GCC mirror COPYING3](https://github.com/gcc-mirror/gcc/blob/master/COPYING3).
Reachability text is from Apple's [published sample license](https://developer.apple.com/library/archive/samplecode/Reachability/Listings/LICENSE_txt.html); only trailing whitespace on blank lines was removed.

## Distribution boundary

Development object storage uses the external [SeaweedFS 4.48 service](https://github.com/seaweedfs/seaweedfs/tree/530be3e37337488ecc34d58441e0bc476e121c93), copyright Chris Lu, under [Apache 2.0](LICENSES/Apache-2.0.txt). Its image digest and official macOS CI archive checksums are pinned in `Dependencies/ObjectStorage.lock.json`. SeaweedFS and its bundled image dependencies are downloaded from the upstream distribution and are not linked into or republished with Makosh source/app bundles. The narrow SigV4 client and encrypted file format are independently authored Makosh code; AWS public example signing vectors are used only for synthetic tests.

This repository publishes Makosh source, build adaptations and notices. Prepared
engine files, generator caches and local app bundles remain ignored; no binary
release is published. The local development bundle dynamically links installed
Homebrew libpq and OpenSSL and is ad-hoc signed. Before distributing a standalone
binary, provide the complete corresponding source for its exact engine/build,
all selected dependency copyright notices and sources as required, and audited
packaging of the actual libpq/OpenSSL versions. A local ignored checkout or a
generic license URL alone does not fulfill binary-source delivery obligations.
