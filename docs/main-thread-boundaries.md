# Main thread and service execution

## Required boundary

MainActor owns presentation, user approvals, command routing and aggregation of
service state. Telegram is one adapter in the common workspace, alongside the
planned mail, WhatsApp and other services. A service's protocol, persistence,
file preparation, cryptography and media processing must not run on MainActor.
This does not introduce a general plugin framework or replace reference layouts.

Each service owns its execution and lifetime. Commands cross the boundary with
immutable inputs; observations return immutable results. UI publication must
check the account/editor generation after every suspension. Cancellation revokes
publication and stops cooperative work; a synchronous native operation may need
to finish before its worker can acknowledge release. No UI teardown may wait
synchronously for that release.

Native callback construction is part of this boundary. A closure created in a
MainActor method may inherit that isolation even when it only transforms data.
Construct background pipelines, including nested transactions and admissions,
in nonisolated helpers. Deliver only presentation results on main. A final
`deliverOnMainQueue` does not protect transformations that precede it. Do not
disable actor checks or move native transactions onto main to hide violations.

## Audit scope and evidence — 2026-10-14

The audit starts at local base `76c43e63fc37bc9254cc163d6a0a2e46acab6a42`,
including uncommitted startup repairs. Immutable review snapshots cover289
Telegram sources and122 App/Core/C bridge sources; their complete file hashes
were checked twice. Root separately reviews the four changing startup files.
Lexical XERJ searches were source-confirmed; this is risk-focused concurrency
review, not proof of every runtime path or measured performance.

Confirmed producer/actor mismatches include startup call observations, unread
counters, MediaBox auxiliary methods, search/sender transactions, message action
validation/enqueue admissions, secret-chat pipelines and group-basis mapping.
Real encrypted synthetic fixtures reproduce startup and callback failures;
focused regressions verify the repaired pipelines. The suspected native proxy
target callback already passes the actual MTContext producer regression and
was excluded without a production change.

Confirmed blocking paths include Contacts SQL/import/duplicate computation,
upload hashing and validation, proxy/session Keychain access, cover/avatar
preparation, wallpaper installation, native call queue waits and per-frame call
image conversion. These are source-established work boundaries; no duration or
frame-rate measurement is claimed. S3/archive repositories already own actors;
backup operations and several media preparations already use workers.

Notification completion handlers are a separate SDK boundary. Apple's
[settings callback contract](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getnotificationsettings(completionhandler:))
permits a background thread. Capture callbacks must enter without actor
inheritance, then explicitly publish on MainActor.
Standalone SILGen probes against the installed Swift6 SDK confirm all five
notification completion APIs already import `@Sendable` and their outer
callbacks are nonisolated. The suspected notification entry defect is excluded;
no production change is justified by the raw Objective-C headers alone.

## Implemented boundaries

1. `ContactWorkspaceWorker` owns configuration, the PostgreSQL connection,
   imports and duplicate computation. Its unsuspended actor commands serialize
   writes with refresh, preserve uncertain-COMMIT refusal, and report a known
   committed write separately from a failed display refresh.
2. `TelegramSessionWorker` and the proxy-vault actor own session and Keychain
   work. Account/connection revisions reject obsolete results after suspension.
3. `BackgroundWork.run` explicitly uses a concurrent executor for immutable
   file/hash/image preparation. Upload restore and cover commits recheck their
   account/chat/editor/file/recovery admission before transferring ownership.
   Cleanup of rejected owned assets remains active after task cancellation.
4. Native pipelines are constructed nonisolated. Chat/history projections run
   on native view producers before main delivery; UI receives snapshots.
5. Native call commands run FIFO on a dedicated worker, with bounded control,
   signaling and latest-frame queues. Stop revokes admission immediately;
   native release acknowledges retirement asynchronously. Frame conversion has
   its own worker and one latest waiting frame, with UI publication acknowledgement.

These boundaries apply to future mail and other service adapters. They do not
require the UI coordinator to implement a service's process or introduce a
shared protocol engine. Small UI calculations and presentation callbacks remain
on MainActor; this audit does not claim the elimination of every filesystem
metadata operation or prove a maximum latency for third-party teardown.

Independent native and UI/Core reviews cover the implementation. Both final
review findings have focused regression proof: cover ownership survives account
replacement/deinit through durable acknowledgement, and continuous input cannot
starve completed frame publication. Complete gate and signed UI outcomes are
recorded separately in development status.
Real-account content, sending, calls and physical devices remain separately
authorized. Active-call device switching and a local passcode/autolock remain
excluded by the user's decisions.

## WhatsApp block 1 — 2026-10-15

WhatsAppWorkspaceModel owns presentation/account/selection generations only.
WhatsAppWorker performs service commands and transfer on its actor; repository
actor owns PostgreSQL/archive/Keychain/crypto. NativeSession uses a dedicated
Dispatch SerialExecutor for blocking private IPC. Protocol callbacks, SQLite and
Tokio live in a separate owned Rust process. QR image generation is @concurrent.
No model/view initializer starts account IO; only explicit Connect creates/opens
a session. Cancel/close is asynchronous and stale QR/history publications are
rejected by account/context checks. Native offline lifecycle and late-selection
regressions are synthetic evidence; they do not prove a real linked account.


## WhatsApp block2 — 2026-10-15

Composer/actions/search/preferences/call controllers conduct scoped UI values.
WhatsAppFiles owns private file leases, crypto, S3 policy/preparation/recovery;
repository owns bounded paged SQL and durable attempts. Native asynchronous jobs
have reserved call-termination capacity. Audio capture/conversion, bounded PCM,
H264 encode/decode and device enumeration stay on owned private media executors.
Call generations cancel setup before late signaling; the narrow AppKit panel owns
only window hosting/close. No protocol callback or native queue inherits MainActor.

## Teams — 2026-10-16

`TeamsWorker`, repository/session/Graph/OAuth/token-vault/loopback/file actors own
service IO and processing. `TeamsWorkspaceModel`, composer/preferences/history
models are MainActor conductors with immutable scoped values and generation checks
after suspension. JSON/HTML-to-text projections use BackgroundWork; Quick Look and
AppKit panels remain narrow native UI bridges, file capture/copy/hash outside main.
Constructors perform no account/key/network IO. Cancellation revokes publication;
shutdown asynchronously drains admitted receipts before closing persistence.
Synthetic tests cover suspended selection/preparation/settings/auth and native UI
was inspected with isolated fake accounts. This is not measured latency proof or
real Microsoft/Keychain acceptance. See teams-migration.md and current status.

## Telemost first stage

REST/OAuth/JSON, PostgreSQL, AES/HKDF, Keychain and JSONL export run on service
actors. History presentation decoding uses BackgroundWork. The MainActor model
owns account/meeting/draft revisions and publishes only current results; Core
snapshot and owning-key-window checks fence final dossier navigation.
ASWebAuthenticationSession callback construction is nonisolated and explicitly
hops to MainActor. Close revokes publication and asynchronously drains admitted
receipts. A30-second local snapshot check updates expiry without provider polling.
No protocol connection, account read, native browser or credential IO occurs in
constructors. Synthetic mode validates both qa_telemost_ schemas before stores,
uses memory transport/vault/opener and excludes all other service hosts.

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
