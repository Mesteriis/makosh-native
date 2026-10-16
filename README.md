# Макош / Makosh

Native macOS workspace for a unified contact dossier and communications. The contact book is backed by a local PostgreSQL service: create/edit/search, multiple phones/emails, organization, role, tags, notes, source-scoped identities, JSON import, duplicate review, transactional merge and guarded undo.

Telegram is the first implemented channel: native account setup, paged dialogs/archive and history, local chat search, per-dialog message search, explicit attachment downloads, bounded image previews, file saving, local native audio/video playback, explicit file/photo preparation and sending, and a text composer backed by the actual TelegramCore from the selected TelegramSwift reference. Connect your own separate session explicitly in the app. Real authorization/sync/send/download acceptance is still unverified; see [Telegram setup and limits](docs/telegram.md). Mail is implemented with manual IMAP/SMTP accounts, retained history, rules/templates/signatures, scheduling and scoped notifications; real-provider QA remains paused. WhatsApp and Teams are implemented native adapters with explicit account connection; real-provider acceptance remains unverified. See [Teams setup, scopes and recovery](docs/teams-migration.md). Telemost has an independent native first-stage API adapter, a local known-meeting catalogue, retained versions and dossier references; participation opens the official client/browser. Existing Telegram/mail sessions and macOS Contacts are not read. All included examples are synthetic.

Open native Settings (⌘,) to choose Enter or ⌘Enter for Telegram submission.
The choice persists across launches and applies to messages/replies, inline
edits and attachment captions. Shift-Return inserts a newline; Return also
inserts a newline when ⌘Enter is selected.

An inline Telegram edit keeps its text, formatting and selection when switching
chats or services in the same window. For media, right-click the edit accessory
to move its caption above or below; changing only placement can be saved, and
editing text preserves the native placement. Cancelling it returns to the separate
ordinary draft/reply. Active edits remain in memory and reset after app restart.

For a new photo, use the preparation window’s actions menu to move its caption
above or below. The choice survives text edits and recovery after restart;
ordinary files keep captions below. Prepared bytes are encrypted in S3, with
metadata in PostgreSQL and the pending draft in encrypted Postbox.

Forwarding opens the selected recipient in the same workspace, with a source
accessory and optional rich comment. The forward draft/options survive chat and
service switches and restart; cancelling the forward keeps the comment/reply.
Unavailable or changed sources block sending. An uncertain submission is retained
without automatic resend; a local queue receipt can be checked after restart.

Use **Выбрать** in a history message's context menu to select up to 100 messages
for one forward. The selection survives history pagination and switching services
in the same window. Cancel returns to the ordinary draft/reply or active edit;
choosing a recipient stages the selected batch without sending it. Shift-range,
album grouping and selection copy/delete actions remain unfinished.

