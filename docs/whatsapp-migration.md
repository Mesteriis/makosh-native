# WhatsApp migration — 2026-10-15

## Scope and accepted foundation

The user approved block 1: core/dependency review, companion QR connection,
protected durable session, account selection, chat list and paged retained history.
Block2 now implements durable sending/media, retained statuses/receipts, rich
presentation/search/export, notifications/settings/S3 controls, dossier and
personal audio/video calls. Final acceptance evidence is in development-status. No real
WhatsApp account is linked by this task. Telegram/mail/call/Keychain live QA stays
paused. A real QR scan/link and real history/network recovery require a separately
selected test account and the user's instruction to resume that acceptance.

Selected reference: mdenizay/whatsapp-zen
790066aa411d395562a572101a74057147af67db. Own facade adapts its Rust Bot/event
mapping and Swift pairing/sidebar/message layout with the same whatsapp-rust
0.7.0 stack. No alternative backend is substituted. Global CORE/VIDEO_SINK,
plaintext app.db/session.db, private logger, legacy session adoption, automatic
logout cache deletion, destructive LID→phone rewrites and app locking are excluded.

## Open questions — user decision 2026-10-15

The user explicitly asked to keep the following items open after the two
implementation blocks. The original list below records that decision; the approved2026-10-16 execution
update follows it. Items are accepted only with the current development ledger
evidence, not merely because their implementation was requested.

| ID | Open question | Current behavior / remaining work |
| --- | --- | --- |
| WA-OQ-01 | Readable contact cards | Implemented bounded structured cards with original source retained; synthetic native card/raw-fallback views verified. |
| WA-OQ-02 | Poll presentation | Implemented exact normalized-question suppression; duplicate option labels retain distinct source indices. |
| WA-OQ-03 | Status entry in the chat list | Implemented exact status-row exclusion from ordinary lists/recipient selection/counts; retained archive/status workflow stays available. |
| WA-OQ-04 | Dossier visual acceptance | Complete the visual check of the linked dossier. CUA's native pipe closes on opening DossierView while the app stays alive; persistence/link tests pass. This is not evidence of an application crash. |
| WA-OQ-05 | Profile photos | Implemented scoped encrypted cache and bounded photograph view; initials remain the unavailable-photo fallback. Synthetic native images verified; real provider acceptance pending. |
| WA-OQ-06 | Multiple attachments and transfer limits | Implemented ordered batches up to10 files,100MiB each/1000MiB total, durable child receipts and unknown-no-replay. Synthetic ten-file/reorder/restart/unknown UI verified; real provider acceptance pending. |
| WA-OQ-07 | Media editor | Implemented Zen native photo editor: crop,rotate,pen/arrow/rectangle,six colors,undo/reset,caption and standard/HD. Source/recipes/exports recover independently; video editing remains outside the approved photo scope. |
| WA-OQ-08 | Group calls | Implemented pinned SDK group start/accept/invite/ring/leave, up to32 participants, mixed per-source codecs and9 visible video decoders. Synthetic picker/grid/paging/pin/leave verified; real signaling/media acceptance pending. |

