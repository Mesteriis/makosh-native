# Architecture and license decisions

## ADR-001: Native shell and local PostgreSQL core

`MakoshApp` is SwiftUI with AppKit application activation and browser opening. `MakoshCore` owns Codable contact models and PostgreSQL transactions through the system libpq C interface. PostgreSQL 18.6 runs in Docker for development; Homebrew `libpq`, OpenSSL 3, CMake and Ninja are required locally; scripts prepare the exact engine and supply `PKG_CONFIG_PATH`. Contacts and notes need the database service but no communication-service accounts. Telegram is the first real engine adapter with explicit user connection; remaining integrations show their disconnected state. The ad-hoc app bundle packages reviewed libpq/OpenSSL 3 dylibs; PostgreSQL and S3 remain separate services. Developer ID/notarization and clean-machine acceptance are separate boundaries.

Use macOS 26.0 as the declared minimum, Apple Silicon as the supported initial architecture. The first local verification uses macOS 27.0.1/Xcode 27/Swift 6.4. Older OS runtime acceptance and Intel are unverified. CI uses the documented `macos-26` arm64 runner, not a Linux substitute ([runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)).

## ADR-002: Own transactional contacts

Contacts use one JSONB row per contact (`contact_records`), one per merge record (`contact_merges`), per-identity import watermarks (`contact_source_fetches`) and a version row (`contact_store_meta`, version 2). Every mutation runs in one transaction under a schema-scoped `pg_advisory_xact_lock`, rereads only the rows it needs and writes only the rows it changes, so independent connections still serialize writes against current state while a write no longer rewrites the whole contact book. Identity and note-ownership lookups use JSONB containment over GIN indexes and keep the previous fail-closed checks for duplicate owners. Schema initialization uses a transaction-scoped advisory lock; unsupported schema versions are rejected on open and on every read/write. Duplicate review remains pairwise.

Version 2 (2026-11-03) replaced the earlier single-row `state` aggregate without a data migration, by owner decision: contacts are re-imported from their sources. The old `state` table, if present, is neither read nor modified or deleted. The libpq session rules (fixed connect timeout, suppressed notices, statement/lock timeouts, SQLSTATE-only errors, asynchronous release) live once in `PostgresConnection` and are shared by the contact, archive, mail, Teams, Telemost and WhatsApp stores.

The development container binds `127.0.0.1:55439` and uses a named volume at `/var/lib/postgresql`; `./scripts/dev-db.sh down` preserves that volume. `./scripts/dev-db.sh up`, `./scripts/test.sh` and `./scripts/run.sh` are the normal development sequence. The app reads `{connectionString, schema}` JSON via `--database-config`; development scripts select ignored `.local/postgres-app.json`, while a direct launch defaults to `~/Library/Application Support/Makosh/database.json`. Schema defaults to `makosh` and is validated by the core. Credentials and DSNs are never committed or displayed in UI diagnostics. Missing configuration or connection failure produces an actionable setup error; there is no SQLite fallback or automatic migration from the unpublished prototype.

The public data contract is `Sources/MakoshCore/Models.swift`. Identity equality uses exact UTF-8 bytes of the complete service/account/external-ID tuple, never the external ID alone. The persistence key encodes each raw component with base64 and joins them with a separator outside that alphabet; canonical-equivalent Unicode spellings remain distinct opaque IDs. Imported observations retain value, source identity and fetched time. Manual field overrides suppress import writes without discarding source evidence. Notes and contact-local events are real persisted local records; no fabricated messages or meeting links appear.

Duplicate review uses normalized email/phone overlap, with visible reasons; equal names alone are insufficient. Merge is explicit and keeps unioned identities, arrays, notes, observations and history. Conflicting scalar values remain in the dossier's observations and journal snapshots; the selected scalar becomes a manual choice so an identical reimport cannot silently reverse the user's selection. Undo restores both prior cards only while the merged survivor remains at the expected revision; subsequent edits/changed imports/merges must block undo. Undo revisions must remain monotonic to avoid stale journal entries becoming applicable again.

## ADR-003: Reference boundaries and licensing

