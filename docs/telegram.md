# Telegram channel

Makosh reuses the **actual TelegramSwift engine**, not a mock transport or an
alternative client library. `MakoshTelegram` wraps TelegramCore, Postbox,
SwiftSignalKit and OpenSSLEncryptionProvider; `MakoshApp/TelegramView.swift` is
original SwiftUI. Exact source provenance and license texts are in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

## Build and preparation

Use macOS 26+, Xcode 26+ with Swift 6.2+, Python 3.11+, Homebrew libpq,
pkg-config, OpenSSL 3, CMake and Ninja. `scripts/build-app.sh` and `scripts/test.sh`
automatically run `scripts/prepare-telegram.py` before SwiftPM resolves local
packages. For direct SwiftPM commands, prepare first:

```sh
brew install libpq pkg-config openssl@3 cmake ninja
python3 scripts/prepare-telegram.py
source scripts/libpq-env.sh
swift build --product Makosh -j 4
```

The build reads `Dependencies/TelegramEngine.lock.json`, independently of the
research lock or checkouts. It fetches revision
`a24bbe45f9861f736a79916a50898512f751e0dc` into Makosh's own bare Git cache,
`.local/telegram-source.git`, and checks official-equivalent tree
`0beebf847c66e5d1bcfe3e2d7f28054ca7b8fbe0`. No build/run/test script needs or
creates `.references/`. A failed first fetch/tree check never publishes the
source cache. Git replacement refs cannot override the pinned source.
Only committed regular files from the 21 selected packages are extracted.
Untracked files cannot enter the build; symlinks and archive path traversal are
refused. The separate `.local/telegram-engine` copy contains reviewed build and
privacy adaptations and generated FlatBuffers models. Its recipe number,
complete file set, SHA256 checksums and full source pin are verified on reuse,
before opening a source cache or fetching anything. Repeat builds with a valid
prepared engine therefore work without research clones, the source cache or
network access; an initial preparation still requires network access. The official
FlatBuffers 24.12.23 source archive is checksum-pinned and compiled locally.

If preparation detects changed files or an old recipe, it stops. Preserve and
rename the affected generated engine/compiler directory before preparing again;
do not blindly delete it. Session data is elsewhere and is never reset by build
scripts. No upstream application installer or private config is executed/read.

## Account and data boundaries

Opening the app or selecting Telegram does not connect an account. Enter your
own API ID and API hash in the native setup form, then click **Подключить
Telegram**, or use **Подключить с локальными API-данными** after explicitly
installing your local API configuration. Phone, code and optional two-step password are entered in the app.
The agent has not authenticated an account, read private dialogs or sent a
message. Do not paste credentials or login codes into this repository/chat.

Manually entered API credentials remain in memory. Optional user-authorized
local credentials are stored in `~/Library/Application Support/Makosh/telegram-api.json`
as `{ "apiID": "…", "apiHash": "…" }`. The loader opens only on the explicit
saved-data Connect action, checks the same open descriptor for owner, regular-file
type, no group/world permissions and a maximum 8192-byte size, and refuses
symlinks. Values never prefill the screen or enter logs; no automatic connection
occurs. This is a private mode-0600 file, not Keychain storage. Protect its backups.
To import only the API ID/hash from a selected legacy dotenv configuration:

```sh
python3 scripts/import-telegram-api.py --from-env /path/to/legacy/.env
```

The importer selects only `HERMES_TELEGRAM_API_ID` and `HERMES_TELEGRAM_API_HASH`,
does not evaluate shell code, prints no values and refuses an existing destination.
It transfers no phone, authorization key, session or messages. No credentials
belong in Git. OTP and password fields clear on submission. A separate encrypted TelegramCore
session lives in `~/Library/Application Support/Makosh/Telegram`; its random
48-byte encryption key/salt is stored in the macOS Keychain under Makosh's own
service. Existing Telegram app sessions and system contacts are never imported.
Missing or inaccessible keys stop opening existing data instead of overwriting
them. Postbox cache-open errors do not trigger automatic database deletion.

Contact dossiers/notes/merge history remain in **PostgreSQL**, with the local
development database in Docker. TelegramCore's encrypted Postbox/SQLCipher
cache is its protocol/session storage; this cache does not replace PostgreSQL
or store Makosh contact dossiers. Linking Telegram identities to dossiers and
importing Telegram contacts are not implemented in this slice.

