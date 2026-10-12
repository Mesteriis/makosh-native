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
- Restore pending read-state synchronization after reopening Postbox. Recipe 5
  replaces the full-table `0...-1` signed SQLite range with `scanInt64`, preserving
  exact integer peer keys. The GPL-3.0-or-later patch context is tracked in
  `scripts/telegram_read_adaptation.py` with exact input/output SHA256 checks.
  No database schema change or source-cache dependency is introduced.
- Add optional admission/commit hooks to the ordinary outgoing enqueue API.
  Recipe 6 keeps the upstream media transformation and queue algorithm, while
  allowing Makosh to validate its pending pointer before enqueue and save its
  receipt in the same Postbox transaction. Existing callers use nil defaults.
  The GPL-3.0-or-later patch in `scripts/telegram_enqueue_adaptation.py` checks
  exact input/output SHA256; no generated engine source is edited by hand.
  Recipe 9 shares that transaction wrapper and native construction core with a
  local entry point requiring Postbox and three scalar Account inputs. The
  production transformation and lazy clock read stay in place. Reverse scalar
  substitution must recover the exact original native-body SHA256; local tests
  need neither Account construction nor network managers. Recipe12 excludes
  `PaidStarsMessageAttribute` only from a forwarded source message's inherited
  attributes. Explicit requested attributes retain the new consented charge.
  Tests reverse this one exact change before checking the original native-body
  hash, and real local-queue tests cover free Saved and a newly priced recipient.
- Expose a cached numeric-ID index lookup on Postbox transactions. Recipe 7
  composes the exact recipe-4 journal file with the GPL-3.0-or-later adaptation
  in `scripts/telegram_selection_adaptation.py`, checking both file hashes.
  Shift selection uses two bounded Cloud/Local reads (at most 200 each), without
  scanning missing integers, allocating all cached history or fetching network
  history. No schema or dependency pin changes are introduced.
- Add selected-message admission beside the native delete implementation.
  Recipe 8 retains the native operation log and removal paths, validating the
  complete frozen batch inside the same Postbox transaction before mutation.
  Only exact selected IDs are passed, without expanding albums. The own
  GPL-3.0-or-later addition in `scripts/telegram_delete_adaptation.py` is bound
  to exact input/output SHA256 and retains all previous adaptations.
- Expose the existing chat-input update and synchronization-operation helpers.
  Recipe10 changes only their visibility, through exact input/output hashes in
  `scripts/telegram_draft_adaptation.py`. The native draft serialization and
  synchronization algorithm remain upstream; local composer/basis changes are
  committed in the same Postbox transaction. Recipe11 also makes Postbox draft
  observation compare encoded draft data when the timestamp is unchanged; this
  prevents a same-timestamp edit from being hidden from observers. The adapter
  verifies the exact original and resulting file hashes for both changes.
- Bound retained topic decoding before legacy pointer reads. Recipe14 adds an
  own wire/semantic preflight in `scripts/telegram_topic_adaptation.py`, used by
  native seed rendering, forum operations and Makosh admission. Exact original
  and resulting SHA256 cover both adapted source files. It rejects truncated
  lengths/tags, unsupported profiles, invalid notification variants, overflowing
  bundled sound IDs and noncanonical author bits; pinned source remains unchanged.
- Link OpenSSLEncryptionProvider explicitly to Homebrew OpenSSL 3, using its
  Apache-2.0 implementation rather than the upstream Bazel BoringSSL target.
- Generate FlatSerialization using official `flatc 24.12.23`; source archive
  SHA256 `c5cd6a605ff20350c7faa19d8eeb599df6117ea4aabd16ac58a7eb5ba82df4e7`,
  as pinned in the upstream `MODULE.bazel`. Generator source is downloaded,
  checksum-verified and built locally; unknown cached binaries are refused.

## Portable syntax highlighting provenance