Independently authored Makosh source retains MIT; the combined Telegram-enabled application uses GPLv3. The exact iOS engine gitlink from TelegramSwift is prepared and linked locally. Its complete Git tree equals the verified official Telegram-iOS ancestor; Telegram's published GPLv2-or-later grant permits electing GPLv3. The outer GPLv2 macOS UI is excluded. Apache-2.0 dependency compatibility is evaluated against GPLv3, not assumed against GPLv2-only. See [third-party notices](../THIRD_PARTY_NOTICES.md) for commits, license texts, dependencies, build adaptations and binary-distribution obligations. No ready-to-distribute binary is published.

900CRM is Apache-2.0 and has a separable Rust domain crate, but its CRM schema and migration surface do not meet our provenance/undo requirements without adaptation. Orbit is an approach reference: its missing repository-wide license and unsafe merge details preclude copying. See `research-crm.md`. Choosing own core avoids importing both unnecessary business schema and unresolved combined-work obligations.

TelegramSwift remains the chosen Telegram direction, MMail the functional mail basis, Aether Courier the mail UX reference, WhatsApp Zen the chosen Swift/Rust direction, and teams-cli the Graph basis. No alternative component has been silently substituted. Researching a reference does not validate its build, auth, sync or real account behavior.

## ADR-004: UI and service adapters

MainActor is the workspace's presentation and state coordinator. Every service
owns its protocol/persistence/file/media work on independent executors; adding
mail or another service must not put that work on the workspace actor. Immutable
commands/results, generation checks and asynchronous release separate those
lifetimes. The current audit and concrete rules are in
[main-thread boundaries](main-thread-boundaries.md); its scoped evidence must
not be mistaken for proof of every native runtime path.

Presentation models that need no AppKit window, SwiftUI view or application-wide
notification infrastructure live in their service module's `Presentation/`
folder (`MakoshMail`, `MakoshTeams`, `MakoshTelemost`, `MakoshWhatsApp`), as
`TelegramModel` already does in `MakoshTelegram`. They use `package` access, so
the app target and same-package tests reach them without making them public
library API, and service model tests do not import the executable target.
Views, windows/panels, system-notification adapters, settings registries and the
cross-service `WorkspaceModel` stay in `MakoshApp`; tests of those still import it.

Aether Courier's indexed `RootView`/`ReadingPaneView` and inspected `docs/screenshot.png` informed the sidebar → list → dossier hierarchy, violet emphasis, compact caption metadata and separate reading panel. The earlier Contacts shell used original SwiftUI. The mail migration now adapts the MIT Aether Aurora backdrop and MIT MMail transports/editor with retained notices; Telegram outer UI remains independently implemented. See `research-ui-meetings.md` for pinned evidence and queries.

The user-selected matte-glass shell (2026-10-16) replaces the persistent service
sidebar with a titlebar section dropdown. WorkspaceSplitView retains existing
service panes/width bounds; mail keeps folders, list and reader. It avoids the
NavigationSplitView-generated toggle that displaced the menu on this runtime.
WorkspaceStyle/WorkspaceBackdrop own shared chrome; explicit chat themes and
content colors remain scoped. See reference-interface.md and ../design-qa.md for
scope and acceptance limits. Workers, ownership and lifecycle admission are unchanged.

SwiftUI owns workspace and sheet state; AppKit provides the JSON file panel. On the local macOS 27 build, SwiftUI's importer left a valid JSON selection unavailable. The explicit `NSOpenPanel` sets file-selection flags after allowed types, as the macOS 27 SDK requires when those flags must be preserved. Merge review uses an item-driven sheet and requires an explicit survivor selection before enabling confirmation. System background colors and an appearance-aware accent support the observed dark appearance.

Adapters will expose source-scoped identities and timestamped import observations to the core. Do not build a general plugin framework. WhatsApp now uses a separate AGPLv3 Rust process with private framed JSON IPC; no Rust code links into the Swift executable. Its native owned-buffer functions remain internal to the worker. See `docs/whatsapp-migration.md`. Other service contracts remain concrete and source-scoped.