Engine console/file logging is disabled before account initialization, including
the required shared logger registration. Cloud login-token reads, future token
storage, iCloud integration, automatic system-contact sync and online-presence
advertising are disabled. This does not imply anonymity or remove Telegram's
normal server-side account/network visibility.

**Остановить подключение** releases subscriptions and stops the local engine;
it preserves the cache and does not revoke the server session. Server-side
logout/reset should be managed through Telegram's session controls. An
authorized-to-unauthorized transition clears old previews/history and disposes
their subscriptions; callback generations prevent stale account updates.
Destroying the model also shuts down subscriptions through isolated deinit.

## Implemented surface and limits

- Existing-account phone → code → optional password authorization calls real
  TelegramCore APIs. Code/password requests time out after 30 seconds; local
  session opening reports a problem after 45 seconds. There is no automatic
  retry of auth or sending. Email codes use the distinct email-verification
  payload; phone/session/SMS/call/word/phrase codes use the phone-code payload.
  Email setup, Firebase, Fragment and flash/missed-call verification show an
  explanation instead of submitting an incompatible phone code. Registration,
  password recovery/reset and payment are also unsupported.
- Main and archived dialogs and selected history use live cursor-based windows.
  **Старее**, **Новее** and **Последние** replace the active window; 50 is the
  engine's requested batch size, not a total-history limit. Around-anchor windows
  may overlap and include entries on both sides of the anchor. Actual Postbox
  boundary indexes drive navigation. Edits/deletions in the active window remain
  observable; older windows are not accumulated into a stale second cache.
  Selected chat and draft survive list/folder changes. Empty loading snapshots
  retain displayed data; stable empty snapshots clear it. A 30-second deadline
  offers an explicit retry, keeps the subscription alive and permits later recovery.
  Secret-chat UI, replies and read receipts are not implemented. Unknown media
  and paid/locked content show an unsupported label and offer no download.
- Chat search reads all known Postbox peers in the selected main/archive list,
  independently of the visible page. It does not discover remote peers and may
  omit dialogs not yet in the local cache. Message search calls the selected
  peer's engine search API (secret chats use its existing local branch), requests
  50 more matches per page and can open a match in the live history window.
  Query/chat/account changes cancel the old request and reject stale tokens.
  Errors and 30-second deadlines offer explicit retry; successful empty results
  remain distinct. A failed RPC preserves both engine cursors and displayed
  results, including migrated peer pairs. There is no automatic search retry.
- Photos and files appear in both history and search with explicit full-file
  and thumbnail download actions. Rendering never starts a fetch. Progress,
  cancellation, failure and a 60-second deadline offer explicit retry. Only
  complete zero-offset data becomes ready; local status or fetch completion
  alone is insufficient. Each job disposes its own engine subscriptions, and
  replaced requests reject stale callbacks. Files leave the active cache lease
  when no longer present in the history/search window or on account/view reset;
  an ongoing preview/export borrow retains it until processing finishes.
- Ready images open only by a separate action. ImageIO checks the measured file
  size (maximum 20 MiB), dimensions (maximum 8,192 per side) and pixel count
  (maximum 40 million), then downsamples to 1,280 pixels on a worker. Each
  conversation allows one processing operation at a time. General files are
  never executed or opened automatically. **Сохранить…** uses a native Save
  panel and streams a separate atomic copy; cancellation of the panel writes
  nothing. Source files are never moved or overwritten. Regular-file, size,
  symlink and same-inode checks protect the cache and destination. Download
  paths and raw protocol references are not persisted in contact dossiers.
  Immediate-thumbnail decoding remains future work; image/file support is not
  full media-client acceptance.
- Audio/voice/video/round-video attributes expose an explicit **Открыть
  проигрыватель** action after full download. Native AVFoundation/AVPlayerView
  opens a private streamed copy (4 GiB cap, 0700/0600); opening never autoplays.
  Container suffixes for Ogg/WAV/MP4 come from bytes, never message names/MIME.
  Actual native tracks, finite positive duration up to seven days and video
  dimensions up to 8,192 / 40 million pixels are checked before controls appear.
  The asset forbids all external references and alias resolution before loading;
  no resource-loader/network fallback is installed. Decoder isolation and support
  for every codec/container are not established by these limits.