`Dependencies/CodeHighlight.lock.json` independently pins
[desktop-app/libprisma](https://github.com/desktop-app/libprisma/tree/23b0d70f9709da9b38561d5706891a134d18df76)
at `23b0d70f9709da9b38561d5706891a134d18df76` (MIT), and
[Boost.Regex](https://github.com/boostorg/regex/tree/237e69caf65906d0313c9b852541b07fa84a99c1)
at `237e69caf65906d0313c9b852541b07fa84a99c1` (Boost Software License1.0).
Exact Git trees,115 source/provenance blob hashes and the prepared121-file
fingerprint are pinned. The complete committed `grammars.dat` is embedded;
`generate.js`, npm and unpinned grammar downloads are never run. Only four
portable C++ compilation units and the reviewed standalone regex headers link.

`scripts/telegram_code_highlight_adaptation.py` contains Makosh's own exact-hash
adaptations for weak grammar references, bounded work/depth/token allocations,
exception-safe abort/cleanup and complete alias lookup. The own C boundary
returns only source-bound byte spans; Swift validates UTF16 conversion and keeps
spoiler/link protection. Cooperative cancellation/work limits are not a hard
real-time execution guarantee. MIT and Boost notices are retained in prepared
source and bundled `Resources/Licenses`.

## Portable animated emoji provenance

`Dependencies/RLottie.lock.json` independently pins
[TelegramMessenger/rlottie](https://github.com/TelegramMessenger/rlottie/tree/67f103bc8b625f2a4a9e94f1d8c7bd84c5a08d1d)
at `67f103bc8b625f2a4a9e94f1d8c7bd84c5a08d1d`, archive SHA256
`2b75c791781c3f61f7fd5348c74d09406a0f8d7be4067830986fab6f82b9129e`.
RLottie is **LGPL2.1-or-later**, not MIT. Its reviewed portable closure contains
31 C++ units and72 headers plus six source notices. The prepared package adds
only Makosh's fixed configuration, module header/map and SwiftPM manifest.
No upstream build/configure scripts or research checkouts participate.

The included FreeType-derived rasterizer uses the FreeType License; **this
software uses FreeType**. Pixman and RapidJSON portions retain their respective
MIT notices. STB and RapidJSON's Windows integer headers are excluded from the
compilation closure; the archived STB notice is retained for provenance.
`LICENSES/RLottie-source-notices.txt` includes the full LGPL, FreeType, Pixman and
RapidJSON notices and is bundled in `Resources/Licenses`. The combined app
elects GPLv3 consistently with the engine; publication must retain corresponding
source, these own preparation recipes/pins and the ability to rebuild/relink the
combined work. This does not relicense any upstream source as MIT.

The fixed configuration disables external image modules, logging, cache and
background rendering threads, and uses the portable rasterizer. The reviewed
reference's `pixman_region_selfcheck(x)=1` compile definition is retained. Own
wrappers bound inputs/output dimensions; runtime acceptance is recorded in the
development ledger separately from source/license preparation.

## Portable VP9 emoji provenance

`Dependencies/VPX.lock.json` independently pins libvpx1.17.0 at
`6df3ec34557879fff673706f4a1d9fbd0f3a6f0e`, tree
`f83d33a1ba18b3a203e43596b5223042b62417a3`, official source archive SHA256
`3438fed428d5b272528b5e397cc3aa24cf080751933f600af3f8fcfcce1ab55b`.
The exact126-file portable VP9 decode closure includes48 C units,72 headers,
three runtime-dispatch inputs and LICENSE/PATENTS/AUTHORS. Its prepared135-file
inventory is fingerprinted. BSD source and patent notices are retained in
`LICENSES/VPX-source-notices.txt` and bundled in `Resources/Licenses`.

The owned preparation generates a fixed C11, single-threaded portable decoder
configuration and audited literal runtime-dispatch declarations. It runs no
upstream configure/make/Perl scripts, assembly, encoder or VP8 components. The
source size checks restrict decoded dimensions to512 and individual allocation
to8MiB before allocation; this is not a whole-process memory limit. Makosh's own
bounded WebM parser and C boundary retain separate color/alpha decoder state.
Build/run/test do not depend on `.references/`.

## Portable Opus provenance

`Dependencies/Opus.lock.json` pins the selected Telegram-iOS revision/tree above
and its `third-party/opus/opus-1.5.1.tar.gz` blob. The archive SHA256 is
`b84610959b8d417b611aa12a22565e0a3732097c6389d19098d844543e340f85`,
also published in the [official libopus 1.5.1 release](https://opus-codec.org/release/stable/2024/03/04/libopus-1_5_1.html).
The reviewed preparation copies 137 portable C files from the five literal
Opus/CELT/SILK float source groups, 103 headers, COPYING and three source-list
manifests. It executes no upstream configure, installer, CMake or Bazel script.
SwiftPM builds C99 locally; architecture-specific assembler/intrinsics and
neural-model groups are not compiled. Full source headers remain unchanged.

The lock binds the archive, license, manifests and full prepared file-set hash;
warm reuse additionally requires the exact preparation recipe and marker. It
works without the bare source cache or research checkouts. The app bundles the
unchanged COPYING and 68 deduplicated leading source copyright/license blocks,
with their selected file paths, in the two Opus notice files below. Selection
and notice review found BSD-style grants; this is not a vulnerability audit.
The GPL macOS recorder, OpusBinding writer and Telegram-bundled libogg helpers are not
copied or linked. Makosh's fixed-signature C control boundary and bounded Swift
Ogg framing are independently authored. No prebuilt codec is downloaded.

## Ordinary Opus file provenance

`Dependencies/OpusFile.lock.json` independently pins the official
[libogg1.3.6](https://www.xiph.org/downloads/) and
[opusfile0.12](https://opus-codec.org/downloads/) release archives, their unchanged
BSD3 COPYING, source-list manifests and complete prepared file-set fingerprint.
`scripts/prepare-opusfile.py` selects two libogg and four libopusfile C sources,
five unchanged headers and one own fixed-width macOS type header. SwiftPM links
the existing reviewed libopus1.5.1. All selected upstream sources retain their
notices. No upstream configure/build/installer executes; no prebuilt codec is used.

The core `stream.c` helpers remain unchanged because the core has unconditional
references to them. Makosh calls only its own held-descriptor callbacks; close
ownership stays with Swift. `http.c`, opusurl, examples and their network/TLS
dependencies are excluded. Prepared sources are authenticated on every warm use,
without the archive cache, network or research checkouts. The callback facade,
strict page admission and ordinary music policy are independently authored.

## Portable Mozjpeg provenance

`Dependencies/Mozjpeg.lock.json` pins Mozjpeg4.1.4 inside the same exact
Telegram-iOS revision/tree above, at `third-party/mozjpeg/mozjpeg`. The selected
92 committed regular files match the research source byte for byte:53 C
compilation units,6 included C fragments,25 unchanged headers,3 configuration
templates, the CMake source-list provenance and4 notice/provenance files.
`scripts/prepare-mozjpeg.py` checks every source hash and the complete98-file
prepared aggregate. It generates an own SwiftPM manifest/module umbrella and
headers from the unchanged templates for64-bit macOS, JPEG8 ABI,8-bit samples,
arithmetic support and portable scalar routines. No upstream CMake, Bazel,
installer or prebuilt library executes. Warm reuse authenticates the exact
recipe, lock, marker and file set without source-cache/network/research access.

This software is based in part on the work of the Independent JPEG Group.
The unchanged IJG README, libjpeg-turbo license, Mozilla provenance and SIMD
zlib notice are retained below, together with86 unchanged leading source
copyright/license blocks. `jpeg_nbits_table.h` has no leading notice and remains
unchanged under the package's applicable grants. The source selection/notice
review is not a vulnerability audit.

Makosh's fixed-signature, quiet C error/ownership boundary and Swift white-
background RGBX rasterization are independently authored. Ordinary photos use
FASTEST defaults, integer DCT, optimized Huffman coding, quality75 and simple
progression. ImageIO.75 remains the reference-compatible fallback; video covers
keep their existing encoder. The outer macOS Mozjpeg Objective-C wrapper is not
copied or linked. Architecture-specific SIMD and upstream command-line programs
are excluded from the app. Parameter alignment does not assert universal byte
equivalence with the reference's native builds.

## System ZIP compression

Makosh's independently authored ZIP32 writer and streaming verifier use the
Swift SDK `zlib` module, which autolinks the operating system's
`/usr/lib/libz.1.dylib`. The reviewed development SDK header and runtime report
1.2.12. No zlib implementation or binary is vendored; the retained
[SDK copyright and license notice](LICENSES/Zlib-SDK-1.2.12-LICENSE.txt) is the
verbatim notice from that header. It credits Jean-loup Gailly and Mark Adler.

The implementation uses the documented raw DEFLATE and CRC32 APIs. ZIP record
layout was independently implemented using the published
[PKWARE ZIP specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT).
No specification body or reference Zip/MiniZip implementation is redistributed.
This internal codec layer does not yet enable Archive sending in the UI.

## Included license texts and attributions

| Component | License / retained notice |
| --- | --- |
| Mozjpeg4.1.4 portable C source and scalar stubs | IJG, BSD3 and zlib-style grants; [unchanged license](LICENSES/Mozjpeg-4.1.4-LICENSE.md), [IJG README](LICENSES/Mozjpeg-4.1.4-README.ijg), [Mozilla provenance](LICENSES/Mozjpeg-4.1.4-README-mozilla.txt), [SIMD notice](LICENSES/Mozjpeg-4.1.4-jsimdext.inc), [selected source headers](LICENSES/Mozjpeg-4.1.4-source-notices.txt) |
| Telegram-iOS general engine source and Makosh engine adaptations | GPL v2-or-later, GPL v3 elected; [GPL v3 text](LICENSES/GPL-3.0.txt) |
| Google FlatBuffers, including local build tool | [Apache 2.0](LICENSES/Apache-2.0.txt), [source copyright header](LICENSES/FlatBuffers-Google-Apache-header.notice) |
| Swift RangeSet, Apple Inc. and Swift project authors | [Apache 2.0 with Runtime Library Exception](LICENSES/Swift-Apache-2.0-with-Runtime-Library-Exception.txt), [source header](LICENSES/RangeSet-source-header.notice) |
| Postbox's SQLite.swift-derived database wrapper, Stephen Celis | [MIT copyright and grant](LICENSES/SQLite-swift-Stephen-Celis-MIT.notice) |
| SQLCipher portions, Zetetic LLC | [BSD 3-Clause copyright and grant](LICENSES/SQLCipher-Zetetic-BSD-3-Clause.notice) |
| SQLite portions | Public domain; original blessing retained in prepared `sqlite3.c` |
| Apple Reachability sample portions | [Apple sample-code license](LICENSES/Apple-Reachability-LICENSE.txt); wrapper source retains its upstream notices |
| Dynamically linked local OpenSSL 3 (verified local version 3.6.4) | [Release license](LICENSES/OpenSSL-3.6.4-LICENSE.txt), Apache 2.0; source: [official release](https://github.com/openssl/openssl/tree/openssl-3.6.4) |
| Operating-system libz, reviewed SDK/runtime 1.2.12, Jean-loup Gailly and Mark Adler | [Retained SDK Zlib license notice](LICENSES/Zlib-SDK-1.2.12-LICENSE.txt); no implementation vendored |
| libopus 1.5.1 portable C sources, Xiph.Org Foundation and named contributors | BSD-style grants; [unchanged COPYING](LICENSES/Opus-1.5.1-COPYING.txt), [selected source attributions](LICENSES/Opus-1.5.1-source-notices.txt) |
| libogg1.3.6, Xiph.org Foundation | [Unchanged BSD3 COPYING](LICENSES/libogg-BSD3.txt) |
| libopusfile0.12, Xiph.Org Foundation and contributors | [Unchanged BSD3 COPYING](LICENSES/libopusfile-BSD3.txt) |
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