Received Telegram text has a separate encrypted, append-only PostgreSQL archive,
accessible through **Локальный архив** even while disconnected. Stored versions
survive edits and removal from Telegram's cache. A durable same-transaction
Postbox journal waits for the archive commit before acknowledgement, including
when PostgreSQL is unavailable. Completed full-file downloads receive independent
encrypted copies in S3; PostgreSQL contains metadata, object keys and receipts,
never attachment payload bytes. The local archive provides explicit encrypted
backup, full inspection and restore into a new archive, with a separate recovery
key and read-only restored browsing. See the [recovery procedure](docs/archive-recovery.md).
Historical backfill remains unfinished.
Content removed before this client receives it cannot be recovered. See the
[retention boundaries](docs/telegram.md#independent-local-message-retention).

## Requirements and run

Apple Silicon, macOS 26+, Xcode 26+ with Swift 6.2+, Rust 1.97.0 (rustup with rustfmt/clippy), Python 3.11+, Docker with Compose, and Homebrew `libpq`, `pkg-config`, `openssl@3`, `cmake`, `ninja` and `bison`. First local verification uses Xcode 27 / Swift 6.4 on macOS 27.0.1; macOS 26 is the configured minimum and CI target, not a claim of a full OS/device matrix. Intel and older macOS are unverified.

```sh
brew install libpq pkg-config openssl@3 cmake ninja bison
rustup toolchain install 1.97.0 --profile minimal --component rustfmt --component clippy
export RUSTUP_TOOLCHAIN=1.97.0
./scripts/dev-db.sh up
./scripts/test.sh
./scripts/run.sh
```

Telegram's application API ID/hash are supplied once at build time through
private `.local/telegram-build.env` or CI Secrets, then compiled into the app.
The login screen contains only the connection and personal authorization steps;
no runtime API JSON is read. Ordinary builds require the pair; use
`./scripts/build-app.sh --allow-unconfigured-telegram` for an explicit source-only
build with Telegram connectivity disabled. See [build configuration](docs/telegram.md#application-api-pair-at-build-time).

Build/test scripts use Makosh's own [Telegram dependency lock](Dependencies/TelegramEngine.lock.json), [Opus source lock](Dependencies/Opus.lock.json), [OpusFile lock](Dependencies/OpusFile.lock.json) and [Mozjpeg lock](Dependencies/Mozjpeg.lock.json). They prepare the engine, FlatBuffers compiler and portable C codecs in ignored local storage, verify source checksums, and supply Homebrew libpq/OpenSSL `PKG_CONFIG_PATH`. The first build downloads locked source into `.local/telegram-source.git`; `.references/` is never read or created by the build. Verified prepared engine and codec packages can be reused without the source cache or network. `scripts/run.sh` creates an ad-hoc signed local `.app` in `.build/`; it packages the reviewed libpq18.6/OpenSSL3.6.4/VoIP runtime closure from [MacRuntime.lock.json](Dependencies/MacRuntime.lock.json). Runtime TLS uses macOS system trust. Build tools still require Homebrew; the packaged app does not load Homebrew dylib paths. Database/S3 services and private app configuration remain external. Developer ID, notarization and independent clean-Mac acceptance are not claimed.

Development services are PostgreSQL 18.6 (`127.0.0.1:55439`) and S3-compatible SeaweedFS 4.48 (`127.0.0.1:55440`), both pinned by image digest with separate persistent Docker volumes. `scripts/dev-db.sh up` starts both and initializes the private `makosh-files` bucket. Versioning is enabled; bucket policy denies deletion, expiration rules and suspending versioning. `scripts/dev-db.sh down` preserves both volumes and local credentials. Do not remove volumes to upgrade or reset a test. See [file storage](docs/object-storage.md) for configuration, encryption and recovery boundaries.

Development scripts use ignored `.local/postgres-app.json`. Its object has `connectionString` and optional `schema` (default `makosh`); never commit this file or its password. To choose another configuration, run `./scripts/run.sh --database-config /path/to/database.json`. A direct app launch without this argument reads `~/Library/Application Support/Makosh/database.json`. A missing or invalid configuration shows a setup error; there is no embedded database fallback. Use a separate database/schema and configuration for isolated synthetic testing. Start with one app window for editing; transactional writes keep the latest database state across store instances, but an already-open editor does not offer field-level conflict resolution for competing edits of the same card.

The default `scripts/run.sh` also supplies ignored private `.local/s3-app.json` through `--storage-config`. When supplying your own database arguments, also supply `--storage-config /path/to/s3.json`. A direct app launch reads `~/Library/Application Support/Makosh/s3.json`. S3 keys are generated separately from PostgreSQL and Telegram credentials; they are never embedded in the app or committed.

## Try the first stage

1. Create a contact; edit phones, email, organization and tags; add a note in its dossier.
2. Import `Examples/contacts.synthetic.json` through **Импорт JSON**. Import it again: no duplicate cards or notes should appear.
3. Open **Объединения**, inspect the matched email/phone, select the survivor and confirm the merge.
4. Use **История объединений** in that panel to undo. Try editing the survivor before undo: a conflict must stop undo and preserve the edit.
5. Quit and reopen with the same database configuration and schema to verify persistence. Same-name sample people remain separate.

See the [import schema](docs/import-format.md), [architecture](docs/architecture.md), [roadmap](docs/roadmap.md) and [current verification status](docs/development-status.md). Undo stores snapshots in PostgreSQL, not a separate backup; no delete/contact backup/export feature is provided yet. For large datasets, the single-row JSONB aggregate in PostgreSQL and pairwise duplicate scan need measured scaling work.

## References and source research

The eight selected references are pinned in `references.lock.json`; optional research clones live in ignored `.references/`. `scripts/prepare-references.py` is only a research tool, never a build prerequisite. The selected iOS engine revision is independently pinned by Makosh's dependency lock and prepared from its own source cache; the outer macOS UI and branding assets are excluded. The combined application is **GPLv3**; independently authored Makosh code retains MIT. Exact official-tree equivalence, adaptations, license grants and retained texts are in [third-party notices](THIRD_PARTY_NOTICES.md). No built app or prepared engine is published as a binary release. Other reference applications remain research inputs.

Read [XERJ workflow](docs/xerj.md) and the CRM, communications, UI/meetings research documents. Indexes, journals, raw local reports and machine configuration are excluded from Git. Reference research does not claim their applications build or their live integrations work.

CI builds/tests on the documented GitHub `macos-26` arm64 runner. Its actual run state is recorded in the development status; merely adding a workflow is not a successful CI result.

## Почта в общем workspace

Почтовый канал использует MMail IMAP/SMTP/MIME и Aether Courier UI внутри общей
панели сервисов и досье. Настройка — ручной IMAP/SMTP с TLS/STARTTLS; пароли в
Keychain, шифрованные метаданные/версии в PostgreSQL, файлы в encrypted S3.
Неизвестная отправка/серверное сохранение черновика не повторяется автоматически.
Подробности, реальный статус и различия: [mail migration](docs/mail-migration.md),
[development status](docs/development-status.md), [notices](THIRD_PARTY_NOTICES.md).

### WhatsApp: native workspace and separate worker

The native workspace now includes the selected Zen-derived WhatsApp connection,
account list and retained paged history. Its protocol core is a **separate AGPLv3
worker**, with independent reviewed Rust/registry pins, SQLCipher cache and framed
local IPC; Swift does not link Rust code. Build scripts prepare/package it and
include its corresponding-source archive. Rust1.97.0 is required in addition to
existing macOS development prerequisites. Read [WhatsApp migration](docs/whatsapp-migration.md)
for scope, licenses, keys, retention and outstanding real-account acceptance.
The second block adds durable outgoing attempts and explicit uncertainty, text/reply/
edit/reaction/forward/revoke, rich media and voice, retained statuses/search/export,
per-account/chat notification and S3 rules, dossier links and personal audio/video
calls. Static/synthetic acceptance and remaining live/UI limits are recorded in
[development status](docs/development-status.md); no real WhatsApp account is linked.

Телемост первого этапа: локальный каталог ссылок и аккаунты официального API,
создание/зал ожидания/чтение соорганизаторов, постоянные версии, поиск/экспорт
и ссылки в досье. [Настройка и ограничения](docs/telemost-migration.md).
Участие открывается в официальном клиенте/браузере. Реальная приёмка на паузе.