- Playback has play/pause, seek and 0.5/1/1.5/2 speed controls. A paused player
  retains its cache borrow and private copy. Stop/end/failure, account/chat/page
  changes, descriptor replacement, search-query change and view dismissal detach
  the decoder before releasing resources; a 30-second preparation deadline offers
  explicit retry. Unsupported native media can still be saved. Synthetic native
  WAV/MP4/Ogg tests establish those fixtures only; native Ogg duration reporting
  varies by OS codec version. Real account media and audio-device output remain
  separately unverified.
- The attachment buttons open a native single-file panel. Choosing a file does
  not send it: a separate confirmation shows the frozen recipient and editable
  caption. Switching chat keeps that recipient; stopping/replacing the account
  while the panel is open invalidates its result, including same-account reconnect.
  Documents retain original bytes, stream in 1 MiB chunks and have an explicit
  4 GiB product cap (not a promise about the server/account quota). **Фото** is
  separate: input is bounded to 20 MiB, 8,192 per side and 40 million pixels,
  orientation is normalized and a JPEG no larger than 2,560 pixels is encoded
  without copying source metadata. Temporary copies use private 0700/0600 paths;
  symlinks/special files and sources changed during preparation are rejected.
- **Отправить вложение** validates the captured account/cloud chat and a caption
  of at most 1,024 UTF-16 units. It first copies into MediaBox and verifies a
  complete zero-offset regular cache file with the exact measured size. Only then
  can TelegramCore enqueue the file/photo. A local MessageId acknowledges the
  outbox, clears only a byte-identical caption in its original chat, and releases
  the temporary copy. Queue progress, 100% or absent progress never mean delivery.
  Before enqueue, cancellation stops preparation; after possible enqueue, closing
  observation never recalls/deletes the message. A 30-second enqueue deadline
  preserves an uncertain result and allows a late acknowledgement without another
  enqueue. There is no app-triggered automatic resend. Queued engine work may
  resume on reconnect. Crash/restart reconciliation, local-to-cloud ID tracking,
  server quota/restriction acceptance, secret-chat upload and queued-send deletion
  remain unverified or unimplemented; no exactly-once delivery claim is made.
- Text sending uses TelegramCore's genuine durable local outbox. Captured
  account/recipient identity is retained across selection changes. The draft
  clears only after enqueue acknowledgement; pending/failed flags are shown in
  history. Local enqueue is not proof of server delivery or recipient read.
- Drafts are isolated by account/chat and retained in memory while switching
  dialogs or stopping/reconnecting in the same app process. They are not
  persisted across app exit. A delayed acknowledgement preserves text edited
  since submission, including normalization-only edits.

Tests cover config rejection before account work, exact-source preparation,
draft/account isolation and acknowledgement races, disabled logger setup and
real OpenSSL modular arithmetic/binary roundtrips. Build, tests and native setup
UI checks are distinct from real authorization, incoming sync, sending,
reconnect or cache-corruption acceptance. See [`development-status.md`](development-status.md)
for actual completed checks and outstanding runtime limits.

## Independent local message retention

**Локальный архив** opens a separate native viewer, including while Telegram is
disconnected or no chat is selected. It shows retained text snapshots, versions,
attachment metadata and source-cache removal markers, attributed to the full
service/account/peer/message namespace identity. Its 100-record cursor pages are
independent of the current Telegram history/search window. It has no delete,
expiration or automatic retention-pruning action.

Preparation recipe 4 captures central Postbox history writes and the old content
before overwrite/removal in durable ValueBox tables in the **same transaction**.
This starts with the prepared engine, rather than registering only visible or
already known peers. The account-bound adapter drains immutable batches to
PostgreSQL; exact source sequences are acknowledged only after archive commit.
Stable event UUIDs and receipts make redelivery idempotent even if an earlier
duplicate snapshot was suppressed. A→B→A versions remain distinct. PostgreSQL
failure leaves the source journal pending and shows an explicit retry error;
account/view changes do not cancel a write already accepted for its captured
account. Disconnecting does not delete the independent archive.

