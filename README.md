# Макош / Makosh

Native macOS workspace for a unified contact dossier and communications. The contact book is backed by a local PostgreSQL service: create/edit/search, multiple phones/emails, organization, role, tags, notes, source-scoped identities, JSON import, duplicate review, transactional merge and guarded undo.

Telegram is the first implemented channel: native account setup, paged dialogs/archive, paged text history and a text composer backed by the actual TelegramCore from the selected TelegramSwift reference. Connect your own separate session explicitly in the app. Real authorization/sync/send acceptance is still unverified; see [Telegram setup and limits](docs/telegram.md). Mail, WhatsApp and Teams remain disconnected. Meetings open an official Telemost link in the browser. Existing Telegram/mail sessions and macOS Contacts are not read. All included examples are synthetic.

## Requirements and run

Apple Silicon, macOS 26+, Xcode 26+ with Swift 6.2+, Python 3.11+, Docker with Compose, and Homebrew `libpq`, `pkg-config`, `openssl@3`, `cmake` and `ninja`. First local verification uses Xcode 27 / Swift 6.4 on macOS 27.0.1; macOS 26 is the configured minimum and CI target, not a claim of a full OS/device matrix. Intel and older macOS are unverified.

```sh
brew install libpq pkg-config openssl@3 cmake ninja
./scripts/dev-db.sh up
./scripts/test.sh
./scripts/run.sh
```

Build/test scripts use Makosh's own [Telegram dependency lock](Dependencies/TelegramEngine.lock.json), prepare the engine and FlatBuffers compiler in ignored local storage, verify source checksums, and supply Homebrew libpq/OpenSSL `PKG_CONFIG_PATH`. The first build downloads locked source into `.local/telegram-source.git`; `.references/` is never read or created by the build. A verified prepared engine can be reused without the source cache or network. `scripts/run.sh` creates an ad-hoc signed local `.app` in `.build/`; it dynamically links installed Homebrew libpq and OpenSSL 3 and needs both libraries on this Mac. This is not a standalone distributable bundle; no Developer ID or notarization is claimed.

The development service uses PostgreSQL 18.6, binds only `127.0.0.1:55439`, and persists data in a Docker named volume mounted at `/var/lib/postgresql` (the PostgreSQL 18 layout). `./scripts/dev-db.sh down` stops the service while preserving its data. Do not remove the volume to upgrade or reset a test.

Development scripts use ignored `.local/postgres-app.json`. Its object has `connectionString` and optional `schema` (default `makosh`); never commit this file or its password. To choose another configuration, run `./scripts/run.sh --database-config /path/to/database.json`. A direct app launch without this argument reads `~/Library/Application Support/Makosh/database.json`. A missing or invalid configuration shows a setup error; there is no embedded database fallback. Use a separate database/schema and configuration for isolated synthetic testing. Start with one app window for editing; transactional writes keep the latest database state across store instances, but an already-open editor does not offer field-level conflict resolution for competing edits of the same card.

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
