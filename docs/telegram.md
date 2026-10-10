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

Preparation fetches pinned gitlink `a24bbe45f9861f736a79916a50898512f751e0dc`
and checks official-equivalent tree `0beebf847c66e5d1bcfe3e2d7f28054ca7b8fbe0`.
Only committed regular files from the 21 selected packages are extracted.
Untracked files cannot enter the build; symlinks and archive path traversal are
refused. The separate `.local/telegram-engine` copy contains reviewed build and
privacy adaptations and generated FlatBuffers models. Its recipe number,
complete file set and SHA256 checksums are verified on reuse. The official
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
- The main chat list shows up to 50 dialogs; selected history shows up to 50
  entries. No older-history pagination, archived-chat list, search, media
  download/upload, secret-chat UI, replies or read receipts are implemented.
  Non-text entries show an explicit attachment/service-message label.
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