On2026-10-16 the user requested WA-OQ-01/02/03/05/06/07/08. The pinned SDK source
does contain group builders/rosters and sender-aware media; Makosh's current
wrapper now uses that public API. The user approved the [written specification](superpowers/specs/2026-10-16-whatsapp-open-questions-design.md)
with target limits and regression criteria. The [ten-task implementation plan](superpowers/plans/2026-10-16-whatsapp-open-questions.md)
was approved for native inline execution in this chat with one final inherited-model
review; Tasks1–10 implementation now covers readable contact/poll/status presentation, scoped
avatars, bounded sequential attachment batches and native Zen photo editing with
encrypted source/recipe/compose recovery, and SDK-bound group signaling/rosters, participant-aware mixed audio and bounded video, explicit participant selection and a paged/pinned native call grid.
One fresh independent review found 0 Critical/6 Important/2 Minor. All six
Important findings were reproduced and fixed in one pass; current full suite
(Swift2864 including WhatsApp142, Rust58, Python153), strict Clippy,
absent-reference canonical build, QA005 inventory and fresh corresponding-source
offline rebuild pass. One existing Telegram microphone-precondition skip remains.
Post-review regressions cover partial preparation/Return, export cancellation,
late chat restoration, departed video selections, reused group call IDs and the
release QA-launch policy. The reviewed SDK preparation patch forwards its own
transition generation; package versions/features are unchanged. Two deferred
Minor limitations remain: per-account recipe lookup work grows before chat
filtering, and canceled avatar waiters do not stop the shared request immediately.
Photo crop/mark dragging is unverified because CUA rejects coordinate drag;
other editor controls/restart and enlarged native workspace were inspected.
Synthetic proof and provider acceptance remain separate.
WA-OQ-04 remains separate visual acceptance.

Real-account QR/link, provider delivery/download/status/PN-LID correspondence,
ordinary-bundle OS banners, Keychain/TCC and hardware call acceptance remain a
separate paused acceptance lane; see [current status](development-status.md).
Active-call device switching, local app passcode and automatic app locking remain
excluded by the user's decisions and are not open migration questions.

## Licensing and independent build

Source audit found 31 Signal Messenger files carrying AGPL-3.0-only headers in
wacore-libsignal, despite Cargo's MIT declaration. The user explicitly chose a
separate Rust worker under AGPLv3 on 2026-10-15. Main Swift application licensing
is unchanged; no Rust code links into its executable. Dependencies/WhatsApp.lock.json
records exact reference source hashes, 277 active target package checksums,
declared/effective licenses, AGPL file hashes, copied notices and build scripts.
Full AGPL and Zen MIT notices and transitive texts live in LICENSES/WhatsApp-*.
Private tracing, insecure TLS/certificate and legacy-session features remain
excluded. Personal VoIP uses the reviewed feature graph and independently
pinned static Opus1.6.1; active-call device switching is excluded. Do not replace that review with package metadata alone.

scripts/prepare-whatsapp.py uses Rust1.97.0, the independent Cargo.lock and public
checksummed registry sources. It verifies every published active source file and
reviewed graph/notices/build scripts before compilation. It never reads research
clones, previous projects or account stores. macOS27 rejects stripped proc-macro
dylibs with a mis-aligned LINKEDIT string pool; own release profile uses strip=none.
The reviewed `durable-history.patch` is applied reproducibly to a separate
public SDK copy, never by editing ignored generated files or a registry cache. --test runs native offline tests;
--sources produces .build/MakoshWhatsAppWorker-Source.tar.gz. App packaging includes
the separate worker, relocated/signed runtime closure, licenses and this source
archive in Resources; the WhatsApp information menu reveals license/source files.
See Dependencies/WhatsApp/README.md for standalone source build and IPC contract.

## Executors and lifecycle

WhatsAppWorkspaceModel is a MainActor conductor only. WhatsAppWorker owns account
commands, state aggregation and journal transfer. WhatsAppRepository owns SQL,
archive, key access and crypto on its actor. WhatsAppNativeSession owns blocking
framed IO on a dedicated Dispatch SerialExecutor, so a slow child cannot occupy
the shared cooperative pool used by the other service actors. The separate Rust
process owns Tokio, protocol callbacks and encrypted SQLite. QR image generation
explicitly leaves MainActor. UI publication checks account and selection generation;
late history or QR completion cannot cross accounts/chats. Teardown is asynchronous.