Telemost first-stage UI opens a supplied official HTTPS meeting URL in the browser. The [official REST API](https://yandex.ru/dev/telemost/doc/ru/) is limited to Yandex 360 for Business organization-domain accounts. No account was authorized in this task, so no API calls or private meeting discovery are performed. The Linux GTK/GStreamer reference explicitly labels its reverse-engineered endpoint mapping unconfirmed against a live server; native WebRTC remains a separate investigation.

## ADR-005: First Telegram channel

`MakoshTelegram` owns a MainActor lifecycle adapter over genuine TelegramCore/Postbox/SwiftSignalKit and OpenSSLEncryptionProvider. Own SwiftUI handles explicit connection, phone/QR/code/password, dialogs, recent history and text sending. No account/Keychain/filesystem/network work occurs in model initialization. User Connect begins a separate encrypted cache and own Keychain key; no existing client sessions or system contacts are read. The application API pair is compiled from private build input into an ignored Swift target; no runtime API file or API input fields remain. Personal authorization and encrypted session keys stay separate. Required engine logging is registered with output disabled before account initialization.

PostgreSQL remains the dossier database. Postbox/SQLCipher is the engine's encrypted protocol cache, never a replacement for contact persistence. Session open failures preserve data; missing keys fail closed. Stop and model destruction dispose subscriptions, stop service/connection tasks and preserve cache. Server logout clears old previews and account subscriptions; generation guards reject stale callbacks. Text enqueue acknowledgement controls clearing an account/chat-scoped draft and does not claim server delivery. Drafts are in-memory only. First slice is bounded to 50 root chats/history entries and text; actual auth/send/reconnect remains unverified without user-entered credentials. See [Telegram details](telegram.md).

## ADR-006: Build dependencies are independent of research

`Dependencies/TelegramEngine.lock.json` owns the build's source URL, complete
revision/tree and selected package roots. The audited Telegram revision stays
the same. Preparation fetches it into `.local/telegram-source.git`, a separate
bare object cache, and extracts committed regular blobs into the adapted
`.local/telegram-engine` packages consumed by SwiftPM. Source/tree validation
precedes publication of a new cache; Git replacement refs are disabled.

The build never reads or creates `.references/` or invokes research preparation.
A complete verified prepared engine is checked before any source-cache/network
work, allowing offline repeat builds. Changed prepared input fails closed rather
than being silently replaced. Research clones/indexes remain optional developer
tools. Neither source cache nor the installed app depends on a research folder;
account data stays outside all dependency caches. The compiled application API target is generated separately from pinned dependency preparations and excluded from Git/XERJ.

## Mail service executors

`MakoshMail` owns the pinned MMail protocol/MIME adaptation. Each
`MailAccountWorker` serializes SELECT/FETCH/STORE/MOVE/APPEND; explicit admission
precedes awaits to prevent actor reentrancy from interleaving mailbox contexts.
NIO callbacks are event-loop-owned, TLS uses the existing OpenSSL 3. SQL,
Keychain, MIME, attachment staging and crypto remain outside MainActor.
`MailWorkspaceModel` only coordinates immutable value snapshots and UI tasks.

The encrypted PostgreSQL mail state stores account metadata, draft receipts and
submission admissions. Normalized encrypted letter/preview rows support bounded
folder paging; immutable encrypted `mail_letter_versions` retains full content
across updates, source removal and UIDVALIDITY changes. Identity includes
service/account/exact wire mailbox/UIDVALIDITY/UID. Display names never become
protocol identifiers. S3 stores encrypted RFC822/files; PostgreSQL stores only
file metadata/receipts. A folder OFF forbids every new S3 copy and uses encrypted
local staging for draft recovery. Mail folders default ON; remote delete never
purges retained history. SMTP and Draft APPEND uncertain outcomes persist and
require explicit resolution before manual retry. The common dossier keeps
account-scoped mail identities and existing atomic merge/undo contracts.


Mail completion adds encrypted automation/notification routes to the same state
transaction. A separate PostgreSQL advisory-lock session owns each active SMTP,
schedule and rule attempt across windows/processes, with state-checked settlement.
Changing a transport/source identity requires a new accountID; credentials and
retained UID identities cannot be rebound. IDLE uses separately owned connections;
disconnect cancels all watchers and the active SMTP preparation. Incoming UIDs are
drained oldest-first without advancing a checkpoint over a missing page. Failed
rule preparation is isolated from unrelated due work. Plain-text pagination and
immutable history queries live off MainActor; native views coordinate value pages.
System SecTrust validates production TLS without Homebrew trust paths.

## WhatsApp service and separate worker

`MakoshWhatsApp` owns source-specific DTOs, account commands, encrypted PostgreSQL
projections/permanent archive transfer and protected Keychain session keys.
`WhatsAppNativeSession` runs bounded local pipe IO on its own Dispatch executor.
`MakoshWhatsAppWorker` is a separate AGPLv3 executable with its own Tokio runtime,
SQLCipher backend, durable source journal and per-account file lease. It opens
offline; only explicit Connect starts protocol work. The independent pin, license
source audit and corresponding-source artifact are documented in
`docs/whatsapp-migration.md`. MainActor receives values and coordinates commands;
no speculative universal plugin framework is introduced.


WhatsApp block2 extends the same concrete workers with durable outgoing attempts,
bounded indexed outbox pages, exact-resource file versions, rich retained DTOs,
source-scoped notifications and owned call media. Core archive sourcePayload is
optional opaque service metadata encrypted with the observation; it is not a
universal protocol interface and contains no attachment payload bytes. Reconnect,
terminal call events and presentation callbacks revalidate scoped ownership.

## ADR-012: Native Teams service

`MakoshTeams` independently ports pinned MIT teams-cli Graph/OAuth contracts into
Swift actors; no Rust/TUI runtime or borrowed client identity. Encrypted service
transactions retain all received versions/checkpoints/notification events and
frozen Core projection jobs. Core acknowledges only after durable append; rich
sourcePayload participates in new-event dedup without rewriting legacy rows.
Held PostgreSQL session leases fence refresh/sync/mutations across processes.
Tenant/account/exact source scope and generation checks fence publication.

MainActor Teams models conduct typed commands; OAuth/RS256/loopback/Keychain,
protocol/paging/SQL/crypto/preparation/download/export run on service executors.
Durable independent upload/grant/post stages never replay unknown outcomes. Files
are encrypted S3 or private local spool, not database byte arrays; thread file
policy maps to its parent channel. One notification delegate adds opaque Teams
routes. Source-scoped dossier identity retains guest tenant/user attribution.
See [Teams behavior and limits](teams-migration.md) for capability grants, ACL
restrictions, operational history ordering and unverified real acceptance.

## Telemost service boundary

MakoshTelemost is a concrete actor service alongside the other channels.
TelemostWorker owns API/OAuth/vault/repository lifetime and account-generation
fences. TelemostRepository owns encrypted records, append-only observations,
durable attempts and held PostgreSQL session leases. Explicit dossier projection
uses idempotent Core source-note commands and returns the current merged owner.
MainActor TelemostWorkspaceModel only conducts window-scoped values/commands.
No Telegram types, speculative plugin framework, Linux runtime or calendar is
introduced. The fixed native OAuth callback only returns to the leased worker;
HTTPS meeting handoff is a separate explicit command.

Telemost authorization rejection is durable and source-scoped: an encrypted
credential gate references a confirmed-grant epoch, without storing token bytes.
REST admission rechecks that epoch under the account lease; Connect/restart cannot
reuse a known-rejected credential, and an older response cannot revoke a newer
confirmed grant. Source-stamped dossier notes retain Core's existing plaintext
storage limitation; their Telemost projection jobs/versions remain encrypted.

## WhatsApp open questions — 2026-10-16

MainActor owns composer/editor/picker/call-window state and scoped commands.
Repository owns additive encrypted batch/compose/photo metadata and session
advisory leases; file/photo actors own encrypted local/S3 preparation, ImageIO
render and recovery. Rust per-call tasks own encoded audio, independent source
decoders, SDK mixing and bounded fair video routing. Swift group-media actor owns
at most9 private H264 queues; codec drain/VideoToolbox waits occur off main.
Account/chat/draft/export/call/PID/visibility revisions and callback nonces revoke
late results before UI publication. Constructors do no provider/key/device IO;
explicit QA validates both schemas, endpoint/files/root ownership before service
construction and excludes other service/OS/device hosts. See whatsapp-migration.md
and development-status.md for actual acceptance limits.


Mail reading-first composition (2026-10-18): account/folder/search/compose controls
span the two mail panes. One shared 54pt pane header aligns list and reading
actions. A scoped resizable WorkspaceSplitView uses a transparent eight-point
hit region and accessibility increment/decrement; per-section widths are local
window state. Mail dossier is an edge-to-edge optional pane, with no system
inspector material gutters. MakoshMenu/MakoshPicker use app-owned SwiftUI popovers
and public container tags; segmented/radio controls and native context menus
retain their platform representation. Each popover owns focus/navigation state;
rendered enabled-row preferences determine keyboard order. Service workers,
authorization, protocol identity, retention and account generations are unchanged.

### Telegram workspace folder presentation

The Telegram branch adds a service-owned folder rail and top navigation around the
existing list/detail. `TelegramModel` owns the account-scoped observed filter IDs,
selection and native page admission. `TelegramWorkspaceFolders.swift` constructs
native filter/page pipelines outside MainActor; publication rechecks account,
connection generation, folder and request. No app-owned universal folder schema or
local approximation over one loaded page is introduced. The optional dossier reuses
current source-scoped profile/link contracts; its UI does not bypass contact workers
or infer notes from a chat. Rich native input remains responsible for formatting,
selection, undo, draft routing and send admission; only its composer surface changes.

## ADR-013: MakoshAI service boundary — 2026-11-04

Spec: `docs/superpowers/specs/2026-11-04-ai-domain-design.md`. `MakoshAI` is a
service module beside Mail/Teams/Telemost: `AIWorker` (actor) owns
OpenAI-compatible HTTP/SSE (`AIClient`, own `URLSession`, no SDK, bodies never
logged), `AIRepository` owns `ai_records` in the configured schema with AES-GCM
values under keys derived from the archive vault key (`makosh-ai-*-v1`), and
`AITokenVault` keeps API tokens only in the Keychain
(`org.makosh.ai.tokens.v1`). Roles (chat, embeddings, images, transcription,
speech) map to a connection and model; an unassigned role disables its action.
`AIWorkspaceModel`/`AISettingsModel` live in `Presentation/` with `package`
access; the app's `AIHost` shares one worker between the workspace window and
the settings scene. One generation runs per conversation; deletion bumps an
epoch so late deltas are never written. Conversations are the only
user-deletable history in Makosh; the message archive is unaffected. The S3
bucket denies DeleteObject, so generated images carry a random per-image key
stored only in the encrypted message record — deleting the conversation
forgets the key, local copies are removed. Part 1 has no RAG, tools or
cross-domain embedding; `MakoshAI` imports no other service module.

## ADR-014: AI access flags, index and retrieval — 2026-11-04

Spec: `docs/superpowers/specs/2026-11-04-ai-domain-design.md`, plan
`docs/superpowers/plans/2026-11-04-ai-domain-rag.md`. Chat and mailbox flags are
`AIAccessScope` rows in the encrypted `archive_ai_policy` table of
`MessageArchiveStore` (backed up; older backups without the table restore).
The contact flag is `Contact.aiAccess` (`inherit`/`allowed`/`forbidden`); a merge
keeps `forbidden`, undo restores both cards. `MakoshCore.AIIndexSource` is the only
contract the index reads: `MessageArchiveIndexSource` follows the shared archive
(Telegram, WhatsApp, Teams; mail events skipped) and `MailAIIndexSource` follows
retained letter versions. Back-fill reads the current state (latest version, deleted
omitted). `AIIndexer` keeps per-source cursors with a 1000-sequence re-read window,
back-fills newly opened scopes, purges closed scopes and forbidden authors, and
re-checks access after every provider response before storing. `AIVectorStore`
(pgvector, own connection) keeps one generation per embedding model with a partial
HNSW expression index; chunk text and references are AES-GCM, vectors are clear.
Retrieval re-checks access for every match and sends permitted chunks as a leading
system turn; answers record `AISourceReference`s. The app's `AIArchiveAccessProvider`
joins archive flags with dossier contacts; `MakoshAI` still imports no service module.