When updating an existing development checkout, preparation refuses an engine
made by an older recipe. Preserve `.local/telegram-engine` under an unused backup
directory name, then rerun `scripts/build-app.sh` or `scripts/test.sh`; the locked
source/compiler caches can be reused. Do not edit the generated engine or remove
the application-support session directory, PostgreSQL volume or Keychain items.
Fresh checkouts prepare recipe 4 directly.

Archive tables share the configured PostgreSQL service/schema, without changing
the contact aggregate. AES-GCM encrypts text and metadata with separate HKDF
encryption/lookup keys; authenticated data binds the vault, schema version,
message token and sequence. Lookup identities use HMAC. SQL contains ciphertext,
opaque keyed tokens, observation UUIDs and sequence/size information; this is
not a guarantee against database-admin deletion or traffic/size analysis.
Parameterized writes are atomic; append-only triggers reject ordinary event and
receipt UPDATE/DELETE/TRUNCATE. Missing/wrong keys, unsupported versions and
integrity failures stop without replacing existing data.

The separate random 256-bit archive key is stored as a nonsynchronizing item in
the **macOS login Keychain**, with the normal macOS ACL/unlock behavior. It is
created only for a new vault, never substituted for a missing existing key.
There is no file fallback, iCloud sync or reuse of Telegram protocol keys.
Ad-hoc development signing cannot access the entitlement-gated data-protection
Keychain; no iOS device-only or lock-screen accessibility guarantee is claimed.
PostgreSQL data and this key are both necessary for recovery. Portable encrypted
backup/key export and restore are still unimplemented; a database dump alone is
insufficient to move the archive to another machine.

Current boundaries:

- Retention covers message states actually stored through the adapted central
  Postbox history paths. Content deleted before reception, unrequested history,
  and intermediate edits coalesced before Postbox are unavailable. Existing
  untouched cache rows are not proactively backfilled; a later overwrite/removal
  captures their prior content. Mutations confined to shared referenced media
  outside history writes and raw API-version capture require further work.
- A physical source-cache removal proves disappearance, not who deleted it.
  The viewer says the cause is unknown; history pagination/filter changes never
  create deletion markers. Author IDs and plain text are retained; resolved
  author names and rich-text entities are not yet archived.
- Completed explicit **full-file downloads** now receive independent encrypted
  copies in S3. An open file descriptor is captured synchronously before the
  first suspension; subsequent Telegram cache unlink does not remove its bytes.
  PostgreSQL stores encrypted metadata/object references only. Preview-only or
  never-downloaded media remain metadata. Opening the archive never fetches
  media from Telegram; exporting a stored attachment reads S3 explicitly.
  See [storage and recovery boundaries](object-storage.md).
- Graceful disk-full backpressure is not established: upstream ValueBox uses
  void/assertion IO and commit paths. Capture encoding/sequence failures stop
  rather than truncate, but synthetic tests do not prove physical disk-loss
  recovery. Old binaries sharing this Postbox store lack the journal adaptation.
- No real account or peer-deletion acceptance was performed. Automated tests
  use generated schemas and encrypted temporary Postbox fixtures; UI inspection
  uses visibly synthetic data. See the evidence ledger for exact results.

## Offline navigation UI check

After a debug build, launch the explicit synthetic view:

```sh
open -n .build/Makosh.app --args --telegram-synthetic-preview
```

This DEBUG-only branch uses the real Telegram views, navigation and snapshot
receivers with fixed in-memory data (125 main dialogs, 65 archive dialogs and
130 messages per dialog), search and explicit search-failure injection. Synthetic
photo/file/unsupported attachments exercise download, cancel, image preview and
the real Save panel. Fixture bytes are created in a private temporary directory
only after an explicit download and removed when their lease is released.
It bypasses the contact workspace and opens no
PostgreSQL, API file, Keychain, account/session or network. Real sending and connection
are blocked in the model as well as the UI. File/photo selection exercises real
staging and confirmation; **Имитировать очередь** invokes only a visibly labeled
DEBUG fake provider with no Postbox transaction or network. It is visibly labeled synthetic and
does not prove server pagination or hole filling. The branch and fixture are
excluded from release builds; regular launch still starts disconnected.

The same preview includes an explicitly synthetic in-memory local archive with
an original, an edit and a source-cache removal marker. It exercises the actual
native archive viewer, refresh and dismissal without opening the user's archive.