Each worker owns one private 0700 account directory and a 0600 exclusive flock
lease; unsafe file type/ownership/mode/hardlink cases fail closed. Session keys
use org.makosh.whatsapp.session in the macOS login Keychain, separate from archive
vault keys and all Telegram credentials. Existing cache with a missing/wrong key
is preserved, never replaced. Opening a worker is offline; Connect starts the Bot.
Disconnect/cancel closes local admission and gracefully flushes/stops, without a
remote unlink or file deletion. Remote logout is surfaced; it never deletes keys
or relinks automatically. A fresh explicit account identity can be linked while
old history remains accessible. This block does not add session-reset controls.

IPC uses version1 length-counted private JSON frames, 2MiB request and 8MiB reply
bounds, fixed public error codes and no private logging. Native owned-buffer/handle
functions are internal worker implementation, tested separately; no borrowed C
callback or Rust pointer reaches Swift. The parent validates framing/version,
bounds waiting, reacts to cancellation and stops only its owned failed child.
A timeout/abnormal exit retains cache and journal and is never reported as a clean
protocol shutdown. Connection state/QR are transient; codes expire and disappear
on cancellation/account change. No token, QR, key or message text enters logs.

## Durable history

SQLCipher is verified before schema access and initialized on every backend
connection, with FULL synchronous commits. Protocol cache and source journal use
one shared backend pool. The inbound durability hook commits before the protocol
ack. An awaited history hook commits messages/chat metadata/names atomically
before HistorySync receipt. Newsletter and PDO fallback writes are awaited, and
the original PDO envelope also retains its recovered contents. Storage failures
suppress acknowledgements on these paths; actual server redelivery is not yet
verified. The SDK documents a remaining ratchet/durable-buffer failure limit under
total storage outage; there is no unconditional recovery claim for that failure.
Status broadcast content uses the awaited durability hook before acknowledgement.
The current status view hides items after24h; archive retention never expires. Raw received protobuf versions stay
in encrypted append-only journal records, with no TTL/pruning. The block1 no-transfer statement is historical; block2 media rules follow below.
PostgreSQL receives encrypted text and attachment metadata only, never file bytes.

Identity is (whatsapp, account UUID, exact source chat, JSON [sender, stanza ID]).
Same stanza IDs from different group senders remain separate; LID/phone aliases
never cause destructive rebinding. Edits and deletion preserve original message
time; deletion marks retained content. Distinct received versions remain in the
independent append-only MessageArchiveStore. Historical replay cannot overwrite a
newer current projection. Source version timestamps and edit/delete rank let
new historical changes advance while old replay remains retained but does not
overwrite current text. Every received message creates its minimal encrypted
chat projection in the receipt transaction, before journal ack, making a new
chat discoverable after an immediate offline restart. Stable sequence/observation identity and observed time
allow archive/projection replay after interruption; changed content under a receipt
is rejected. Only after archive and projection commit does Swift acknowledge the
source journal. That ack advances a watermark and never deletes source records.
Byte-bounded exports retain a contiguous prefix; unexported entries cannot be acked.
Failures are account-scoped and never suppress a healthy account's transfer/view.

Native and PostgreSQL paging use stable timestamp+identity tie breakers; PostgreSQL
uses opaque HMAC tokens for source identity and AES-GCM with row-specific AAD.
A disjoint new page restarts its paging range so a history burst cannot hide a
middle gap. Live unread increments once per new incoming message; history,
outgoing/control messages, edits/deletion and duplicate replay never increment it.
Push names are stored independently without rewriting source identities.
All connected accounts transfer in the background, regardless of displayed account.
No remote read/mark-read, deletion, EXPUNGE analogue, send or media command is added.

## Evidence and outstanding acceptance

Focused native and PostgreSQL tests cover malformed/oversize ABI inputs, closed
handles, offline process start, encrypted reopen, wrong-key preservation, duplicate
ownership, stable paging, duplicate sender IDs, edit/delete retention, journal
replay/bounds, ack-after-commit behavior, per-account failure isolation, QA admission
and late account-selection results. Full integration gates and final review results
are recorded in docs/development-status.md; preparation alone is not acceptance.

Isolated org.makosh.whatsapp.qa uses explicit qa_whatsapp_ application/archive
schemas and fixed test vault keys, never personal Keychain/network. Native UI
inspection verifies both account labels, the empty second account, personal history,
loading older records including retained deleted text, and the synthetic QR/cancel
screen. The synthetic code cannot link a phone and never reports protocol connected.
Current UI/source differences and final screenshot evidence are in
 docs/reference-interface.md. Evidence remains ignored in .local/whatsapp-block1/.

## Block2 native workflows

Outgoing admission stores encrypted immutable text/reply/file IDs/action and a
unique attempt before dispatch, with a PostgreSQL session advisory lock across
processes. Missing replies/timeouts/restarts become unknown; they never replay.
Explicit resume claims the same prepared row once. A retry copy is available only
after known notSent. A successful SDK write is “Передано ядру”, not delivery;
server/delivery/read/played receipts advance monotonically and retain source actors.
Requested edits/revocations/reactions do not fabricate authoritative archive events.

Native IPC jobs have two data slots, two call-control slots and one terminal slot.
Local call termination bypasses occupied jobs, revokes setup/media generations and
queues the explicit peer terminate. An awaited setup is cancelled before subsequent
work can send a late offer; the reviewed SDK patch retains generation-bound
cleanup of an ambiguous outgoing offer write, pending media and ack waiter.
Each call owns bounded PCM/H264 queues, converters and hardware sessions. The
media executor checks permissions before devices; camera OFF clears output,
codec conversion/decode remains off MainActor, and shutdown is asynchronous.
Only one personal call is active; group calls and active-call device switching
are outside the selected native-call scope. Microphone/camera remain explicit OS
permissions, never assumed from authorization for a different bundle.

Files are limited to100MiB and one attachment per message. Image/video/audio/voice/
WebP sticker/document transfer uses authenticated private leases, not JSON bytes.
Voice uses MakoshVoiceCodec shared with Telegram, without Telegram service types.
PostgreSQL stores encrypted metadata and source keys only. Per-account/chat S3
policy defaults ON for personal chats, OFF for groups/status/newsletters. OFF
forbids every new copy; preparation uses encrypted local envelopes. Enabling S3
never promotes local preparations. Pending outgoing encryption can be opened
locally without a PUT; original preparations are associated before dispatch and
reused for their own received resource, avoiding a second copy/promotion. Incoming
archive reservations persist before parent journal ACK; bounded due pages survive
restart and policy is rechecked before download/capture. Fixed public archive
errors/retry state are visible. Existing S3 objects remain readable while OFF.
Historical media download selects an exact retained resource, not its replacement.

Location/contact/poll/reply/reaction/star/pin cards use source-scoped DTOs. Encrypted
poll votes remain retained and reduce per actor by source time; unavailable keys
cannot invent votes. Search scans stable retained pages beyond the loaded window;
More continues even across an empty result page. A permanent version archive and
private JSONL export preserve all observations, including remote deletion/expiry.
Global/account/chat notification preferences restrict each other and server mute.
History establishes a baseline; muted events are consumed, never replayed. One
application delegate routes opaque durable tokens. View-once content is sanitized
before notification persistence; callback-time policy/account/unread/window/OS-lock
checks and consent revalidation apply. Settings changes withdraw stale previews.

The existing workspace owns all controls: composer, actions, outbox, status/archive,
chat/group/profile/privacy, notification/S3 forms and dossier. The common Settings
window uses weak references to existing workspaces; it never opens a second native
session. JID/account identities remain exact. No personal account, network delivery,
ordinary-bundle banner or device call acceptance is implied by synthetic tests.


## Block2 failure boundaries

Server acknowledgements, deliveries and reads can arrive before the local sent
projection. SQLCipher retains per-stanza/actor facts first and applies them when
the body arrives. Negative server ACKs remain explicit rejection facts after
socket-write success and after restart; they never authorize automatic retry.
The PostgreSQL outbox is paged by timestamp/opaque token with an index; completing
an attempt reads only its exact row. Explicit copy retry is available for a known
not-sent or rejected result.

Permanent Core observations include optional encrypted sourcePayload containing
the service-owned JSON message DTO (JSON Codable encodes this field as base64 in
JSONL). Resource ID/name/size are separate attachment metadata; no attachment
bytes enter this field. Rich contact/poll/location/receipt versions survive cache
loss and export. Existing Core observations without this field remain decodable;
no append-only row is rewritten to upgrade presentation. Pre-release block2 QA
schemas with the earlier incomplete mapping are historical evidence, not migrated
personal account stores.

Chat preference Save is admitted only after both persisted S3 and notification
rules load for that exact context. Notification willPresent/add-completion compares
the complete fresh rule with submitted content. Reconnect cancels archival task
ownership using an independent token; old cleanup cannot remove a newer task.
Remote terminal calls revoke queued acceptance and pending setup; accept cannot
fall back to a new outgoing call. The call panel hosts an explicit snapshot via
NSHostingController with window-owned sizing and asynchronous state delivery.

## Open-questions implementation — 2026-10-16

Batches freeze order and reserved per-child attempts before dispatch. Unknown or a
new NACK stops subsequent children; restart never sends. Explicit continuation
skips only failures already known when admitted; copy creates a new prepared intent.
Compose CAS/admission is atomic; later edits remain separate from an admitted draft.
Photo originals always use the encrypted local spool; recipe operations remain
metadata. Only current-revision standard1600/HD4096 exports are eligible to send,
never an unedited fallback. S3OFF applies to every derivative/recovery path and
ON never promotes previous local preparations.

Native calls use the public encoded_audio interface because the SDK PCM path emits
Opus group packets separately. Independent MLOW/Opus decoders feed the SDK
participant mixer; personal jitter/foreign-playout behavior is preserved. SDK owns
authentication/SRTP/rekey; sender/device/PID and wrapper call epoch gate routing.
Video latest-per-visible-source queues fairly return at most4×256KiB per exchange;
IPC stays2MiB/8MiB. Swift owns at most9 stream codecs, checks1920×1080/portrait
dimensions before decoder allocation and renders tiles at most640×480. Page
revision/roster/callback nonce fences retire old streams asynchronously.

Group start requires an explicit2–31 remote selection. Local aliases are excluded
using the SDK identity marker, not names. Remote roster pages/pins are separate
from local preview; invite/ring and leave are scoped to the owning call/epoch.
The UI says “Покинуть звонок” and does not promise to end other participants' call.

`python3 scripts/run-whatsapp-qa.py --launch` stages a fresh owner-only ignored
run with both qa_whatsapp_ schemas, pinned loopback PostgreSQL/S3, fake keys and
avatar HTTP, synthetic permanent messages/unknown batch and generated fixtures.
It checks exact executable text, signatures and public source resources. The
marked bundle fails closed without explicit configuration; Telegram/mail/Teams/
Telemost/OS notifications and physical media hosts stay disabled. The synthetic
status remains offline and queue/call previews are labelled. This lane is not
WhatsApp delivery or hardware proof. Current exact gates/UI limitations are in
development-status.md; live acceptance remains paused.

### Cancellation ownership during setup

Each UI invocation supplies a unique optional callContext for start/accept and
early End. The native worker binds it to the current epoch and peer; an old
context cannot end a replacement call, even before a start receipt arrives.
Legacy controls still require their existing ID/epoch checks. A known accepted
start receipt carries optional callEpoch; late UI cleanup additionally validates
the worker-owned current session generation, exact call ID/epoch/peer and durable
receipt before admitting a targeted End. Unknown results never authorize a new
call or account-wide cancellation. Media revocation precedes asynchronous drain;
protocol termination uses the existing reserved control lane and SDK teardown.
