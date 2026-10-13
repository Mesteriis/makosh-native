# Telegram channel

## Notifications on this Mac (2026-10-13)

The common workspace opens Notifications and Sounds from Telegram settings;
each profile opens a local per-chat exception editor. Account-scoped local
preferences support a master switch, previews, system/silent sound, Dock attention,
active-app suppression, timed snooze, private/group/channel policies and per-chat
overrides. They never write server notification settings. Server mute, hidden
previews, silent messages, topic rules and already-read state remain authoritative.
Reset explicitly resets local settings only. Malformed/corrupt/oversized stored
records fail closed until an explicit reset; an absent record uses defaults.
At most512 peer exceptions and64KiB
of encoded settings are admitted. Account/context changes reject stale editors.
Controllers using the same in-process preferences store propagate account-local
changes to other windows, invalidate their old cards and retain their engine
subscriptions. Other accounts/stores are not affected. One app-owned system
delegate routes opaque tokens to the owning workspace/window; opening another
window cannot steal the first window's routes. Dock aggregation counts each
account once, using its largest observed window count. A separate4096-key app
cache suppresses the same event arriving through multiple windows; its native
identity stays in memory and is never included in the system payload.

Only AccountStateManager.notificationMessages feeds new notifications. Native
resolution uses fresh messagesForNotification inside an encrypted Postbox transaction;
it does not infer arrivals from loaded history or an initial chat-list snapshot.
An own locked pump retains one read and at most1000 unique pending IDs, without
replacing an in-flight read. Each raw update is bounded at10000 IDs; IDs are
deduplicated before the1000-unique-ID transaction limit. Overflow drops excess
pending arrivals and reports a warning once per binding; it does not discard
messages or their archive. Album identities coalesce repeated members, using the
first nonempty resolved caption and its native privacy/silence constraints.
Incoming events older than24h or more than60s in the future are refused. A process-
local4096-entry identity cache survives rebinding; it is not a durable exactly-once
delivery guarantee. At most100 current click routes/system submissions are retained.
Unread badges use full native filtered root counters, including bot/private tags,
with separate group/channel switches and messages/chats modes. Archived counters
are excluded; loading another chat-list page cannot change this count.

Own UNUserNotificationCenter delivery asks permission only from an explicit button.
Spoilers and service login codes are masked; protected and secret content remains
generic. Screen-lock events remove existing owned cards and hide subsequent titles,
body and sound; this is best-effort removal, not erasure of content already seen by
macOS. Disabling previews/settings, account changes and disconnect invalidate owned
cards/routes. Late asynchronous cleanup preserves newer submissions. The system
payload contains only an opaque activation token, with no credentials, peer IDs,
media fetch, reply action or implicit mark-read. A click must resolve a live same-
account single-use route and pass the ordinary model navigation guards; it then
opens the chat/topic/message in the existing common workspace. Reopening the app
does not restore old click authority. It must be running and explicitly connected;
background push while terminated is not implemented.

DEBUG synthetic workspace controls exercise local settings and own macOS delivery
without a Telegram account. The system delivery probe queries only this QA bundle's
current opaque synthetic token; it never inspects other applications' notifications.
Local tests/native QA are recorded in development-status.md. Server-synchronized
notification editing/reset, cloud/bundled Telegram tones, joined-contact controls,
reactions/stories/scheduled reminders and banner reply/read actions are outside this
slice. Per-chat S3 prohibition, permanent message retention, PostgreSQL schema,
engine pin/recipe and dependencies are unchanged. Reference layouts and explicit
adaptations are recorded in reference-interface.md.

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
python3 scripts/prepare-opus.py
python3 scripts/prepare-opusfile.py
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

The extended-message block (2026-10-12) adds selected reply quotes, observed
server drafts, custom emoji, syntax highlighting, ordinary forum topics and
explicit secret/paid-send boundaries within the common workspace. Historical
open-item notes below are superseded by this contract and the current validation
ledger in `development-status.md`.

- Selected quotes preserve trimmed Unicode/UTF16 entities, pack provenance and
  validated reply media. The current `quote_length_max` is observed from native
  account configuration and rechecked in the queue transaction. Quotes remain
  attached through topic drafts, voice/round uploads, Archive and restart.
- Server draft observation is read-only. Initial local restoration completes
  before reconciliation; independent edits show an explicit local/remote choice.
  Native version/basis/local revision checks and atomic Postbox acknowledgement
  prevent stale replacement and echo. Same-timestamp native changes are observed
  by preparation recipe11. Unsupported native payloads fail closed.
- Account-bound custom-emoji catalogs expose recent/installed/featured/search,
  pack loading and installation. Native editor insertion preserves typed text,
  selection and Undo. Current full document and account tier are checked again
  before enqueue/edit. Visible WebP/TGS/WebM playback and topic icons use owned
  bounded decoders; hidden spoilers/offscreen views release their leases.
- Caption schema22 explicitly enables custom emoji on frozen resource schema19.
  A new marker is mandatory; older wires keep their original projection and
  reject injected new policy fields. Schema20 wraps selected quotes and schema21
  topic identity without changing their frozen resource policy. Restoring an old
  preparation never silently promotes it. Recorded media and old preparations
  without a frozen caption policy have no custom-emoji picker.
- Code blocks retain their language/copy/selection/spoiler behavior, adding
  source-bound syntax colors from independently pinned Prisma/Boost sources.
  Unknown languages, stale/cancelled work and rejected bounds keep plain code.
- Forums have an observed topic list and independent draft/history/search/read
  and upload/forward scopes, including General. All Messages requires a selected
  topic or a validated ordinary reply destination; paid consent requires an
  explicitly selected topic. Native admission rechecks current topic/content
  permissions and the caller's durable receipt. Retained topic data passes a
  bounded check before native seed rendering/forum operations and the legacy
  decoder (recipe14:512KiB,16 nesting levels,1024 fields). Truncated bytes,
  unsupported wire profiles, invalid notification variants, overflowing legacy
  sound IDs and noncanonical author bits fail closed.
- Paid sends confirm an immutable destination/count/unit-price/total for each
  submission. Current fee, consent Begin/consume and queue insertion share one
  native transaction. Forwarding never inherits the source message's old charge
  (recipe12). Human confirmation pauses the outer timeout; after native work
  begins, a missing ACK remains recoverable and cannot enable automatic resend.
- Secret chats expose current state and reference fingerprint verification;
  sending is restricted to active plain text with validated native keys/layer.
  Secret media, rich text, replies/forwarding, key-agreement and TTL workflows
  remain unsupported. Paid-media access/price is displayed without a purchase or
  media-fetch grant. Balance purchase and paid-media purchase are not implemented.

Extended search adds separate account-bound global and conversation requests.
The existing sidebar searches messages with media categories, all/private/group/
channel scopes and an optional selected chat. Local chat suggestions retain the
cached-list boundary. Conversation search adds sender suggestions, older/newer
navigation across pages, return to results and a calendar jump to local midnight.
Opening a result retains the query and the destination's separate draft; stale
result contexts cannot activate another account/chat/topic. Media sources are
retained only for current results/history. Requests retain300ms debounce and30s
deadlines; failed pagination preserves prior results and permits retry.
Calendar and result navigation cancel an older pending selection independently
of pagination. Only actual forum peers use a positive exact Int32 navigation
topic: ordinary channel thread1 and Saved/monoforum sub-peer threads open the
supported all-messages history. Saved sub-peer navigation is not implemented.
Chat-restricted global matches retain the selected modern conversation even
when the native result index belongs to its migrated group's older history.

Preparation recipe18 rejects unresolved authors, inexact ordinary topic IDs and
invalid Saved/monoforum sub-peer identities before native RPC flags or PeerId
construction. Global local-Secret merging excludes group/channel scopes and
filters native tags before counting. Postbox's empty global FTS query cannot
enumerate Secret media: this limitation is visible, and scoped Secret searches
with an author or empty text+media fail explicitly. Full Secret media search,
Saved-tag suggestions, complete participant directories, remote peer/hashtag/
Stars discovery and the specialized reference result/calendar renderers remain
open. These additions do not establish real-account network acceptance.

Playback supports a deliberately narrow SDR8-bit420 WebM profile: at most8MiB,
512px canvas,9s and3240 blocks. Explicit projection/content-encoding/mapping or
stereo profiles use Unicode fallback. These input/output limits do not establish
a whole-process memory or hard real-time bound. Full Telegram sticker/media
parity and actual Account/network delivery remain outside this validation slice.

Debug UI scenarios use `--telegram-extended-messages-synthetic-preview`,
`--telegram-secret-synthetic-preview`, `--telegram-paid-send-synthetic-preview`
or `--telegram-server-draft-synthetic-preview`, together with `--database-config`
pointing to an isolated `qa_telegram_dossier_…` schema. They retain the common
service sidebar, never connect an account, and cannot send or spend Stars.
The draft scenario exercises the real Model conflict/choice lifecycle with an
explicit in-memory fixture; native persistence has separate Postbox regressions.

The current Telegram media preparation contract is described in
`telegram-album-migration.md` (Media block,2026-10-12). New ordinary picker
preparations use schema19 with account-derived caption limits, current Markdown
and cloud-hashtag projection, and final native File-caption capabilities.
Earlier1024-only and unfinished-preview notes below describe historical slices;
schemas1–18 retain those frozen rules. File/Media chat drops and append into the
open preview use cancellable local-URL loading and the ordinary staging pipeline.
Append preserves old immutable resources and installs a verified complete
candidate with full-byte Postbox CAS; only installation can be retried after
capture. File/music/PDF/static-WebP previews read owned local files and never
autoplay or fetch from the network. Full animated stickers, image editing,
hardware capture and live Account/server acceptance remain separate work.

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
  Secret-chat UI and its read handling remain unsupported; ordinary cloud
  replies and visible-history read marking are described below. Unknown media
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
  not send it: a modal preview shows the frozen recipient, document card or
  bounded photo thumbnail, and editable caption. Switching chat keeps that recipient; stopping/replacing the account
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
  outbox, clears only the captured full draft revision in its original chat, and releases
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
- Ordinary text drafts are isolated by account/chat and persisted in encrypted
  account Postbox, including explicit empty snapshots. Revision guards preserve
  text edited since submission, including normalization-only edits. See the
  composer-persistence section for limits and retry behavior.

Tests cover config rejection before account work, exact-source preparation,
draft/account isolation and acknowledgement races, disabled logger setup and
real OpenSSL modular arithmetic/binary roundtrips. Build, tests and native setup
UI checks are distinct from real authorization, incoming sync, sending,
reconnect or cache-corruption acceptance. See [`development-status.md`](development-status.md)
for actual completed checks and outstanding runtime limits.

## Visible-history read marking

The common workspace marks an ordinary cloud conversation through its latest
actually visible stored message, following TelegramSwift's visible-height
tolerance of 10 points. A stored outgoing row also advances preceding incoming
messages. Merely loading a 50-message window does not mark the entire window.
Search results supply no read indexes. Loading/timed-out history, pending or
failed outgoing rows, secret chats and scheduled/local messages cannot supply
the boundary. Dedicated topic/thread read handling remains future work.

SwiftUI supplies row/viewport geometry. A narrow AppKit view checks its current
window immediately before admission: the app must be active and the window key,
visible, unminimized and unoccluded, without an attached sheet or application
modal window. Detach/dismantle invalidate the weak eligibility callback. Account,
chat, account generation and history-request guards reject stale observations.
The guarded native history may include an associated old peer after a group
migration; its original message/peer index is retained. No selected-chat index
is manufactured. Repeated/lower boundaries are deduplicated per peer/namespace.

The provider uses the engine's `applyMaxReadIndexInteractively`. Completion means
the local Postbox transaction completed, not that Telegram acknowledged a server
read receipt. An accepted operation retains its original account after UI
unbinding. Native tests verify unchanged message content/version and retention
journal while read state changes.

Preparation recipe 5 repairs the pending-read table's reopen scan: the pinned
SQLite implementation's signed `key > 0 AND key < -1` range loaded no rows.
The exact-source, hash-checked GPLv3 adaptation uses `scanInt64`, without changing
the schema. An encrypted Postbox regression verifies both read state and pending
push synchronization survive release and reopen; it does not authenticate or
claim a successful network receipt. Preserve an older prepared engine under an
unused ignored backup name before preparing recipe 5; never edit generated files
or remove account/session storage to update it.

The DEBUG-only `--telegram-history-read-synthetic-preview` route uses the same
common workspace and isolated database requirements as the dossier QA route
below. It starts in search with zero local read admissions. A synthetic-only
footer exposes actual viewport admissions/window eligibility. No real account,
Keychain or Telegram network is opened. Runtime results and remaining acceptance
limits are recorded in `development-status.md`.

## Reference message status indicators

History retains the engine's `MessageHistoryEntry.isRead` when projecting a
message. Read-state-only emissions update the existing guarded history window.
Search receives bare messages and therefore never invents a remote read
receipt from a missing history context.

Own SwiftUI rendering follows the confirmed `ChatRightView` arrangement: time
with a clock while queued/sending, an error on failure, one check for a stored
cloud message and two for native read state. Pending/failure flags take priority
over read and remain visible for outgoing channel posts. Stable incoming and
broadcast messages have no check; unsupported local/scheduled namespaces without
pending flags are not announced as sent. One check does not promise delivery to
a recipient device. Group read state does not identify individual readers.

Saved Messages and bots use the reference's double-check convention with
distinct accessible descriptions; support peers are excluded from that
convention. Source-reference messages conservatively retain one check because
the full upstream crosspost/pinned/custom-mode presentation is not yet mapped.
Actual server receipts and local-to-cloud pending ID reconciliation still need
live-account acceptance. The offline fixture demonstrates all five ordinary
states without contacting Telegram.

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
Fresh checkouts prepare recipe 9 directly, retaining the recipe-4 journal,
recipe-5 read scan and recipe-6 enqueue hooks. Recipe 7 adds the hash-checked
cached ID index lookup used by Shift selection. Preserve older prepared source
under an unused ignored backup name before preparing recipe 8. Recipe 8 adds
exact-hash-checked selected-message admission inside native delete's transaction.
Recipe 9 adds a local enqueue entry point sharing the Account API's transaction
wrapper and native message-construction core. Its three Account inputs become
explicit scalars; the production API keeps its outgoing-media transformation
and reads the server-adjusted clock at the original point in the transaction.
Source/output digests and a reverse-substitution body digest guard this patch.
Preserve recipe-8 preparations under an unused ignored name before regeneration.
Offline encrypted Postbox/MediaBox tests exercise this shared core with actual
MP4/MOV bytes, options, atomic receipts, reopen and duplicate admission refusal.
They do not construct Account/network managers or prove Telegram server delivery.

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
  copies in S3 when **Сохранять файлы в S3** is enabled for that chat. Personal
  cloud chats default on; groups and channels default off. The choice is scoped
  to account/chat and persists in PostgreSQL; disabling preserves message text
  and existing objects. Off also prohibits new outgoing preparation copies in
  S3, including photo originals and video covers. These resources recover from
  encrypted local receipts/envelopes and never enter S3 retry after re-enabling.
  Older tagged/untagged preparation queues use the same resolved chat policy.
  An open file descriptor is captured synchronously before the
  first suspension; subsequent Telegram cache unlink does not remove its bytes.
  PostgreSQL stores encrypted metadata/object references only. Preview-only or
  never-downloaded media remain metadata. Opening the archive never fetches
  media from Telegram; exporting or previewing a stored attachment reads S3
  explicitly. **Посмотреть** uses native Quick Look after authenticated
  decryption and retains a private temporary file until the preview closes.
  Cancellation/failure cleans partial files; crash/forced termination cleanup
  and large-media preview performance are not established.
  See [storage and recovery boundaries](object-storage.md).
- Graceful disk-full backpressure is not established: upstream ValueBox uses
  void/assertion IO and commit paths. Capture encoding/sequence failures stop
  rather than truncate, but synthetic tests do not prove physical disk-loss
  recovery. Old binaries sharing this Postbox store lack the journal adaptation.
- No real account or peer-deletion acceptance was performed. Automated tests
  use generated schemas and encrypted temporary Postbox fixtures; UI inspection
  uses visibly synthetic data. See the evidence ledger for exact results.

## Message actions

Each history/search row offers reply, formatted text or supported media-caption edit,
forward and deletion. The source captures account, chat, native peer/namespace/
message ID, thread and a content/version fingerprint. Dispatch reads the current
Postbox message and permissions again; changed or missing sources are rejected.
Server rules remain authoritative. Incoming private-message revoke uses the
account's current limits; basic-group and channel administrator deletion rights
are checked. Own outgoing channel/send-as posts use the selected Postbox's
outgoing flag and current channel rights, since their author may be the channel.
Channel deletion never offers a misleading local-only option.

Reply uses the current chat draft and shows the original author/text. Canceling
reply keeps the text; a local enqueue acknowledgement clears only the exact
submitted revision in its captured account/chat, including protection against
typing A → B → A or changing only formatting, selection or the reply target
while acknowledgement is pending. Exact text, typed entities, scalar-safe UTF16
selection and the optional reply target (peer/namespace/message/thread) share
one revision and transaction in that account's encrypted Postbox,
including a reply-only draft with empty text. The ordinary composer is
restored when opening the dialog after restart. Explicit empty snapshots prevent
late reads from resurrecting cleared text; account/binding/request guards reject
stale results. This uses the engine's local persistent interface preferences,
without server draft synchronization. Schema 3 reads schema-1/2 text drafts with
the caret at the end and upgrades them on the next local change/save; the
envelope marker stays stable.
Stored fingerprints/capabilities are never restored as authority: a cancellable,
account-bound local Postbox lookup supplies fresh source text/author/permissions,
checks thread/migration ownership and has a 30-second deadline. A missing or
deleted cached source keeps the text and target, displays Retry/Cancel, and
blocks ordinary send and attachment selection until it resolves or is explicitly
cancelled. Dispatch still revalidates the resolved source before enqueue.
Switching chats/channels does not lose reply context; editing temporarily hides
the ordinary composer and returns to it when cancelled. Unknown/malformed/future state is retained
and reported, never replaced. Text over 64 KiB UTF8 stays in memory with an error
instead of being truncated on disk. Input admits at most 1,024 entities; decoding
checks the text/entity limits before formatted-range validation. The entire
encoded envelope is bounded to 512 KiB before a write, including URL metadata.
Failed/pending revisions stay dirty; an
explicit retry or account rebind resubmits only the latest snapshot, including
an empty snapshot after enqueue. A completed upstream NoError transaction is
not a guarantee of disk-full diagnosis or survival of abrupt power loss while a
write is pending. Edit has a separate in-process session for each chat in the
current account context. Switching chats or the shared service selector restores
its source, exact text/entities and UTF16 selection. Ordinary input and reply
remain separate. Explicit cancel discards the edit input and returns to that
ordinary input; reopening starts from the source message. A changed source
version uses its own original, without attaching a cached older draft.
Rejection/uncertainty retains the session. An applied acknowledgement closes only
the captured session revision, including while another chat is selected; newer
text, formatting, selection or a replacement session survives. Submission still
revalidates the source against current Postbox. There is no automatic retry.
Reference `ChatInterfaceState` restores edit from AccountContext temporary state
but explicitly decodes `editState = nil` after restart. Makosh likewise keeps
edit sessions in process and clears them when stopping the account context,
while ordinary input/selection/reply is persisted separately. The reference's
normal edit clears on local commitment; Makosh conservatively waits for the
existing action provider's applied event. Neither proves remote delivery.
Reply quotes and topic-aware edit navigation remain open.
Pending attachment caption/file recovery is connected
as described below. The selected dialog is not restored automatically.

Reply and edit use the lower composer with a compact source accessory, following
TelegramSwift. Message actions use the row context menu; attachment choices share
one paperclip menu. Formatting is available for selected text through the native
context menu and keyboard shortcuts, without a persistent formatting toolbar.
See [reference interface mapping](reference-interface.md) for verified source
pointers and remaining visual gaps.

The ordinary and edit composers share the native AppKit text editor. It preserves
UTF16 entity ranges, styles, links and
Telegram-specific metadata. Malformed ranges or unsupported server entity
conversion block editing instead of silently flattening the source. Plain edit
calls cannot erase a rich source. Formatting-only edits are allowed; no-change
comparison includes entities. Telegram's server still decides entity validity.
Formatting replacement and native undo/redo publish storage plus selection as
one coherent value; their callbacks cannot trigger an external reinstall that
erases redo. Chat/account recreation discards that editor's undo history.
Ordinary Return submits, Shift+Return inserts a newline, and marked input is
left to the native text system. Configurable send-key preferences and actual IME
acceptance remain open.

Ordinary messages and replies enqueue typed native text entities, including
format-only changes. Fresh Postbox preflight rejects unresolved or hashless
text mentions instead of letting the API silently discard their entities.
Inline custom emoji remains retained in the DTO but cannot be sent without its
resolved media registry. The ordinary enqueue chain is built outside MainActor;
only its guarded acknowledgement returns to the UI queue. Local fixture/native
simulation checks do not establish live server delivery.

File/photo replies capture the original message and chat before opening the
file picker. The preparation view shows that reply subject and frozen recipient;
the caption may be empty. After copying the prepared file into MediaBox, dispatch
freshly validates the source before enqueueing the exact native reply/thread.
A stale or deleted source rejects the upload; it never becomes an ordinary
message. Closing or switching chats cannot retarget a captured attachment.
Attachment preparation copies the ordinary formatted input and its UTF16
selection into the same owned native rich editor. File/photo captions enqueue
native entities and validate text mentions against current Postbox peers before
reply preflight. Empty/whitespace captions remain valid, without trimming.
The 1,024 UTF16 limit remains; unresolved custom emoji cannot be sent.
Caption callbacks are bound to the current preparation token and ready phase;
send freezes the formatted value. Only an exact captured ordinary draft revision
can clear after acknowledgement, protecting newer formatting/selection/reply.
Following the reference's temporaryInputState workflow, preparation suspends the
ordinary input and reply accessory and transfers the full input/selection into a
modal preview. Cancel/Escape restores the current original-chat draft and reply;
late sheet callbacks cannot cancel a newer preparation. The durable original is
retained as a crash-recovery backup rather than overwritten with an empty draft.
Acceptance of an edited caption clears only that captured original revision;
newer revisions or input changed while the file picker was open survive. An
uncertain enqueue retains the preview until explicit observation close or a late
ACK; closing it never resends. Photo previews decode only the owned normalized
stage with the existing bounded image decoder. Restart recovery now restores the
pending file/photo, edited caption/entities/selection and original draft revision
in the shared window. Prepared reply targets are resolved against current Postbox
before the modal becomes sendable; missing authority leaves a visible retry error.

The recovery storage adapters are connected to the runtime/model/UI. `TelegramPendingUploadFiles` stores the exact owned staged file in
the existing encrypted S3 archive; PostgreSQL contains only authenticated file
metadata. An opaque `pending-upload:<preparation UUID>` draft-resource identity
is separate from received-message observations and is never an engine MessageId.
Photo restore authenticates the archive record and retains the normalized JPEG
bytes without a second encoding, in a new mode-0700/0600 owned stage.
`TelegramPostboxPendingUploadRepository` uses a separate account/chat preference
key for schema-1 caption entities/selection, original draft, reply target, file
reference and prepared/submissionStarted/accepted/cancelled disposition. Atomic
revision compare-and-swap, exact-byte idempotent retries and cancellation
tombstones reject stale writers; unknown/foreign bytes remain untouched. Cancelling
the pointer retains the immutable archived file. Transaction completion is not
an fsync or disk-full guarantee.

`TelegramPendingUploadSession` serializes writes on its captured account repository.
Initial storage must succeed before send. Caption changes are saved; send freezes
and persists the latest full input with `submissionStarted` before calling the
provider with the exact preparation UUID. Recipe 6 adds optional admission/commit
hooks to the native enqueue API, preserving its media transformation and all nil
default callers. The admission hook checks the scoped `submissionStarted` pointer,
preparation, caption/entities, reply target and file metadata before queue creation.
The commit hook writes `.accepted` in that same Postbox transaction. It requires
exactly one existing outgoing Local message in the captured chat, with exact UTF8
caption and native entities. Hook closures are built outside MainActor; UI events
return through `deliverOnMainQueue`. The later storage ACK remains idempotent and
precedes exact original-draft ACK. Storage-only retries never call submit.
After a lost UI callback, restart reads the already persisted receipt. This
proves local queue admission, not server delivery, read status or fsync. An
unexpected nonempty native result/failed receipt leaves an uncertain outcome;
Postbox does not roll back an already added message on that refusal.
Restored `submissionStarted` stays
uncertain, preserves the marker on observation close and never sends automatically;
older uncertain records are not guessed from matching content. The pinned
`PendingMessageManager` correlation-to-sent-ID mapping is process memory, so it
cannot establish an older record's outcome after restart. Live local-to-cloud
reconciliation remains open. Cancellation is ordered
after an in-flight initial write, including failed acknowledgements. Its failure
and storage-only retry remain visible outside a dismissed preview. Rebinding
preserves stored state and rejects stale UI callbacks. Recovery load/error blocks
ordinary send/actions and attachment admission; explicit retry reopens the same
pointer. Unknown/foreign schemas are preserved.

Native synthetic acceptance verified file and normalized-photo restart recovery,
rich caption/selection, cancellation/original restoration, accepted ACK restart
and the shared channel selector. An explicit DEBUG-only
`--telegram-pending-upload-ack-loss-qa` additionally drops the UI acceptance event
after a synthetic StoreMessage and receipt commit. Actual native acceptance used
the same owned Postbox: uncertain modal without Send, process stop/relaunch,
no recovered resend modal and exact original draft cleared; a newer draft then
survived a second restart and the Mail → Telegram switch. This fixture uses the
receipt helper and a synthetic queue, not an Account or server send. Cancellation/
acceptance faults also have regression coverage. Live account, power-loss and
disk-failure acceptance remain unverified. QA requires explicit synthetic Postbox, isolated
PostgreSQL configuration and S3 configuration; it never opens personal sessions.

### Send-key preference

Native Settings exposes the reference's two exclusive choices: send with Enter
or Command-Enter. `Makosh.Telegram.SendKey` is an application preference, separate
from Telegram accounts and Postbox drafts. Missing/unknown values read as Enter
without replacing stored data. The same editor preference drives ordinary/reply
send, inline edit and attachment-caption submit; each caller retains its existing
readiness, context and formatting guards. No window-wide default-send shortcut
is installed.

Return and keypad Enter use physical key codes. In Enter mode, device-independent
flags must be empty, Caps Lock alone or numericPad alone. In Command-Enter mode,
Command may be combined with other modifiers, matching the inspected reference.
Marked text never invokes the submit callback; the native text system handles
composition. Rejected Command/Shift Return inserts a newline in submit-enabled
editors. Other rejected events and editors without a submit callback keep native
text behavior. Modifier/fallback/persistence regressions do not establish actual
IME input-source or server-send acceptance.

Native synthetic acceptance additionally verified both Settings choices, their
application to an already open editor and persistence after process stop/relaunch.
Command-Enter submits reply/edit/caption; main Return and keypad Enter submit a
reply in Enter mode. Rejected Command/Shift Return creates a newline, which native
undo removes. The new draft survives the shared Mail → Telegram switch. The QA
bundle's unsigned executable matches the built app and passes strict signatures;
only explicitly isolated Postbox/PostgreSQL/S3 and synthetic actions were used.

### Forward and delete

Forward requires explicit selection among loaded dialogs in the same account;
the confirmation shows the recipient. Deletion requires choosing local-only or
everyone, where available, and explicitly says previously retained versions and
S3 copies remain. All engine mutations continue through the central Postbox
retention journal. No archive-delete operation is introduced.

Reply, forward and delete acknowledgement means local queue acceptance, not
server delivery/recall. Edit reports applied only after the engine response;
its ambiguous no-change response is reconciled against exact current text and
entities.
After a post-commit timeout/error the result is uncertain: text remains and
automatic repeat is disabled. Stopping observation cannot undo a queued action.
Fresh preflight and mutation are separate engine transactions; a concurrent
server change after preflight remains subject to Telegram's server rules.

This is a message-action slice, not complete Telegram migration. Destination
topic selection, secret-chat actions,
paid-content forwarding and premium caption limits remain unfinished. Plain
text currently allows 4096 UTF16 units; supported captions allow 1024. Protected,
paid and service-action messages are not forwarded. Replies/deletion do not
depend on the media renderer's supported types. No real account action was run.

## Formatted message reading

History and search render captured UTF16 entities without changing the original
message: combined bold/italic, underline/strike and fixed-pitch code/pre. Quote
paragraph attributes are prepared; full Telegram quote/code chrome, folding,
language headers, inline code-copy and custom emoji rendering are unfinished.
SwiftUI paragraph-layout parity has not been visually established. Unknown
entities retain their original text. Invalid entities or an exact UTF8 mismatch
between message and metadata produce an unavailable label rather than a plain
fallback that could reveal a spoiler.

Spoilers initially display UTF16-length masks. Presentation, AX and selection
copy contain the mask; source data remains intact. A reveal is tied to account/
chat/message context and the exact formatted version before rendering, so a
later edit cannot inherit the earlier reveal. The same masking is used for chat
list previews and action/reply/upload source summaries. Explicit editing still
loads the original content. The separate retained archive does not yet store
entities and is outside this reading-presentation boundary.

Validated HTTP(S) and simple mailto links are active; schemeless domain paths
are normalized to HTTPS. Credential-bearing URLs, unsupported schemes, controls,
format characters and whitespace are not activated. Telegram deep links,
mentions and commands currently stay text. If a TextUrl label differs from its
target, confirmation shows the actual URL. Links intersecting hidden spoilers
carry no source target until reveal. Accessible reveal/link actions use the same
activation path. These are native reading controls, without a browser renderer
or remote preview fetch. The synthetic QA exercised confirmation and Cancel;
opening an external application was deliberately not tested.

## Code and quote reading blocks

The history follows the verified TelegramSwift code header/copy and quote
folding behavior using independently written SwiftUI/AppKit. Quotes marked
collapsible fold to two lines only when their measured text exceeds three
visual lines. Expansion is tied to the exact captured message and account/chat
context. Search keeps its compact four-line rich-text summary.

Block projection preserves original UTF16 ranges and exact text bytes,
including whitespace and line breaks. Nested styles/spoilers are rebased;
ambiguous structural entities or semantic links spanning blocks retain a single
original rich-text view. No split can restore a link target hidden elsewhere.
Code copying uses the currently masked/revealed text and preserves whitespace;
language hints are bounded, reject controls/format characters and stay hidden
while the code has an unrevealed spoiler. Syntax highlighting, inline-code
click-to-copy and continuous selection across multiple blocks remain open.

Copy permission is separate from forwarding and defaults to unavailable when
unspecified. Engine mapping checks message, channel and group protection.
Current history/search text selection, code copy and action-sheet source
selection respect that capability. This is a live reader boundary; the separate
historical archive does not yet store entities/copy capabilities.

History uses eager layout for the engine's bounded 50-message window. Native
QA exposed incorrect lazy row reachability and a SwiftUI lazy Accessibility
scroll trap. The eager layout restored Search → In History reachability and
ordinary accessibility scrolling; heavy-media performance and the broader OS
matrix remain unmeasured. See the status ledger for actual checks and failures.

## Peer profile and explicit dossier linking

Click the conversation header to open the selected peer's profile, following
TelegramSwift's title-bar entry and profile/phone/username ordering. The card
supports people, bots, basic groups, supergroups and channels. Available native
cached descriptions and participant/subscriber counts are shown; an unknown
count remains unavailable rather than becoming zero. Native scam/fake flags
are displayed and suppress the description, following the reference.

Opening the card subscribes to the selected account's native
`viewTracker.peerView(updateData: true)`: cached observations arrive immediately
and the engine can refresh the peer data. The timestamp describes a local cache
observation, not an acknowledged server fetch. No contact-list scan or system
Contacts access is performed. Groups, channels and bots cannot be linked to a
person dossier; a person without a name can be viewed but not linked yet.
Secret-chat profiles and animated video avatars remain open. Member lists,
administration and shared media are described below. The static
profile-photo gallery below is available from the card's avatar.

The profile offers explicit creation of a new dossier or selection of an existing
PostgreSQL contact. Existing-source ownership opens that dossier or permits an
explicit refresh. Identity uses the exact `(telegram, accountID, native peerID)`
tuple; username remains display data because the current dossier schema has no
username field. Name and available phone observations retain the source and
cache-read time. Manual fields, notes and source history survive attachment.
The operation never silently merges contacts or moves an identity owned by
another contact. The database checks ownership and target existence atomically
under its row lock, including concurrent app instances. Duplicate snapshots are
idempotent; older snapshots cannot replace newer source data. New observations
and attachments advance revisions so stale merge undo stops.

Profile observations have account/chat/request guards and a 30-second deadline
for the first value. Later native peer/cache updates retain the same guarded
request. Closing the card, changing the chat, hiding Telegram through the service
selector or stopping the account disposes observation; this does not guarantee
cancellation of an already issued engine RPC. Only the immutable Sendable DTO
crosses to MainActor. The current snapshot and person kind are checked again
immediately before a dossier write. A real encrypted synthetic Postbox regression
observes initial and changed peer/description values; it does not exercise a real
Account/ViewTracker RPC. A known committed write disables repeat linking even
if refreshing the workspace fails afterwards.

The DEBUG-only `--telegram-dossier-synthetic-preview` branch exercises the real
workspace/profile controls with in-memory Telegram fixtures and PostgreSQL.
It requires an explicit `--database-config PATH` whose schema starts with
`qa_telegram_dossier_`; it refuses the ordinary configuration fallback. Create
that configuration privately from your local database settings with a fresh
isolated schema. No API settings, Keychain, real account/session, Telegram
network, real sending or normal archive configuration are opened in this branch.
Release builds exclude it. Native create/link/persistence checks passed;
opening the full dossier still has the UI-automation limitation recorded in
`development-status.md` and is not claimed accepted.

The DEBUG-only `--telegram-peer-profiles-synthetic-preview` flag uses that same
workspace and explicit isolated database contract. Dialogs 1–7 cover a person,
group, channel, supergroup, bot, unknown-count scam channel and zero-count fake
supergroup. These are in-memory fixtures, not server-refresh acceptance.

### Group/channel administration and shared media (block 4)

The profile contains member/admin directories, restrictions/removals, title and
description editors, group default permissions and shared media. Native roles,
membership, migration, access hashes and available cached data determine which
actions appear. Missing/inaccessible/monoforum peers fail closed. Lists use
native64-member pages and raw server offsets; basic groups use their complete
cached participant list. Administrator name filtering is local over fetched
pages, so more pages may be required for a match. Empty results are distinguished
from failed or timed-out requests.

Immutable account/peer/context/request tokens reject late reads and stale UI
actions. Writes re-read actor rights and cached peer data in Postbox after a
fresh channel-participant lookup, comparing the exact selected participant.
No UI snapshot alone authorizes a write. Granted rights cannot exceed the
actor's rights; self/owner edits and implicit administrator demotion through
restriction are prohibited. Basic groups use boolean admin rights and removal
without history revocation. Default permissions compare their old value and
cannot ban everyone from reading. The server is the final authority for edits
concurrent with admission; this is not a distributed CAS guarantee.

Title/about limits are255 UTF16 and rank16. Title and about save separately,
so partial success cannot appear as an atomic combined save. Explicit member
and default-permission confirmation freezes the submitted change. Finite bans
are limited to60seconds through365days and revalidated at native admission;
only an explicit permanent choice uses Int32.max. This margin avoids the
[Telegram forever conversion](https://core.telegram.org/constructor/chatBannedRights)
for dates outside the server's finite window. Expired custom dates must be
selected again. Native legacy aggregate ban bits are not sent; nonzero admin
rights include the pinned engine's required other bit, while demotion clears it.

RPCs use the pinned TelegramApi with automatic flood waiting disabled. A
30-second outer deadline bounds each read/write.4xx rejections are definite;
transport/server uncertainty, timeout or closing during a write requires an
explicit refresh before another write. Requests are never automatically
resent. Refresh shows the current available observations; it cannot prove that
a still-running server operation did not execute. The uncertainty ledger lasts
for the controller lifetime and is not a durable outbox. A confirmed basic-group
admin Bool updates cached membership only while its exact old basis matches;
Updates ACKs replay through recipe19's unchanged public wrapper. Cache refresh
is requested after Updates/basic-admin ACKs, without claiming synchronous
server-refresh completion.

Shared media has independent query, media filter, pagination and source leases;
it does not replace conversation or global search. All-chat native search can
open the exact source thread/index. Closing or changing accounts clears results
and cancels stale activations. Photo/video viewing uses the existing bounded
decoder, file borrowing and playback; spoilers require explicit reveal. Save
uses the existing native panel. Gallery downloads inherit the existing per-chat
S3 policy: OFF prohibits every new S3 copy, and no PostgreSQL byte storage or
archive deletion path is added.

GIF results use the existing file rows and their supported preview/playback
actions. Files without a supported visual decoder are not put in an indefinitely
loading photo tile. Animated-GIF grid/player parity remains open.

The DEBUG-only peer-appearance preview uses the existing explicit isolated
`qa_telegram_dossier_` database contract and synthetic administration fixtures.
Native UI QA exercises confirmation, role/rank refresh, default permissions,
information editing, media tabs and photo→video→source-message navigation.
Real account/network/admin acceptance remains block6. Invites/member addition,
join requests, admin logs, ownership, statistics, avatar editing/stories and
full reference-gallery parity remain open in `reference-interface.md`.

## Peer avatars and cached status

Visible dialog rows, the conversation header and the peer card observe the
selected account's native peer view with `updateData: false` for static profile
photos. The provider selects native small/large representations and uses an
avatar reference, peer location and avatar content category. Missing access
hashes permit a cache-only attempt; no standalone network fallback is invented.
An absent, unsupported, failed or invalid image leaves the existing initials.

Photo replacement disposes the previous resource observation/fetch. Pending
fetches have a 30-second bound; native cache leases remain until resource change
or view cancellation after completion. Forced cache purge can still interrupt
decoding and falls back safely. Only opaque resource digests and complete-file
events cross to main delivery; native protocol references stay in the provider.
The shared avatar store invalidates account contexts and limits active observers
to 128. Its worker accepts regular files without following a final symlink,
at most 2 MiB, 4096 pixels per dimension and 16 million pixels; thumbnails are
bounded to 128/512 pixels. The generic attachment preview keeps its prior limits.
These transient profile photos use the account's MediaBox cache; no image bytes
are written to PostgreSQL or dossiers. Retained message attachments still use S3.

The header and person card show cached native presence rather than connection
state. Server clock offset is added when comparing native Unix expiry/activity
times; it is subtracted for device-clock timer deadlines. Absolute last-seen
dates preserve the original Unix timestamp. Online expiry, relative minute/hour
boundaries, calendar midnight and year changes refresh without a new peer event.
Older presence shows hours in the same day, yesterday with its native local
time, then day/month (including the year for past years). Gregorian calendar
boundaries use the selected timezone and handle 23/25-hour DST days.
Privacy buckets remain approximate,
missing presence is explicitly unavailable, and Saved Messages hides presence.
Bot/support/service and group/channel counts have separate presentation.
Leaving Telegram or changing account/chat cancels the selected-peer subscription
and the view's timer. The clock offset is refreshed on peer emissions, with no
separate clock-change subscription. Actual account/network behavior remains
unaccepted; this is a cache observation, not a live-availability guarantee.

Chat-list online badges have their own reference policy. Native list entries
already carry reactive presence, so normal rows add no per-peer subscriptions.
Search owns one combined cached Postbox presence view for its current result
set; replacing the query/folder/account disposes it. An associated peer supplies
presence while the DTO retains the original account/chat identity. The list
excludes self and the exact CloudUser 777000 service identity; it does not inherit
the header's separate bot/support/phone-number exclusions. Missing, none, last-week
and last-month observations have no badge. Present/recently timestamps use the
reference's inclusive integer-second boundary and truncated server offset, with
overflow-safe arithmetic. Recently activity lasts 30 seconds.

Own SwiftUI circles reproduce the 12-point outer/8-point inner badge at the
avatar's bottom-right, inset 3 points horizontally, with a selected variant.
Visible rows own cancellable expiry tasks; system clock changes, wake and scene
activation restart the device-clock calculation. Server offset is sampled on
native emissions; a server-offset change without an emission is not separately
observed. Actual clock/wake and live account/network acceptance remain open.
Exact custom themes and badge transitions are not claimed. No third-party
UI/assets or additional dependency is copied.

The DEBUG-only `--telegram-peer-appearance-synthetic-preview` uses the same
explicit isolated database contract and shared workspace. Dialog 1 has a generated
photo/online status, 2 no photo, 3 corrupt bytes, 8 a four-second online expiry,
9 approximate recently, 10 missing presence, 11 a self peer, 12 two hours ago
and 13 the previous calendar day. Dialog 12 follows the calendar and can show
yesterday near midnight. Gallery fixtures provide three photos with a reported
total of five; the second marks a static video-avatar frame and the third fails
decoding on its first attempt, then recovers on retry. Dialog 2 has an empty
gallery. The strip uses actual generated thumbnail pixels and independent leases.
Generated photos are temporary private fixture files; no personal
account, Keychain or Telegram network is opened. List badges use a fixed observation
time for the fixture session: dialogs 8/9 expire after 30 seconds without list
updates, while 1 stays online and group/bot/missing/self fixtures have no badge.
Header dialog 8 retains its independent four-second fixture. Animated avatars
remain open.

## Static profile-photo gallery

Click the peer-card avatar to open its static gallery. Native user/group/channel
photo metadata is mapped before main delivery; cached personal/photo data takes
precedence, with the current large avatar as a fallback when the list is empty.
Historical images retain an avatar-list reference for native revalidation.
Missing peer access hashes allow cache-only image access. The engine's first
request is bounded to 100 user photos or 1000 group/channel photo messages;
the adapter does not invent pagination. A total larger than the available list
is displayed explicitly. Empty results can also represent a caught RPC failure,
so the UI offers retry without claiming that the peer has no photos.

The gallery uses a borderless window sized to the parent screen, with a black
0.9 background, safe top inset and 95-point footer. SwiftUI owns presentation
requests and gallery state; a narrow AppKit coordinator owns only the child
window, dismissal and focus restoration. Parent close, idle/context changes and
request replacement dismiss the owned window and cancel its work. A finite
hosting-root frame prevents intrinsic content size from shrinking the window.
The peer name, static image, available date, position and previous/next controls
remain visible. A lazy 400×80 strip displays independently fetched native small
representations; selection resets zoom, rotation and pan. At most 32 thumbnail
leases/decodes are active, each with a 30-second deadline, 2 MiB/4096-per-dimension/
16 MP admission and a 128-pixel decoded preview. Late/released/context-stale
events cannot restore old thumbnails. These limits do not cap network bytes.

Zoom is clamped to 0.25–8, with 0.5 steps, pinch and bounded drag pan. Arrow keys,
minus/equal, Cmd-R rotation, Cmd-S Save, Escape/Space and Cmd-W are scoped to the
key gallery window. Apple SDK virtual-key constants preserve commands across
input layouts; an attached native Save panel receives its own keyboard events.
Video avatars are
labelled as static frames. List and selected-image loads have 30-second deadlines
and separate retries. One selected resource lease keeps its cache file available
through decoding/display; switching, closing, changing the peer or rebinding
the account cancels the lease/session and rejects stale callbacks. Synchronous
cache/fixture list delivery is supported before the provider returns its session.
Native protocol objects remain private to that session; UI receives immutable
DTOs and complete-file events.

The existing generic image admission accepts at most 20 MiB, 8192 pixels per
dimension and 40 million pixels, with a 1280-pixel thumbnail. These are decoder
limits, not a native network-byte cap. Gallery images remain transient MediaBox
cache, separate from encrypted S3 retention of received message attachments;
PostgreSQL does not receive photo bytes. Save exports the original downloaded
representation, not the transformed/resized preview. ImageIO determines its
extension; SHA256 of the decoded source is checked during the streaming atomic
copy, so same-size cache mutation cannot silently export different bytes.
The existing regular-file/no-symlink/private-temp/cancellation guards apply.
Navigation/transforms are blocked while choosing/copying; closing cancels owned
panel/copy work. Cancellation after the atomic rename cannot undo a committed
export. Profile sharing is omitted consistently with reference nil chatMode.
Avatar transition, exact theme/hover/thumbnail animations, the additional F
mode, extra public fallback images, stories and animated video playback remain
open. Pinch, display reconfiguration and native pending-fetch deadlines have not
received runtime acceptance. Real account/network fetch, pagination beyond the
native first page and native pending-fetch timeout acceptance are unverified.

## Offline navigation UI check

Persistent composer QA uses the shared workspace, a separately created mode-0700
Postbox directory named `qa_telegram_drafts_…`, and an explicit mode-0600 database
configuration whose schema starts with `qa_telegram_dossier_`:

```sh
.build/Makosh.app/Contents/MacOS/Makosh --telegram-drafts-synthetic-preview /path/to/qa_telegram_drafts_example --database-config /path/to/isolated-database.json
```

Reusing that owned synthetic directory after quitting exercises actual restart
persistence. Only that synthetic Postbox and isolated PostgreSQL schema are
opened. No personal account, API file, Keychain, Telegram network or real send is
used. Reply resolution uses fixed synthetic messages; native Postbox resolution
has separate encrypted-cache tests. The fixed history does not change after a
labelled simulated queue acknowledgement.

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

Message actions also use an explicit DEBUG simulation. It exercises menus,
reply context, separate edit drafts, recipient/scope selection and labelled
outcomes without mutating an engine queue or changing the fixed synthetic
history. It does not prove a Telegram server operation.

The same preview includes an explicitly synthetic in-memory local archive with
an original, an edit and a source-cache removal marker. It exercises the actual
native archive viewer, refresh and dismissal without opening the user's archive.

## Forward composer and local queue receipt

The context-menu picker now stages a forward in the chosen recipient's ordinary
composer and navigates within the shared workspace. It preserves that recipient's
rich comment/selection and reply, independently of the source chat's draft. A
compact accessory offers author/caption options and another recipient; cancellation
removes only the forward. Changing recipient retains the original comment/reply
in its chat. The new destination's persisted draft loads before staging.

Own schema 4 reads legacy 1/2/3 and stores bounded typed source IDs, exact source
fingerprints, options and prepared/submissionStarted/accepted disposition with
the ordinary input/reply. Unknown payloads remain untouched. Ordinary saves are
not general Postbox CAS; transaction helpers compare the full captured draft for
forward begin/accept/reset/consume and refuse stale saves over an in-flight record.
Prepared input/selection/options changes get a new revision. In-flight input and
attachment admission are blocked to keep the frozen submission unambiguous.

Before enqueue, every source and destination is resolved from current Postbox.
The optional rich comment (with its separate reply) precedes the native forward
batch in one enqueue invocation. The final transaction admission checks all
sources, fingerprints, protection, destination permissions and comment mentions
again. Missing sources cannot silently produce a comment-only operation. Multiple
source grouping uses native auto; hidden captions also hide author attribution.
A receipt requires the full unique outgoing Local batch in the captured destination
and is written in that queue transaction. Only accepted consumption clears the
captured input/reply/forward. A proven zero-queue refusal returns to prepared; an
ambiguous/partial result remains uncertain without automatic resend. Restart can
consume an accepted receipt without enqueue. This proves local admission, not
server delivery, remote permission freshness, fsync or power-loss survival.

Reference evidence: ShareModalController.swift:1296-1359; ChatInputAccessory.swift:
227-302; ChatInterfaceState.swift:1172-1180,1304-1320; SenderController.swift:492-523.
No outer GPLv2 serializer/UI was copied. Makosh's atomic batch/receipt is an owned
adaptation; the reference chains comment and forward separately. The initial history/selection picker's Saved Messages branch is described below.
Saved Messages accessory re-targeting is described below. Remaining selection
actions, topics, paid/secret-chat forwarding and live-account
acceptance remain open. A new attachment cannot be
combined with a staged forward yet; its attach button is disabled explicitly.

## History message selection

The history context menu's **Выбрать** enters an in-process selection mode. A
compact delete/count/forward panel with Cancel/Escape replaces the composer without modifying its
ordinary input/reply or active edit. Row clicks toggle typed native identities;
up to 100 frozen sources are ordered by native MessageId, matching the reference's
sorted-then-reversed enqueue order. Protected messages can be selected, but any
non-forwardable or visibly changed source blocks the complete forward batch.
The recipient picker captures the selection revision and refuses stale snapshots.
An ordinary recipient stages its existing composer. Explicitly choosing Saved
Messages submits immediately through the separate operation described below.

Pagination does not prune off-page selection, and the shared model retains it
across service switches. Explicit Cancel/Escape, search opening, actual chat
change or account stop clear it; restart does not persist selection. Clearing on
chat change is Makosh's bounded lifecycle adaptation: the reference's selection
belongs to a chat controller, whose disappearance alone does not clear it.
Selection accessibility labels use the same default spoiler mask as the reader;
unavailable formatting never falls back to raw source text.

Shift-click first toggles the endpoint, then adds cached IDs in the half-open
numeric range between that endpoint and the previous anchor. Candidates are
added in descending numeric order, Cloud before Local for the same number, until
the selection reaches 100. Existing sources and the clicked endpoint survive a
partial fill. Shift-deselect removes only that endpoint and leaves the anchor.
The reference's arbitrary greater selected anchor on an ordinary deselect is
adapted to the deterministic minimum native greater ID. Initial Shift-Select
has no anchor. Local candidates remain selectable/deselectable but disable the
whole forward batch; protected candidates are not silently omitted.

The provider reads only the account's cached Postbox ID index through the
recipe-7 API: at most 200 Cloud and 200 Local candidates, then at most 200 merged
sources. No network history or iteration over missing integers is involved.
Selection session/revision, account context and captured history window must
still match on completion. New clicks, pagination, chat/account changes or
explicit cancellation dispose the pending lookup. A 30-second failure preserves
the endpoint and earlier selection with a visible error. Forward is blocked
until the range finishes. A freshly observed changed off-page source invalidates
its frozen version instead of replacing it. Synchronous callbacks are supported.

Reference evidence: ChatMessageMenuItems.swift:1005-1011; ChatPresentationInterfaceState.swift:
1684-1694,1702-1718; ChatController.swift:9753-9788; ChatInputView.swift:638-658;
MessageActionsPanelView.swift:61-118; SenderController.swift:492-523;
ChatController.swift:6531-6577; ChatPresentationInterfaceState.swift:1684-1738.
No GPLv2 UI source was copied. Scheduled/topic/migrated-peer range parity,
album individual/group selection and Saved Messages behavior are described
below; remaining option/special-case parity stays open. Cross-native-peer numeric ranges are
refused instead of mixing unrelated message IDs.

### Selected-message copy and delete

Command-C follows the reference copy workflow through a SwiftUI scene command;
the panel has no new Copy button. The command exists only for an eligible
selection in the visible Telegram conversation. Native text responders retain
their standard Copy behavior; confirmation/profile/preview sheets suppress the
selection command. One cached Postbox transaction loads the entire set in native
MessageId order, rechecking account/chat, migrated-peer relationship, exact UTF8
fingerprints, thread and current copy protection. Missing or changed items refuse
the complete copy. Plain text includes the effective/forward author, double-newline
separators, spoiler and incoming service-code masks, and typed media summaries.
Malformed formatting has a safe unavailable label. No clipboard write occurs
until the original selection/session/revision/context is still current. There
is a 30-second deadline; cancellation or late callbacks preserve the clipboard.

The delete panel opens explicit local/everyone confirmation for the whole
selection. Each action has an independent sticky permission invalidation;
copy/forward protection does not prohibit an otherwise permitted delete.
Saved Messages never offers everyone deletion. The bound account revalidates
all sources and fresh limits/peer permissions inside the same native Postbox
transaction that queues and removes the exact selected Cloud IDs. Unselected
album members remain intact. The existing retention journal captures the prior
snapshot; this operation never deletes PostgreSQL archive records or S3 objects.

Queue acceptance clears only the captured selection revision and any exact
captured edit of its deleted source; ordinary drafts/replies and newer selections
survive. Cancellation/timeout after dispatch is uncertain and blocks further
submissions until an explicit account reconnection; no automatic retry occurs.
True means local queue completion, not server deletion, fsync or power-loss proof.
The DEBUG preview labels its operation as simulation and does not mutate a live
Account. Native cache/journal behavior is tested separately with encrypted Postbox.

Reference evidence: MessageActionsPanelView.swift:60-64,112-118,140-145;
ChatSelectText.swift:110-140; TextUtils.swift:27-180;
ChatController.swift:4411-4490,9753-9776. Own SwiftUI/AppKit code is used;
the outer GPLv2 UI/serializer is not copied. Specialized admin moderation,
scheduled/topics/secret/paid actions, exhaustive media localization/music metadata
and live-account acceptance remain open.

## Initial picker forwarding to Saved Messages

Telegram remains in the shared service-selector/list/conversation window. The
initial history-message and selection recipient picker pins **Избранное** first.
Clicking that row immediately forwards the frozen source batch without navigating
away or staging/consuming the ordinary Saved Messages composer. Ordinary recipient
rows retain recipient-composer staging. The captured account/context and selection
revision guard both submission and clearing; a later chat, selection, input or
reply is preserved. Protected or changed sources refuse the whole batch.

An owned schema-1 record uses the account-scoped Postbox preference key
`Makosh.SavedForward.Preference.v1` and marker `Makosh.SavedForward.JSON.v1`. It is
separate from ordinary input/reply/forward and pending-upload keys. Encoded records
are bounded to 512 KiB; unknown/malformed bytes remain untouched and block this
operation. A durable started intent precedes enqueue. Fresh full-batch native
admission rechecks exact sources and permissions after asynchronous media work;
the existing enqueue adaptation writes a full unique outgoing Local receipt in
the same Postbox transaction as the queue. No unselected album member is added.
Only a proven zero-queue refusal clears the exact started intent. Cancellation,
timeout, partial admission or missing acknowledgement remain uncertain; UI
cancellation does not abort durable completion, and no automatic resend occurs.
Restart reads accepted/started state without enqueue. An accepted record may be
replaced only by a new explicit operation ID. Started/unknown records block Saved
forwarding until reconciliation; ordinary recipient staging remains available.
Local acceptance is not confirmation of Telegram server delivery or power-loss
durability. Archive PostgreSQL records and encrypted S3 objects are unaffected.

Postbox signal builders are nonisolated; callbacks return explicitly to MainActor.
Regression reproduction exposed inherited MainActor transaction closures, then
verified recovery from an owned encrypted Postbox after the boundary fix. DEBUG
Saved forwarding is an explicit offline StoreMessage/receipt simulation, not a
live Account enqueue: logical fixture account -1 uses valid native destination
10000 in its isolated Postbox. A lost-acknowledgement regression counts actual
queue history and confirms one message, unchanged ordinary bytes and no duplicate
submission; separate native admission/receipt regressions use positive peer IDs
and genuinely reopen the encrypted Postbox.

Reference evidence: `ShareModalController.swift:1232–1234` explicitly limits this
forward object to one recipient; `1296–1314` directly forwards to
the own peer and clears selection; `1315–1335` stages an ordinary recipient. Its
delayed success animation does not establish server delivery. No outer GPLv2 UI
source or assets were copied. Album selection is described below. Remaining parity includes
special/topic/secret/paid behavior and
live-account acceptance. The whole Telegram/sequential migration remains open.

## Re-targeting a staged forward to Saved Messages

The accessory's **Другой получатель…** picker now also pins **Избранное** first.
One explicit full-row click queues only its captured forward sources, without
navigating away or sending the old recipient's comment/reply. The origin keeps
its rich input, UTF16 selection and reply. This fresh forwarding operation uses
default visible author/caption options, matching the reference own-peer call;
ordinary re-targeting retains the existing options and is not claimed to have
exhaustive option parity. Ordinary recipients still open a prepared composer.

The picker freezes account context, chat, draft revision and forward intent.
Optional origin metadata extends schema 1 without duplicating the comment or
sources; literal originless schema-1 receipts still decode. Native admission
requires the exact prepared origin revision/intent/sources. The complete Local
queue receipt and removal of only that origin's forward are encoded before
either preference write and committed in the enqueue transaction. Unknown bytes,
stale origins and invalid receipts cannot consume the origin. Account/context
guards also prevent late UI callbacks from clearing another chat's input.

An unknown outcome locks the captured origin's forward, Send and input while
ordinary input in another chat remains available. If recovery cannot identify
the operation, prepared forwards stay locked until reconciliation. Recovery of
an accepted receipt reads the already-cleared durable origin without enqueue.
Cancellation of the picker before dispatch retains the prepared origin. This
is a deliberate adaptation: the reference clears its prior forward IDs after a
short delay when opening the fresh picker; Makosh clears them at acceptance.
Archive PostgreSQL records and S3 objects remain unchanged.

Reference evidence: `ChatInputAccessory.swift:227–242` creates a fresh
`ForwardMessagesObject`; `ShareModalController.swift:1296–1335` separates the
own-peer operation from ordinary composer staging; `SenderController.swift:492`
defaults author/caption hiding to false; `ChatInterfaceState.swift:1397–1398`
removes forward IDs while retaining input/reply. Native synthetic AX/screenshots
verify cancellation, full-row Saved forwarding, ordinary re-targeting, unknown
outcome locks, Mail → Telegram state and accepted-receipt restart. Encrypted
Postbox regressions establish queue/receipt/origin atomicity and genuine reopen;
DEBUG UI simulation is not live Telegram server acceptance. Album selection
is described below; normal option and special/topic/secret/paid behavior, remaining Telegram parity and all
later channels remain open.

Accepted Saved recovery also reconciles the matching cached origin before the
controller releases its validating lock. The current provider binding validates
the account; the operation's old context is not reused as the new session guard.
Exact origin revision/intent/sources are required, including for an offscreen
chat. This clears only the memory forward, without saving or enqueueing: the
accepted queue transaction already wrote the durable removal. Same-model rebind
regressions verify preserved input/reply, unchanged durable snapshot, zero
recovery writes/submissions and protection of a newer origin revision. Process
restart alone did not establish this lifecycle behavior.

The generic ShareModal API accepts an optional comment, but the selected
ForwardMessagesObject picker does not expose that field. Its multipleSelection
is false (`ShareModalController.swift:1232–1234`), passed into presentation at
`2015–2027`; notify hides the caption at `1611`, whose setter hides the text
container at `239–244`. The forward comment is entered in the chosen recipient's
composer. Earlier documents listed picker comments as missing forward parity;
this source check corrects that interpretation rather than adding a new picker UI.

## Album history and selection

Telegram stays in the shared WorkspaceView with the service sidebar, chat list
and conversation/dossier. Native `Message.groupInfo.stableId` supplies the UI
album identity; `groupingKey` is retained separately and does not substitute for
it. Projection scopes account/chat/native peer/namespace/thread, retains input
member order and places the grouped row at its last member. Ordinary intervening
rows do not flush the group; a different eligible UI group does. Unsupported,
secret and single-member rows keep the ordinary path. Only the loaded history
window participates: no hidden album-member fetch or backend expansion occurs.

Visual groups use an independently implemented SwiftUI mosaic with a four-point
gutter, bounded dimensions and explicit image/video loading. Common two-, three-
and four-member layouts and longer malformed inputs have geometry regressions;
exhaustive pixel parity is not claimed. Files retain per-member attachment cards
and captions. Visual albums show the first nonempty caption, matching the
reference; all original member text, metadata and IDs remain in the model.
Thumbnail decoding borrows the downloaded file lease, checks current context/
resource state and limits its output to 512 px under the existing image caps.
A ready photo exposes an explicit accessible Button. Media-spoiler attributes
survive native mapping; visual tiles require a separate Reveal before preview
or playback. Context/descriptor changes hide them again. Ordinary photo/video
rows are described below; the complete upstream media renderer remains open.

Tile click/context actions use exactly that member. In selection mode the
outer whitespace, author and caption toggle the visible group; metadata also
starts group selection. A partially selected group adds missing valid members;
a full group removes exactly its members. Existing frozen entries, sticky
permission/version invalidation and the 100 limit survive. Partial fill at the
cap and removal at the cap are supported. Shift uses the first newly added
member in input order as a deterministic endpoint, adapting the reference's
unordered Set.first. Group actions require the exact captured session/revision,
account context, current window and reprojected membership; stale callbacks
cannot select a different group. Forward/copy/delete consume only selected IDs.

Reference evidence: ChatHistoryEntry.swift:1184–1212,1294–1307;
GroupedLayout.swift:52–59; ChatGroupedItem.swift:43–52,625–652,753–783,901–916;
ChatSelectText.swift:349–370;
ChatRowView.swift:371–381; CoreExtension.swift:565–571;
ChatInteractiveContentView.swift:481–486,853–863. No outer GPLv2 source/assets
were copied. Pins, engine recipe 8, PostgreSQL schema and S3 format are unchanged.

`--telegram-albums-qa` is an explicit DEBUG addition to the owned synthetic
Postbox workflow, leaving the default fixture unchanged. Its forward/Saved,
copy/range/reply resolvers now receive the same page configuration as history.
Regressions reproduce the initial mismatched fixture versions before fixing
those bindings. The native DEBUG queue remains a simulation; it does not prove
live Telegram Account/server acceptance. Actual root checks and remaining
limitations are recorded in development-status.

## Ordinary forward author and caption options

The accessory menu follows ChatInputAccessory.swift:244–294: checked Show/Hide
author choices count distinct nonnil native author IDs; caption choices count
resolved captioned messages and are absent when none exist. A typed action freezes
the account context, chat, intent ID and draft revision. Stale menus and locked
uncertain composers cannot overwrite newer state. Choosing an author option,
including the already checked Show item, records an explicit preference. Until
that choice, hiding/showing captions also hides/shows author names. After it,
caption changes preserve the author preference.

Schema 4 adds optional `explicitHideNames` to the existing forward intent, without
changing its ID or source versions. Missing legacy fields decode as nil and keep
their stored flags; malformed field types and explicit/active flag disagreement
are refused. The preference survives ordinary recipient changes and persistent
draft reload. Saved re-targeting intentionally creates fresh default options,
as in the previously verified reference exception. Input, UTF16 selection and
reply remain independent of option changes.

Reference ChatInterfaceState.swift:1178–1179,1310–1318,1348 persists the two flags
but resets `tempSenderName` when decoding. Persisting Makosh's explicit preference
is an intentional adaptation rather than identical upstream restart behavior.
The accessory title reflects `hideNames`; outgoing native options still use
`hideNames || hideCaptions` (SenderController.swift:504–505). Thus choosing Show
author while hiding captions preserves the UI preference for later changes;
native transport still suppresses author attribution while captions are hidden.

Model/JSON regressions cover coupling, both explicit preferences, stale revisions,
wrong scopes, locked recovery, legacy/malformed fields and ordinary re-targeting.
An encrypted Postbox transaction verifies native preview author identity. Root
native checks cover a fresh already-checked Show selection, caption cycling,
actual process restart, recipient Cancel/re-target and Mail → Telegram. Native
queue simulation does not establish live server acceptance. No outer GPLv2 code
or assets were copied; pins, recipe 8, PostgreSQL schemas and S3 format stay fixed.

## Ordinary inline photo and video

History and search use the shared own visual renderer for ordinary photo/video
attachments, including a single visible album member. Caption text follows the
attachment by default; received placement is described below. Ordinary images use aspect-fit, while album tiles retain aspect-fill.
Other file/audio/voice/round-video/unsupported attachments keep their existing
cards and explicit controls; this slice does not implement their specialized UI.

Own sizing follows verified ChatLayoutUtils.swift:16–32,76–114 and
ChatMediaItem.swift:600–610: photos fit within 320 points, small-image minimums
are preserved, captions reserve portrait width, landscape video fits up to 420
points, and portrait video uses the 320-point bound. Available widths are finite
and bounded; narrower windows clamp the reference minimums to available width,
and pathological landscape video keeps at least one pixel of height. These are
deliberate own adaptations. Autoload and exhaustive pixel parity remain open.
Received InvertMedia placement is described below. Supplemental fitted/aspectFitted source
in TGUIKit Extensions.swift was read directly; it is outside the original index.

The exact attachment/context reveal guard applies independently in history and
search. Hidden media exposes Reveal, without photo/preview/player actions; an
explicit full-file download/save remains available through the context menu.
Reveal does not open the media automatically. A ready photo then exposes its
native accessible Button; video uses explicit download and playback controls.
The existing borrowed-file decode lifetime, cancellation checks and 512-pixel
thumbnail cap are retained. Whole-message selection hides these inner actions
and keeps the exact source message ID.

The explicit DEBUG album fixture now passes the same page configuration into
search as history, preserving media IDs, spoilers, fingerprints and action
metadata. A regression compares search129 to its history source. Defaults and
live search are unchanged. Root native checks verify search/history Reveal,
preview, one-message selection, actual synthetic video playback, portrait fit,
Mail → Telegram and restart with the ordinary draft preserved and media hidden
again. These isolated checks do not establish live-account/server acceptance.
No outer GPLv2 UI/assets were copied; pins, recipe 8, PostgreSQL schema and S3
format remain unchanged. Actual gate outcomes are in development-status.

## Received caption placement

The native `InvertMediaMessageAttribute` is projected for supported received
photos and ordinary videos. History and search move the existing rich caption
above the visual attachment when requested; otherwise it remains below. MIME
`video/webm` and nonvisual file/audio/voice/round-video cards are excluded. Search
keeps its existing four-line limit and copy protection, context menus and native
message identity remain unchanged.

For a visual album, placement comes from the first visible member while the
caption comes from the first member with nonempty text; these need not be the
same message. Original captions and IDs remain in the model. The moved caption
still toggles the exact visible group during message selection. This follows
ChatRowItem.swift:114–121,1766–1767,1788, ChatGroupedItem.swift:43–52,1169–1172 and
ChatMediaItem.swift:774–777. CoreExtension.swift:307–320,1534–1539 confirms the
interactive-media and WebM boundary; broader animation/map/paid/secret parity is
not claimed. New-photo preparation placement is described below.

The explicit DEBUG album fixture marks messages126 and129 above media; defaults
are unchanged and search/history share placement with the same descriptors and
versions. Mapping regressions use native photo/video/attribute objects and cover
history/search, default order, excluded cards, first-member placement, empty
captions and file albums. Actual owned synthetic native checks and their limits
are recorded in development-status. PostgreSQL/S3 retention is unchanged.

## Editing caption placement

The inline edit accessory offers Move Caption Up/Down for a message with media,
within the existing edit permissions. Its whole surface accepts the context
menu. The session starts from the raw native InvertMediaMessageAttribute,
including nonvisual files whose renderer deliberately keeps the caption below.
Text/entities/selection and placement remain independent per-chat state in the
current account context. A placement-only edit is valid, including an empty
supported caption; unchanged content and invalid or over-limit edits are refused.

Menu and submit actions capture session/revision/context; busy or uncertain
operations cannot change placement. Switching chats/services retains the edit;
cancel/reopen restores the source, and restart resets this temporary mode while
preserving the ordinary draft. An applied acknowledgement clears only the exact
submitted session, retaining newer input.

Dispatch builds edit content from the freshly validated Postbox message. Legacy
callers that omit additive metadata therefore retain the native flag; an explicit
placement remains an override. The existing engine API receives invertMediaAttribute.
Its unchanged-text reconciliation compares raw placement as well as text/entities.
References: ChatInputAccessory.swift:194–206, ChatInterfaceState.swift:1040–1043,
ChatController.swift:3827–3849, ChatPresentationInterfaceState.swift:1163–1185,
and the independently prepared RequestEditMessage.swift:185–195 (flag bit16).
No outer UI code/assets, pins, recipe8 or storage schemas changed.

Regression coverage includes native request content, nonvisual raw-state
preservation, real encrypted Postbox validation, legacy callers, stale menu/submit,
uncertainty and late acknowledgement. Owned native synthetic QA verifies the
whole-band menu, placement-only confirmation, text/chat/service preservation,
cancel/reopen, synthetic acknowledgement and restart. It does not establish
live-server acceptance. New-photo preparation is described separately below.

## New-photo caption placement

Photo preparation offers Move Caption Up/Down in its native actions menu and
header context menu, including an empty caption. The input stays beneath the
preview, matching the reference’s active layout; choosing placement changes the
outgoing message. Ordinary file preparation has no placement action. Video,
album preparation and other reference media options remain separate open work.

Text/entities/selection and placement have independent state. Menu actions
capture the preparation context and caption revision; old menus, submission and
uncertain phases cannot change the flag. A send freezes input and placement
together, persists the submission marker, and passes the native
InvertMediaMessageAttribute through the existing media enqueue boundary. Reply
and thread validation remain required. Admission checks the pending flag and the
same-transaction receipt requires exactly the corresponding native attribute
count. Acceptance records preserve the choice; an unknown outcome never resends.

Placement introduced schemaVersion2 with an explicit captionAboveMedia Bool;
current writes use schemaVersion3 as described below.
Legacy schemaVersion1 without the field restores below; version1 with an above
flag, version2 without the field, future schemas and above on a file are refused.
Older Makosh versions reject version2 rather than silently losing placement.
The existing envelope, PostgreSQL schema and encrypted S3 format are unchanged.
Recovery restores the normalized photo, rich input and placement without
submitting. Initial-write races, persistence retries and cancellation retain the
frozen choice. Cancellation payloads are held only until their in-flight initial
write ends; cancellation tasks/retries own their frozen copy afterwards.

Verified references: PreviewSenderController.swift:62–66 (effective file mode
below), 388–394 (media action), 544–560 (inactive input-reordering code),
1893–1897 (leadingText); SenderController.swift:643–644 (native attribute).
These are inspected workflows; no outer UI code/assets or embedded credentials
were copied. Independently pinned engine recipe8 remains unchanged. Root tests
include real encrypted Postbox admission/reopen and real PostgreSQL/S3 photo
restoration. Native owned synthetic QA verifies actions/context menus, text
preservation, restart, queue acknowledgement, file exclusion and cancellation.
It establishes no live Telegram server acceptance.

## Outgoing photo media spoilers

The native photo actions and whole-header context menus offer Hide with Spoiler
and Disable Spoiler, independent of caption placement and rich input/selection.
The preparation preview is blurred/covered and the image is absent from AX while
hidden. Ordinary file preparation cannot enable either photo option. The input
stays below the preview. Menu actions capture the current context/revision and
reject stale, started or uncertain states.

The send freezes caption, placement and spoiler, persists the submission marker,
and adds MediaSpoilerMessageAttribute to the pinned native engine message. The
engine retains the attribute and uses its uploaded-photo spoiler bit. Pending
admission compares the exact option; the atomic native receipt requires exactly
one attribute when enabled and zero when disabled. Rich entities, reply/thread
validation and no-resend behavior remain unchanged.

Pending JSON writes schemaVersion3 with an explicit mediaSpoiler Bool. Legacy
schema1/2 may omit it and restore false; legacy true claims, missing schema3 Bool,
wrong types, future schemas and true-on-file are refused. Older apps reject the
new schema rather than silently opening the photo. The existing envelope,
PostgreSQL schema and encrypted S3 format are unchanged. Files remain encrypted
S3 objects; PostgreSQL stores metadata. Acceptance/cancellation preserve both
options, and cancelling never deletes the immutable archive.

Rebinding freezes the latest prepared tuple against its original store, including
while the initial write is pending. Initial snapshots are consumed on completion;
failed detached updates retain a storage-only retry and prevent that preparation
from being restored with stale options. Recovery captures a controller epoch
before loading; reset and detached write start/completion invalidate older
snapshots, including file exports finishing after the pending marker cleared.
Rejected exports are discarded; explicit retry reloads current state. Retrying
never submits a message and cannot mutate the new store. A failed/unacknowledged storage write does not prove
that the latest unsaved input will survive process death.

Verified reference: PreviewSenderController.swift:381–386 (toggle),1701–1705
(ordinary media eligibility, excluding secret/paid),1893–1897 (send flag);
MediaPreviewRowItem.swift:48,212 (forceSpoiler with no parent). The engine sources
SyncCore_MediaSpoilerMessageAttribute.swift, EnqueueMessage.swift:249,286 and
PendingMessageUploadedContent.swift:646–658 confirm the native boundary. No outer
GPLv2 UI code/assets or embedded credentials were copied; recipe8 is unchanged.
Current preparation supports ordinary photos, not secret/paid/video/albums.
Animated dust effects and full media-option parity
remain open. Real Postbox/PG/S3 regressions and owned synthetic native QA establish
local behavior; live Telegram server acceptance is not established.

## One-shot photo Send as Spoiler

Photo preparation exposes Send as Spoiler from the send control's context/held
menu. A regular primary click uses the current preview choice. The explicit
command overrides only this submission to true, leaving the preview toggle,
rich input/selection and placement unchanged. It captures preparation ID and
caption revision and requires a ready ordinary photo and valid caption; stale
menus, ordinary files and busy/uncertain states cannot dispatch.

The existing durable submission marker, native provider/receipt and acceptance
storage-only retry receive the same frozen rich input, placement and true flag.
An unconfirmed marker cannot enqueue or retry the send. No pending schema,
PostgreSQL/S3 format or engine recipe changes are needed.

Verified reference: PreviewSenderController.swift:1212–1244,1316–1324,1378–1380,
1787,1893–1897; send(false, asSpoiler: true) and asSpoiler ?? state.isSpoiler are
independent from the preview toggle. Own SwiftUI Menu(primaryAction:) plus
contextMenu preserves primary/secondary/held gestures, verified in the owned
native synthetic app. Tests exercise stale identities/revisions, invalid input,
file exclusion, frozen rich content/options, held/failed markers and acceptance
retry without resend. The complete reference send menu, playback/cover/album
preparation and live Telegram acceptance remain open. Video support follows below.

## Ordinary video preparation: picker, first frame and native queue

The shared-window attachment menu offers Photo or Video and a separate File.
The single-selection native panel routes images to photo normalization and
videos to the owned staging path; an MP4 chosen as File remains a document.
Video staging copies original bytes without transcoding or metadata stripping, then inspects only that
copy with AVFoundation. External media references/aliases are forbidden. An
explicit original-name MIME hint identifies extensionless private stage files;
cancellation and inode/stat checks reject removed or changed stages. Duration is
frozen as Double(Float32(seconds)), matching the native Postbox/FlatBuffers
decoder. Display dimensions include the preferred transform. Bounds are positive
duration up to seven days, dimensions up to8192 with40M pixels, and4GiB bytes.

Video pending records use schema4 with required typed width/height/duration,
hasAudio and inCollage. File/photo writes remain schema3; legacy schemas1–3 retain
their existing meaning, including generic files named.mp4. Metadata on another
kind, missing fields, noncanonical duration and unsupported schemas fail closed.
Encrypted Postbox stores this descriptor beside rich input/reply/options and the
S3 receipt; PostgreSQL stores archive metadata and encrypted S3 stores bytes.
Restore authenticates exported bytes, re-probes them and compares dimensions,
duration and audio presence with the frozen descriptor. It preserves inCollage
rather than deriving it from final single-message grouping. Caption updates,
submission/acceptance/cancellation markers and same-preparation retries preserve
the descriptor; a retry cannot replace it. Cancellation retains archived bytes.

The native mapping follows SenderController.swift:426–442,378–382: Video with
supportsStreaming, nil preload/coverTime/codec, stem.mp4 filename and video/mp4
MIME; non-MP4 originals also carry hintFileIsLarge. Animated requires a frozen
non-collage preparation, no audio and an original MP4 smaller than10MiB. A fresh
singleton defaults to inCollage=true, as confirmed by CoreExtension.swift:2953–3015
and PreviewSenderController.swift:1743–1754. supportsStreaming is a native flag,
not evidence that a container was optimized for streaming. The active reference
FetchVideoMediaResource.swift:50–72 copies bytes; its export/transcode path is
commented out. No GPLv2 UI/assets or reference credentials were copied.

Admission matches the persisted video descriptor. The same-transaction local
receipt additionally checks one queued video, exact native attributes, MIME,
size, local resource identity and singleton grouping before accepting its marker.
Video also requires exactly one bounded generic JPEG previewRepresentation in a
distinct non-secret local resource. Its ID, size, dimensions, progressive data,
immediate data, video/personal flags and type hint must match the frozen receipt;
native representation equality alone omits several of these fields.
Controller recovery requires the same descriptor, preserves rich input/options,
and keeps an unknown submission non-resendable. The video modal now shows the
transformed first frame at the reference's320px decoder bound and exposes
placement, spoiler and one-shot override. The decoder owns its generator on one
actor, cancels native work and rejects a missing/changed or foreign stage.
Native CUA QA verified MOV/MP4 preparation, orientation, spoiler accessibility,
caption/options after restart, synthetic acknowledgement, photo/file cancel and
shared Mail→Telegram navigation without resurrecting cancelled preparations.

Tests use real generated MP4/MOV, encrypted Postbox, PostgreSQL and S3. Recipe9
also permits exercising the production transaction wrapper and native enqueue
core locally: original bytes enter real MediaBox, message/options and atomic
receipt survive reopen, and accepted preparations cannot enqueue twice. This
test creates no Account or network managers. The UI fixture separately retains
explicit synthetic StoreMessage construction; its queue is not server delivery.
Outgoing JPEG follows SenderController.swift:104–127: first transformed frame,
at most320px, quality0.3. Shared MediaBox preparation keeps both resources and
reads back a complete original and exact JPEG bytes before permitting enqueue;
subscription runs on the native FIFO data queue after both writes. The first
synchronous snapshot reports incomplete data as known failure rather than waiting
for a fetch. Void copy/store calls suppress errors and do not acknowledge success. Cancellation
stops decoding/observations and guards late callbacks. Real native-core/reopen
tests retain thumbnail metadata and actual JPEG bytes. The derivative is rebuilt
from the authenticated original on a ready preparation's recovery; the encrypted
S3 archive format and PostgreSQL schema are unchanged. The original is never
transcoded. Owned native CUA verified local synthetic MOV acceptance through this
shared preparation path in the common window.
Full Account/media-transform/network pipeline and Telegram server acceptance
remain unverified. Preparation playback now borrows only the validated owned stage,
rechecking its inode/stat snapshot after native readiness. A container MIME hint
supports extensionless MOV/MP4; external playback is disabled. The reference's
muted loop runs only in the native surface's visible key window. Spoiler, dismiss,
rebind and submission detach the decoder before source release. Player identity
and generation reject stale callbacks; loading has a30-second deadline and safe
visible failure. Received-media playback retains its previous end behavior.
Real AVPlayer regressions cover actual MOV/MP4, repeated loops, visibility,
replacement, cleanup ordering, invalid preparation and immediate cancellation.
Owned final CUA verifies animated portrait MOV, labelled native accessibility,
spoiler hiding and Escape preserving the ordinary draft. Restart preserves that
draft without cancelled-media resurrection. Native window notifications and held
in-flight cancellation remain separately unverified in CUA. The basic cover
workflow below is exposed; complete editor parity, multiple selection/albums and
full visual parity remain open.

### Custom video cover storage, transport and restoration

The optional `TelegramUploadVideoCover` owns a separate JPEG stage. Its IO crops
normalized oriented-image coordinates, rejects nonfinite/out-of-bounds crops,
scales to at most320px without upscaling and encodes quality1.0 decoded pixels.
Owned-file checks, bounded reads, geometry and SHA256 reject altered stages.
First-frame JPEG generation remains separate and unchanged. The native mapping
sets videoCover to one canonical TelegramMediaImage while retaining the ordinary
video previewRepresentation; original, thumbnail and cover have distinct IDs.

Pending schema5 stores a bounded cover descriptor, with exact account/chat/
preparation identity and archive attachment ID `video-cover`. Schema1–4 without
a cover remains readable; older builds reject schema5. Original and cover are
separate encrypted S3 objects. PostgreSQL and Postbox store metadata/pointers,
not attachment bytes. The encrypted object format and PostgreSQL schema are
unchanged. Authenticated export restores both owned stages and revalidates the
cover digest/geometry. Caption/options, submission and accepted receipts retain
the same descriptor. Retry refuses a dropped/changed cover. Cancelling preparation
releases its owned temporary files; archived original and previous cover versions
remain retained.

Shared MediaBox preparation holds all three resources and reads back a complete
original plus exact first-frame/cover JPEGs on the native FIFO queue before
enqueue. Atomic admission and acknowledgement require matching persisted cover,
stage and transport descriptors and every canonical native image field. Real
encrypted Postbox/MediaBox enqueue/reopen tests exercise MP4/MOV both with and
without covers; isolated PostgreSQL/S3 tests verify distinct retained objects
and exact restoration. Recovery refuses a missing or mismatched cover. The
existing preparation sheet displays the cover and disables video autoplay,
following the selected reference. Spoiler hides the image from accessibility.

Owned native CUA QA used a pre-saved synthetic cover, edited its caption, toggled
spoiler, restarted and accepted it through the local synthetic provider. Read-only
Postbox/S3 readback verified the accepted record and retained JPEG; restart did
not restore the accepted preparation. Full Account/network/server delivery
remains unverified.

### Video cover picker, crop and serialized replacement

The existing preparation menu exposes Add/Change/Remove. A small asynchronous
NSOpenPanel helper selects one image; SwiftUI owns the editor and preparation
context. The editor owns a bounded copy of the original image, verifies its displayed
digest against the exact bounded bytes read for Apply, and releases only owned
stages. Cancel/Done, drag/move, four corner resize handles, keyboard arrows and
accessibility adjustment operate a fixed aspect. Reference bestDimension selects
an exact preset when available, otherwise Original; nonstandard video ratios are
not rounded to a preset. The final crop produces the same bounded cover format.

TelegramPendingUploadSession.replaceVideoCover freezes its source FD before
suspension, serializes against the account-bound pending draft, checks current
preparation/metadata/reply and prior cover, then writes with CAS. A repeated
desired cover reuses its saved object after unknown ACK; an old editor or a
submitted preparation cannot overwrite it. Original, prior cover objects,
caption/options and archive formats remain retained. Removing the current cover
restores ordinary video preview and writes a coverless schema4 preparation.

The controller has separate editor/write generations. Editing and any unresolved
cover write block send and caption/options changes. Successful replacement also
confirms the visible caption/options snapshot, including recovery from an earlier
failed caption write. Errors require explicit persistence retry; they never retry
enqueue. Detached account-bound writes may finish, while late results cannot
publish into a new account/window. A restored preparation uses its durable ID
independently of the rich editor's caption generation. Cancellation/rebinding
clears editing context and releases stages without removing archived objects.

Owned CUA QA selects, adjusts, applies/cancels, changes/removes and restores the
cover in the common workspace, then accepts it through the local synthetic queue.
Readback verifies exact caption, unchanged original, receipt and three previous/
current retained S3 cover objects. Restart does not reopen the accepted draft.
This uses isolated synthetic Postbox/PostgreSQL/S3, without personal account,
Keychain or Telegram network. Real persistence regressions cover replacement,
idempotence, stale editor, submission freeze and retained previous bytes.

### Original source, rotation and horizontal mirror

The picker now copies the original image bytes before decoding, retaining their
SHA256 and full oriented geometry. Input remains bounded to20MiB,8192px per axis
and40 million pixels. Ordinary photo attachments retain their existing JPEG
normalization. Apply checks the snapshot digest on the same read before EXIF
orientation, editor rotation, output mirror and crop. Final rendering draws
directly into the at-most320px JPEG at quality1.0, without a second full-size
transformed bitmap or source metadata. Temporary source copies are released on
cancel/close; the selected original is never changed. The final cover continues
through the existing encrypted S3/pointer workflow.

EditImageControls.swift:96–123 and TGUIKit Extensions.swift:1481–1570 establish
counterclockwise quarter turns followed by horizontal output mirror. The two
state fields are independent: a subsequent rotation appears clockwise while
mirrored. EditImageModalController.swift:1068–1113 and Extensions.swift:1882–1926
transport the crop counterclockwise and mirror its x origin. The reference keeps
that crop direction even while mirrored; rotate/flip order can therefore change
the crop path despite equal final raster state. Makosh retains these semantics.
The selected dimension preset remains fixed for later resize; Original follows
the current transformed image's aspect. The existing bottom controls now add
Rotate (Cmd+R) and Mirror between Cancel and Done.

Research corrected two earlier frontier claims. Crop has four corner controls,
not eight; eight controls belong to inserted image overlays. The reference's
200-square aspectFitted call may upscale to the smaller fitted canvas dimension;
it is not a literal200pt initial crop. Makosh already matches its main normalized
initial geometry. The later fitted geometry/resize/double-click slice and its
remaining precision differences are recorded below. Inserted-image editing
remains open. Drawing/eraser/undo are
implemented below. This is
progress toward complete reference editor/Telegram parity, not its completion.


### Drawing and stroke history for video covers

Draw opens a separate native sheet over the full transformed source before
crop. Its own value copy owns accepted strokes and local undo/redo; Cancel
cannot mutate the parent painting, while Done returns the accepted list.
Reopen clears redo and keeps existing strokes undoable. Brush/arrow toggle,
eraser, Cmd+D, Cmd+Z/Shift+Cmd+Z, physical A/E/L, Return and Escape follow the reference.
A narrow AppKit first responder fixes native bare-key delivery in nested sheets;
there are no event monitors or retained window globals.

The continuous reference palette persists color location and brush weight.
Default0.22 gives5pt; pressing the strip resets thickness to4pt and dragging
up increases it to18pt. Every stroke freezes tool/color/width/capture canvas
geometry. Normalized original-oriented top-left points are mapped from the
current transform; rendering scales width by the average of the two axis
ratios. Arrows use first/last points, a strict per-axis threshold and round
45-degree heads. A separate transparent paint layer confines erasing to paint,
so original image pixels remain visible. Both preview and final export use the
same independent renderer, with final painting performed directly into the
at-most320px crop output. The original source and ordinary photo path are
unchanged; final JPEG bytes use the existing encrypted S3 cover pointer/receipt
workflow without a new schema.

Ten drawing/brush regressions cover whole-stroke history/cancel, erasing,
arrow geometry/threshold, pointer mapping across eight orientations, cropped
JPEG export, brush gestures, Retina knob precision, computed-width overflow
rejection and physical tool keys. Owned native QA checks
actual pixels, tool keys and save/cancel/reopen/rotation. Prepared and accepted
Postbox/S3 readbacks verify final320×160 pixels, caption, original video and
receipt; restart restores the cover and does not reopen an accepted preparation.
Account/network/server delivery and complete reference-editor parity remain
unverified/open as recorded in development status.

### Fitted crop geometry and pointer gestures

Crop and drawing share shrink-only width-first/height-second fitting with ceil
of each reduced orthogonal extent and8pt available-space padding. Small sources
keep their dimensions. Movement subtracts separately ceiled canvas-local pointer
positions. Corner resizing uses absolute ceiled/clamped X and derives height
from width and the retained preset (or transformed Original aspect). Four own
20pt L-shaped controls match the reference interaction surface. The fitted-view
minimum is40pt wide, limited by bounded opposite-anchor geometry.

A simultaneous parent double-click gesture covers corner hit targets and
selects the largest centered aspect region only inside the current selection;
an accessible action exposes the same operation. Native portrait QA reproduced
stationary corner mouse-down resizing and failed double-click with zero-distance
drag. A1pt movement threshold prevents resize until actual movement. Rebuilt
native top/bottom single and double clicks, minimum drag and Cancel pass.
Geometry regressions use independent literal fitting/minimum/pointer cases.

Makosh intentionally maintains bounded anchored aspect geometry. Reference
conditional feedback can differ after its intermediate40×40 minimum or while
a corner remains active. Reference runtime callback timing is unverified.
Initial fitted-point precision and independently rounded source-pixel crop
coordinates are implemented in the following slice; inserted-image overlays
remain open. The704-test crop-gesture suite
passes; prepared/accepted S3 readbacks preserve cover pixels/caption, original
video and retained receipt. No storage/credential schema changes occur here.

### Initial fitted selection and source-pixel rounding

The first valid crop-canvas appearance initializes the floored fitted square
and retained preset/Original aspect once. Later geometry edits and drawing-sheet
return preserve that selection. Independent rounded source-pixel origin/extent
replaces floor-origin/ceil-edge expansion. The renderer intersects right/bottom
with the source image and rejects rounded zero-pixel axes before allocating.
It keeps the same original-space paint CTM and bounded320px output.

Regressions verify initial fitted-point literals, fractional crop dimensions
and first-pixel colors across eight orientations, zero-axis rejection/source
retention and CoreGraphics half-pixel edge intersection. Focused30 tests and
the709-test full suite pass. Native move/drawing-cancel/save/restart and prepared/
accepted S3 checks verify320×192 quadrant cover, exact caption, retained receipt
and unchanged video. Reference conditional feedback differences remain documented;
inserted images follow below. Complete Telegram/network parity is open.

### Inserted cover images

The main cover editor accepts a file or an explicit Cmd+V paste of file URLs or
PNG/TIFF. Decoding uses owned immutable oriented snapshots with20MiB,8192px-axis
and40M-pixel bounds. It admits at most16 live layers and40M unique decoded pixels
retained in current/undo state, with64 history steps. A multi-file paste publishes
only after all inputs pass and produces one undo step. No source URL or image
bytes enter PostgreSQL. Cmd+C copies the selected bitmap as PNG; Delete, Cmd+Z
and Shift+Cmd+Z operate on ordered layers and selection. Eight handles preserve
aspect by default and support the reference Shift formulas. Pointer movement is
unclamped fitted-point geometry; export clips to the bounded crop.

Each item captures its fitted-point rectangle and source multiplier at insertion.
The transform renderer composites base and paint, restores their transform, then
draws ordered images in transformed top-left source coordinates. Independent
rounded pixel rectangles precede final bounded320px JPEG crop. Unrotated mirror
keeps overlays. Original video/thumbnail remain distinct, and accepted flattened
cover bytes use the existing encrypted S3/CAS/schema5 path. Working layers are
ephemeral, like the drawing editor; this adds no persistence/configuration schema.

Forty-one focused and720 full XCTest plus32 Python checks pass. Native regression
reproduced and fixed drag Undo losing previous selection and handle double-click
resetting crop. All eight stationary handle double-clicks, file Menu AX, clipboard
shortcuts, Delete/Undo/Redo, pointer resize/Undo and Draw Cancel pass. Prepared and
accepted readbacks verify320×192 quadrant/white-border output, exact caption,
unchanged video and retained digest/receipt; restart restores prepared state and
does not reopen accepted state. These are isolated synthetic checks, not live
Telegram delivery. Release-only Shift and interrupted/clipped gesture edge cases
are unexecuted. Deterministic centering, bounded state and reference captured-scale
preview/export differences after refit are recorded in reference-interface.md.

## Ordered preparation storage: album migration step1

`TelegramPendingUploadDraft` schema6 has one canonical ordered `items` array and
an explicit grouping choice. Each item has a stable UUID independent of its
preview position and restored temporary path. Shared caption/entities/selection,
reply and original composer draft remain account/chat scoped. Legacy schema1–5
retain their single-file encoding and `prepared`/`video-cover` attachment IDs;
editing old photo options still upgrades their schema as before.

Batch originals use `prepared:<item UUID>` and covers use
`video-cover:<item UUID>` under the same preparation identity. S3 stores the
existing authenticated encrypted envelopes; PostgreSQL stores metadata only.
All items/covers must be stored before one Postbox CAS publishes the preparation.
A later failure leaves the previous pointer/revision unchanged and retains
successfully archived originals. A committed-pointer retry checks exact order,
metadata, cover and streamed plaintext SHA256 before reusing stored objects.
The digest reads the frozen inode in bounded chunks without consuming capture.

Shared caption, submission and cancellation writes retain every item and the
grouping choice. Restoration exports all items in order and releases every new
temporary file/cover on any later failure. Every item receives full scope,
state, kind, name, size and digest validation; IDs and archive object IDs must
be unique. Empty, ambiguous, downgraded or partially invalid batches fail closed.
The existing512KiB encrypted preference payload limit remains unchanged.

The batch provider now has a reference-derived ordered send plan, all-message
transactional admission/receipts and observation of every queued ID. The picker,
controller and recovery protocol now carry the whole ordered set. Native preview
uses groups of at most10 visual items or individual document rows. Reorder,
remove, selection, recovery and covers use stable item IDs. Full receipt matching
never substitutes the first queued ID for the complete result. Whole-list mode,
basic group eligibility and raw-original switching are implemented below. Archive
preparation, full classification and caption normalization remain in
[telegram-album-migration.md](telegram-album-migration.md).
No first-item fallback or automatic resend is available.

Real Postbox/PostgreSQL/S3 regressions verify three ordered files including a
covered video across reopen, exact bytes, committed retry reuse, same-size
content substitution rejection, late preparation failure retaining prior state,
and forged third-item restore releasing earlier stages including its cover.
Single-file controller/receipt regressions reject first-item-only admission.
Legacy preparation retries also verify the staged plaintext SHA256 before
accepting caption/options changes. Same-name/same-size changed contents conflict
without changing the stored revision or caption; acknowledged unchanged retries
reuse the existing S3 record. The independent review identified this pre-existing
gap, and a real Postbox/PostgreSQL/S3 regression reproduced it before the fix.

The broader sequential Telegram/product goal remains open.

### Raw photo originals in ordered preparations

New picker photo preparations, including a single selected photo, first copy the selected source into an
owned stage, then derive JPEG from that frozen copy. The JPEG keeps the selected
filename stem with `.jpg`; the raw source keeps its original filename and bytes.
Both resources share one stable item ID but have different temporary and durable
record IDs. Each chat's policy selects S3 or encrypted local preparation. Raw photos retain the existing20MiB preparation bound. Videos and
ordinary files already retain their source payload; no extra copy is added here.

Schema7 stores raw photo metadata as `originalFile`, with attachment ID
`original:<item UUID>`. JPEG and cover attachment IDs remain unchanged. Every
source is captured before publication, and the whole preparation is
published only after every resource has an authenticated durable receipt. Retry compares original metadata
and streamed plaintext SHA256. Restoration authenticates all records, returning
both stages or cleaning the entire restored set on failure. Reorder/remove,
detached writes, cancellation and accepted receipts preserve the source binding;
temporary cleanup attempts both resources even when one removal fails. S3
copies are never deleted by these operations.

Schemas1–6 remain readable. A schema7 pointer requires originals for every photo;
schema6 rejects source-bearing records. Metadata matching during native photo
submission validates raw stage ownership/name/size; only the active JPEG enters
MediaBox and gets the before/after-copy digest verification. The raw bytes are
authenticated during archive restore and initial-write retry. Schema8 file-mode
submission separately verifies its selected raw payload before enqueue.
Legacy JPEG-only preparations cannot reconstruct original bytes. Archive mode
remains open. Every new picker selection uses the ordered path, including one
file/video/photo without grouping. Legacy programmatic single-file/video APIs
remain compatible.

Real controller/Postbox/PostgreSQL/S3 regressions cover edited order/removal,
restoration, a later video's cover following its ID, later-stage failure cleanup,
cancellation and detached initial-write lifetime. Lost acknowledgement preserves
the native complete receipt and cannot resubmit. The DEBUG synthetic adapter
uses a valid isolated native author separately from account sentinel -1; its
regression reproduced and fixed the native PeerId assertion. Owned native QA
verifies11 visual items, cross-group menu actions, exact restart recovery, local
queue acceptance and no resurrection; native drag/drop and live delivery remain
unverified. Media presentation selects the normalized JPEG; File selects the retained original.

## Native batch provider: album migration step2

Schema6 accepts a complete ordered array of typed Local message IDs, including
one leading text ID for separate sends with a nonempty caption. Partial, duplicate,
foreign-peer or non-Local IDs cannot acknowledge a preparation. The original
ordered durable records and caption/options remain in the accepted pointer.

The Account and isolated native providers share sequential all-resource MediaBox
preparation and transaction hooks. Every original must match its archived
plaintext SHA256 both before and after the copy. One immutable receipt captures
the full pointer revision, item identities, media descriptors, caption/entity
assignments, reply and unique group keys. Unsupported peer namespaces are
rejected before resource preparation. Admission checks current pointer,
resolved mentions and freshly derived reply version/thread; acknowledgement verifies every queued ID,
text, entities, placement, spoiler, grouping, thread and media. Strict derivative
checks cover fields omitted by native media equality, including cloud references,
video thumbnails, progressive/inline data and personal/video/type flags.
Reply attributes must preserve the native source thread, canonical quote and
absence of a todo item. A caller cannot combine an original fingerprint with a
different thread to redirect the batch.
Migrated-group quotes select the last eligible image/file, matching native
enqueue. Real local regressions cover both empty and multi-media source quotes;
whether a live source with multiple eligible media reaches this path is unknown.

Native encrypted-Postbox regressions enqueue21 documents with10/10/1 grouping,
read all original bytes and reopen the complete receipt. Mixed photo/covered-video
submission retains its caption, spoiler, placement and derivatives. A later
changed original rejects before enqueue; stopping at the committing checkpoint
queues nothing. Partial or malformed receipts leave the started pointer intact.
Lost callbacks retain complete acceptance and stale snapshots cannot enqueue
again. Native queue insertion cannot be rolled back by a failed acknowledgement;
this is uncertain, never permission to resend. Account network transformations,
server delivery and reconnection remain unverified; no personal account is used.

## Whole-list media/file presentation

Schema8 introduced explicit `presentation` without replacing the ordered canonical
resources. The schema8–13 behavior below remains readable; new ordinary picker
preparations use schema14's separate source facts, described below. Images retain raw bytes and the prepared JPEG; videos
retain one original payload plus video metadata. Mixed sets stay complete and
initially select file presentation. Both choices appear in the existing preview
menu when the retained resources permit switching. File rows use original names,
sizes and bytes. Legacy photos without a retained original cannot switch.

Mode changes perform metadata-only guarded writes: exact account/chat/preparation,
reply, item order and previous mode/grouping must match a prepared pointer.
An exact committed retry reuses the current pointer. No S3 recapture occurs.
Reorder/remove, cover changes, caption writes, cancellation and native complete
receipts retain the mode. Send stays disabled until mode persistence succeeds.
In schema8–13, switching to media clears grouping for a mixed media/document set; returning to
files retains that cleared choice. File grouping rejects WebP. For legacy generic
sets its basic filename rule remains; if any item has typed music metadata, every
item must be typed music. Exhaustive music/codec coverage remains unfinished.

Caption placement/spoiler and video cover remain stored across switches. File
submission forces caption below while retaining the chosen spoiler, matching
the verified reference state/send boundary. Returning to media restores the
retained placement and cover. Native original-file enqueue verifies the selected
record's plaintext SHA256 before and after copying to MediaBox.

Static-photo payload admission inspects an owned no-follow byte snapshot.
It applies `SenderController.swift:333–368` to the transformed ImageIO thumbnail:
height must be at least40 pixels and width/10 must not exceed height. A narrow
width or reciprocal tall aspect alone does not force a File payload. The probe
shares the actual staging maximum2560; orientation and non-square DPI transforms
therefore match the generated JPEG. Decoder bounds remain at most8192 per axis,
40M source pixels,20MiB and one frame. Source options separately retain the
symmetric40-point/10:1 `NSImage.size` rule from `ThumbUtils.swift:222–260`.
For example64×64 pixels at144DPI now retains a64×64 photo plus raw source but
defaults to File (32×32 logical points). A32×32-pixel source at36DPI retains
only raw File bytes even though its64×64 logical source contributes Media.
New schema17 preparations retain Media in that latter case, as selected by the
ordered logical-source options. Schema18 retains the same allowance with a cached
ZIP. Schemas1–16 keep their visual-payload requirement; no old pointer is upgraded
by retry, caption/mode/list/cover edits or restore. Native payload kinds and bytes
remain independent. New typed WebP with an original .jpg name may likewise retain
Media while sending the unchanged document; its grouping remains disabled.
New ordinary photo preparation now follows the reference's default1280px or
explicit large2560px. The reference helper ImageCompression.swift:53–75 first
tries Mozjpeg75, then ImageIO.75. Makosh now prepares pinned portable Mozjpeg4.1.4
independently of research checkouts and uses FASTEST defaults, integer DCT,
optimized Huffman coding, quality75 and simple progression. An own white RGBX
rasterization and quiet C error/ownership boundary replace the uncopied macOS
wrapper. ImageIO.75 remains fallback; covers keep their existing quality1 encoder.
Exact dependency,98-file preparation and license review are in
Dependencies/Mozjpeg.lock.json and THIRD_PARTY_NOTICES.md. Scalar routines are
compiled; universal reference-build byte equivalence is not claimed.
Settings and the existing Media-preview
menu share the preference; its value is passed explicitly and frozen at preparation.
Changing the preference does not transcode already retained resources. Restoration
keeps the2560px bound for existing large photos and accepts their original encoder
bytes. Covers and raw documents retain their own paths. Typed WebP grouping under
misleading names and exhaustive MIME/recorder parity remain separate gaps.
Existing frozen preparations retain their kind, raw roles, facts and bytes;
restore never reruns new photo eligibility. Both representations survive source
removal. S3 OFF forbids every new copy, including either preparation resource;
later enabling does not promote them.
GIF/WebP/multiframe inputs are never flattened into static photos. WebP typed
originals, GIF conversion and explicit recorded-voice attributes are supported
below. Schema14 implements ordered whole-list options; full recorder interaction parity remains open. The
verified dependency order is in `telegram-album-migration.md`.

Media option eligibility is separate from all-visual grouping/layout: a mixed
photo/document set in Media retains caption placement, spoiler and one-shot
spoiler actions. File mode keeps those controls unavailable. A frozen original-
store mode/list request survives rebind and before-commit/lost-ACK failure;
restoration and send stay blocked until confirmation or an explicit retry.
Remove, reorder and grouping changes use the same frozen request boundary, so
rebinding cannot replace an unconfirmed list update with a caption-only save. Cancellation and
a newer preparation cannot be overwritten. Cancelling also releases a retained
failed mode request. The latest caption/options remain bound to the original chat.

Schema8 rejects missing/unknown presentation and Media with only documents.
For schemas1–16, removing the final visual item normalizes the remaining set to File in one
metadata write, guarded by the exact previous mode/order/grouping. An exact
committed retry reuses that pointer; stale mode, cancellation and a newer
preparation cannot be overwritten. Legacy schema6/7 writes remain compatible.
Local-only preparations retain every authenticated receipt and encrypted envelope
byte across mode changes, restart and later policy re-enable/resume. These writes
never create S3 copies; the per-chat prohibition also covers every initial resource.

### Ordered original sources

New ordinary picker preparations use strict schema17, preserving schema1–16
payload meanings. Schema14 introduced source facts;15 adds the versioned caption
projection described below;17 permits Media from source options even with only
document payloads. Every item requires its UUID, raw resource role/name/size/
SHA256, original-name selection MIME, bounded logical-image result and grouping
result. Photo/GIF facts bind the retained raw resource. Partial/unknown/null or
cross-resource facts are refused and independently re-probed before persistence,
after authenticated recovery and before native resource issuance.

The ordered reference fold makes PNG→WebP File and WebP→PNG Media when chosen
as media. Rejected small images contribute no option. File remains offered;
reorder/removal can clear unavailable Media/grouping and never enables them.
Metadata edits retain durable IDs without new copies, including with S3 OFF.
Native ordinary File images use logical ImageSize; mixed grouped Media captions
the first actual visual in each ten-item chunk, otherwise the last file.
Bounded decoders and incomplete MIME aliases remain explicit compatibility gaps
in `reference-interface.md` and `telegram-album-migration.md`. Older binaries
refuse newer schemas; retain pointers, encrypted resources and keys when rolling back.

### Internal ZIP codec

The next Archive slice has an independently authored internal ZIP32 writer and
streaming inspector over system zlib. It preserves ordered raw sources, hidden/
empty files and allocated collision names; verifies exact headers, CRC/SHA and
fresh owned source bytes without extraction. Count/name/catalog memory limits
are separate from the1500MiB raw-byte cap. See telegram-album-migration.md and
THIRD_PARTY_NOTICES.md for the profile, limits and SDK notice.
Schema16 introduced N ordered canonical items and one versioned ZIP
descriptor; new schema18 adds the source-only Media policy while keeping the same
strict descriptor format. The descriptor binds stable item IDs, allocated member names and a
scoped outgoing file record; it cannot authenticate bytes by itself. Save and
whole-bundle restoration verify both member bytes and the outer record digest
against the same held ZIP inode. Restoration owns originals, prepared files,
covers and ZIP together and cleans temporary exports on failure. Array-only
restoration refuses16/18 rather than omitting its ZIP. Schemas1–15 and17 reject
Archive fields and retain their existing behavior.

ZIP capture reuses the existing outgoing-file policy: S3 OFF forbids every new
S3 copy, including preparation, and encrypted local records never promote after
enable. Restoration reads existing immutable records without recapture. Generic
mode/prepare/plan entry points refuse Archive before changing state or copying
files. A dedicated `installArchive` authenticates an already durable ZIP and all
canonical/raw resources, discards authentication stages, then upgrades the exact
prepared schema15 pointer to16, or schema17 to18. Cross-family installation and
capture retention refuse; the predecessor fixes the Media policy. Rich raw input/selection, original draft, reply,
title and canonical records remain byte-bound; Archive clears grouping, caption
placement and spoiler. It does not capture files or create new storage records.

Its per-attempt admission token binds account/chat/preparation/revision and a
nonzero generation. The owner must cancel it on context invalidation. A lock
covers the bounded synchronous Postbox read/compare/set, so cancellation before
native admission refuses a queued write. Cancellation after admission cannot
undo it; a successful completion returns the committed candidate. Ordinary
serial writes retain their previous behavior. The native repository can replay
an exact retained candidate, including its revision and encoded JSON, while its
token remains active. A fresh Session call after a lost ACK is not that retry.
Completion means engine transaction completion, not an fsync promise.

An active schema16 Archive now has a dedicated one-document plan and native
enqueue receipt. The receipt requires exactly one plain ZIP resource bound to
the descriptor ID/name/size/digest, without raw-source facts, originals, media
metadata or previews. It projects one caption and forbids grouping/placement/
spoiler. Native admission compares the entire frozen pointer; the same queue
transaction validates the inserted ZIP and records exactly one accepted ID,
retaining all canonical resources and raw editor input. A lost ACK leaves the
accepted pointer durable; replay refuses another insertion. These operations
write no archive records or S3 objects. A queued ZIP cannot acquire explicit
media TTL/view-once attributes. Ordinary chat auto-delete is a separate native
attribute and remains supported; neither mechanism purges Makosh's archive.

Account and isolated native providers now accept an explicit recovered bundle.
The shared submission authenticates every canonical resource, retained original
and cover, binds ordered ZIP members to the durable descriptor, and validates
the ZIP against raw bytes and its saved digest before copying one ZIP to MediaBox.
The copied cache is digest-checked again before enqueue. Cancellation before
admission prevents insertion; stopping never discards the caller's bundle or
recalls an inserted message. Legacy array submissions continue to refuse16;
adapters without explicit bundle support refuse Archive. Submission creates no
file records or S3 objects. Account/server delivery has not been exercised.

The model restores the authenticated bundle and transfers canonical resources
and ZIP to the controller as one lifetime. Active schema16 Archive presents one
ZIP, retains its canonical resources and raw caption, and submits through the
bundle provider. Confirmation binds the exact encoded ZIP descriptor, presentation and caption
rules as well as the canonical tuple. A changed confirmation keeps stages and
permits only confirmation retry. Started submissions restore as uncertain,
without automatic resend. Cancellation, rebinding and destruction release the
whole temporary bundle; failed ZIP cleanup retains ownership and blocks a new
preparation until cleanup succeeds. These paths create no file records or S3
objects. Ordinary legacy recovery continues through the bundle adapter.

Guarded installation now commits a separate native preference receipt together
with the schema16 pointer. It binds the predecessor revision and SHA256 of the
exact sorted encoded candidate, including its new revision and raw editor state.
A fresh Session can authenticate the existing whole bundle and retry that exact
installation after encrypted Postbox reopen. Native admission requires the same
receipt and current candidate; replay writes neither pointer nor files. A later
edit, including A→B→A, started submission, wrong predecessor, missing/corrupt or
foreign-scope receipt refuses. Every non-idempotent ordinary pointer write clears
the old receipt, even if a subsequent write reuses the original UUID. Exact
ordinary no-ops preserve it; a guarded install sets its new receipt atomically.
Schemas1–16 are unchanged; older schema16 pointers
without this receipt remain restorable/sendable, but cannot use this install-replay
path. No automatic migration, recapture or enqueue occurs.

After bundle authentication, Session now retains the exact schema16 candidate
in a separate encrypted native preference before installing the active pointer.
The bounded metadata receipt binds the predecessor revision and SHA256 of its
exact encoded state. `loadArchiveCapture` exposes that retained candidate to an
explicit retry after reopen; loading does not install or enqueue. A failed native
installation or lost retention ACK reuses the same candidate and captured ZIP,
without the original caller's descriptor or a new capture/S3 object. The plain
schema15 pointer stays unchanged until guarded installation succeeds. Conflicting
candidates cannot replace the retained result. Exact no-op writes preserve it;
non-idempotent ordinary writes, including cancellation and installation, remove
it in the pointer transaction. Changed predecessor bytes with a reused UUID,
corrupt/foreign receipts and cancelled admission refuse. Native receipt metadata
is bounded to512KiB plus a fixed header; file bytes remain in their original
encrypted local/S3 store. Authentication runs again before installation.

Archive generation/mode switching is now connected to the existing upload menu.
For two or more schema15/17 sources, Session builds the ZIP from authenticated
durable originals, retains its exact candidate and installs it under native CAS.
It does not recapture members or depend on picker stages. A retained candidate
is reused after a failed native installation. Switching File/Media/Archive keeps
the same schema16/18 ZIP cache and raw caption; active Archive clears grouping,
spoiler and caption-above. Recovery accepts inactive caches. Shared submission
authenticates the whole bundle, then selects one ZIP or the ordinary File/Media
resources according to the active presentation. Mode changes create no further
file records or S3 objects. The existing menu layout follows the reference.
After returning to File/Media, existing reorder/remove actions are available.
Changed ordered members atomically invalidate the ZIP descriptor and produce a
schema15/17 pointer in the same policy family; immutable old ZIP/member records are retained. Selecting Archive
again creates only the new ZIP from the edited durable originals. Same-member
grouping and canonical video-cover edits retain the authenticated raw-source
cache. Active Archive itself remains one noneditable ZIP row, as in the reference.
Controller authenticates the resulting bundle and releases its old temporary ZIP
only after confirmation; a lost pointer ACK blocks send until idempotent retry.
New ordinary preparations use schema17; archive installation produces18. Older
15→16 preparations retain their policy and their exact frozen resource kinds.
Capture, receipt retention and pointer
installation are separate transactions. A process loss before receipt commit
still needs the caller's descriptor; this earlier handoff is not claimed recovered.
Failed installation never purges immutable records. Mode writes retain the
existing original-context serialization; cancellation subsequently tombstones
the preparation and never enqueues. No schema version, dependency or automatic
resend is added.

### Versioned caption projection

Schema15 retains the exact raw rich input and selection. The native send plan
independently replaces U+2028/U+FFFC with newline, trims platform whitespace and
clips/shifts explicit UTF16 entities. Unsupported/customEmoji provenance cannot
be removed by trimming. The1024 UTF16 preflight follows reference String.trimmed
without replacing U+FFFC. Editor/callback input stays raw; its visible counter
uses preflight count. Schemas1–14 retain raw send behavior across metadata edits;
no implicit schema upgrade occurs. Recorded voice/round validate raw empty input
before any archive copy, independently of ordinary caption projection.

Ungrouped multi-file nonempty projected captions lead once; whitespace-only input
does not manufacture an empty text message. A single File WebP or generic file
with image/webp selection MIME gets a leading text message and empty media caption.
Grouped placement remains first actual visual or last file per ten-item chunk.
Plan, complete native receipt and accepted-pointer cardinality use the same
versioned rules. Typed GIF/music whose original MIME is WebP can conservatively
get extra leading text because the transport later overrides MIME; exhaustive
MIME parity is not claimed. Markdown/detected entities, resolved custom emoji,
premium limit and reference placeholder/comment behavior remain open.

Real Postbox/PostgreSQL/S3 tests reopen raw padded/formatted/whitespace captions
after removing source paths, check exact projected native entities/IDs/receipts,
terminal reopen without resend and legacy14 reorder compatibility. OFF asserts
no new S3 object/events and no promotion after enable/resume. Actual existing
File sheet restores raw bold input/selection/item UUIDs with OFF; see current
development-status.md for exact gates and limits.

### Typed ordinary music preparation

Schema9 adds a strict `{kind:"audio",payload:{duration,title,performer}}` descriptor
on ordered file items. Required keys, exact types, bounded UTF8 tags/no NUL and
integral native seconds0…604800 are enforced. Unknown/extra fields, explicit null,
cross-kind data and any video/cover/original field on typed music are refused.
Schema1–8 reject typed metadata; schema9 requires at least one audio/WebP item and
an explicit File/Media choice. Schema10 adds GIF pairs below. Legacy generic files
never infer metadata on restore.

Picker preparation probes an owned no-follow file with exact uid/0600/size.
CoreAudio reads its held descriptor with a16MiB cumulative sniff budget and
derives container MIME from bytes. Restricted AVFoundation loads validate finite
positive duration/audio tracks, a bounded initial PCM fragment per track and
bounded title/performer tags. Seconds truncate to the native integer, including0
for subsecond audio. Cancellation and final inode/time snapshots refuse changed
resources. The original bytes remain unchanged. Synthetic WAV, tagged AAC/M4A
and actual ID3 MP3 have regression coverage; whole-stream integrity and exhaustive
codec support are not claimed. Unsupported inputs remain generic files; names
never imply recorded voice. No microphone is enabled; the separate internal
offline Opus codec is described below.

File projection, capture, restart and native submission retain the exact typed
descriptor. Capture/restore/MediaBox independently re-probe bytes, and complete
receipts compare frozen metadata before admission. Native ordinary music has
`Audio(isVoice:false,duration,title,performer,waveform:nil)` followed by `FileName`;
legacy single-file APIs refuse typed items instead of silently dropping it.
Local-only and S3 preparations share the same strict pointer and byte checks.
The S3-off policy still prohibits all new remote copies, including preparation;
later re-enable does not promote local resources. Actual owned M4A UI and private
Postbox/PostgreSQL/S3 evidence are recorded in development-status.md.

Ordinary Ogg/Opus now takes a separate byte-derived path through pinned libogg1.3.6
and libopusfile0.12, using the reviewed libopus1.5.1 decoder. A real1.25s recording
reproduced CoreAudio/AVFoundation's erroneous13s duration. The new probe derives
duration from trimmed48kHz PCM totals, preserves first matching TITLE/ARTIST
comments including whitespace, and decodes an initial fragment of each chained
link. First-link tags describe a chain. This tag policy is explicit; exact
AVFoundation/reference metadata enumeration parity is not claimed.

Strict libogg walking rejects CRC resynchronization, page/packet holes,
multiplexed serials, repeated serials, missing EOS, trailing bytes and malformed
Opus packet durations. Completed packets are counted against each page's granule;
non-EOS timestamps must agree, EOS cannot invent samples, and cropped initial
offsets, pre-skip and end trimming follow [RFC7845 sections4.4–4.5](https://www.rfc-editor.org/rfc/rfc7845.html#section-4.4).
Each independently derived link total must equal libopusfile's PCM total.
Bounds are128MiB,64 sequential links,8 channels per link,
1MiB per packet,4096 comments,4096UTF8 bytes per selected tag and one week total
duration. Invalid UTF8/NUL comments are refused. Whole-stream PCM integrity is
not claimed: every link gets a bounded initial decode. Other Ogg codecs still
use the existing native probe; exhaustive Vorbis metadata support remains open.

The held-fd callbacks have bounded reads/seeks, cancellation and explicit ARC
lifetime. The final inode/time snapshot remains mandatory. Picker Ogg recognition
uses bytes even with an opaque or misleading name; typed native music uses
audio/ogg, Audio(false), nil waveform and its original FileName. It never gains
recorded intent or rewrites bytes. Schema9 is unchanged. Capture/restore/MediaBox
re-probe the same facts; an older erroneous frozen duration fails equality and
cannot silently rewrite or enqueue. S3 OFF has no new-copy exception, and later
enabling cannot promote local preparations.

The existing common-window File sheet still shows the document icon, original
filename, size, caption and explicit Send/Cancel. A dedicated ordinary-music
player and tag presentation are not implemented by this probe change. Actual
owned synthetic UI restores an opaque `.bin` Opus preparation after restart
with its original picker source renamed, chat7 and S3 OFF preserved. Explicit
Send reaches only the synthetic local queue; closing observation and returning
from Mail retain conservative uncertainty without automatic resend.


### Typed original WebP preparation

Schema9 also carries `{kind:"webp",payload:{width,height}}`. Exact required Int32
fields, positive dimensions up to8192 per axis and40M pixels are enforced;
unknown/missing/null/cross-kind or conflicting resource fields fail closed.
File/Media projections retain the typed original; native mapping uses canonical
`image/webp` MIME and exact `ImageSize`, `FileName`, `Sticker("",nil,nil)` order.
Animated input does not infer Animated/Video or cloud sticker provenance.
Any typed WebP forbids grouping even with a misleading audio/document suffix.
Legacy generic files keep their original attributes and are never upgraded on restore.

Preparation probes content before suffix/photo classification. The owned no-follow
file is checked for uid/0600/size, cancellation and inode/time snapshots. A held
12-byte sniff returns nil for ordinary non-WebP without reading the entire file.
Recognizable WebP requires exact RIFF total length and at most20MiB before native
ImageIO. Native frame count1…256, safe positive canvas/frame0 dimensions and a
bounded256px thumbnail decode are required. Animated partial first-frame sources
use full canvas dimensions; raw bytes are never flattened or rewritten. Refused
recognizable input remains an unchanged generic File during new preparation;
a frozen typed descriptor must instead match an independent re-probe during
capture, restore and MediaBox copy. No fallback512×512 descriptor is invented.

Synthetic lossless/lossy static, animated, partial-frame and small WebP are
covered, together with truncation/trailing bytes, oversized axis/byte/frame count,
symlink/stale-size ownership and cancellation. Full malformed-corpus coverage and
exhaustive frame/stream integrity are not claimed. Actual encrypted local and S3
restart paths retain exact bytes/descriptor/caption through native enqueue;
changed dimensions fail even with a valid plaintext digest. S3-off still prohibits
every new object and later re-enable cannot promote local preparations.

Typed WebP also prepares the reference's optional first-frame JPEG transport
preview: transformed index0, maximum320px without upscaling, quality0.7 and at
most1MiB. The held owned bytes are checked against the frozen plaintext digest
before native encoding and independently against the typed canvas descriptor.
Original WebP bytes and animation remain unchanged. Native codec/encode failure
may omit this derivative; ownership, digest, unsafe input and cancellation errors
are never converted into optional success.

The separate `webPPreview` capability reuses the bounded JPEG identity without
occupying the mandatory video-thumbnail role. MediaBox reads back exact JPEG
bytes and the original before enqueue. All batch original/derivative IDs must be
unique; native receipts check dimensions, resource identity/size and every
progressive/immediate/flag field which upstream equality omits. The derivative
is regenerated from the authenticated original after restart, stays in MediaBox,
and creates no archive record or S3 copy even when S3 is enabled. Generic legacy
files retain an empty preview. Composer File presentation still shows its file
icon; this change supplies the native transport representation.

Full ordered source options (including40-point/aspect rules) and recorder interaction remain open.
Apple ImageIO and owned synthetic fixtures add no codec dependency or copied GPL UI.
Actual owned UI/host and full gate results are recorded in development-status.md.

### Typed GIF preparation

The picker inspects owned GIF87a/89a bytes before suffix-based photo/music
classification. Bounded ImageIO/AVFoundation conversion produces an independent
H.264 MP4 while retaining the unchanged raw source. Schema10 requires both
records, exact source SHA256, canvas and Float frame delays; unknown/null/cross-kind
fields, duplicate resource IDs, covers, zero raw size and output over128MiB are
refused. Schema9 cannot contain GIF; legacy generic preparations remain untyped.

Every canonical/raw capture is frozen before the first save. Pair verification
binds raw hash/facts and canonical canvas/name/no-audio metadata; restored bytes
are independently re-probed and any partial restoration is cleaned up. Canonical
MP4 hashes authenticate the converted bytes. Recovery retains measured positive
Float32 duration; generic video re-probe does not add a second H.264-codec check.
Retry, list and Media/File changes reuse the pair's original durable records.

Media maps MP4 to Video(duration0,flags[],nil optional fields), Animated only when
not inCollage, then FileName. File selects raw GIF with image/gif, ImageSize and
original FileName regardless of suffix. Its optional raw-frame0 JPEG uses max320
without upscaling, quality0.7 and cap1MiB. The frozen raw SHA/facts are checked
through a held owned snapshot. Ownership/hash/cancellation errors fail; optional
native encoding failure may omit the preview. Its distinct gifPreview role is
mutually exclusive with video thumbnail, cover and WebP preview. MediaBox exact
readback and complete admission/ACK checks cover all IDs and representation flags.

S3 OFF prohibits every new remote copy of either payload, including preparation.
The encrypted local pair survives restart and never promotes after re-enable;
PostgreSQL holds metadata, not payload bytes. The regenerated JPEG stays only in
MediaBox even with S3 ON. Real local/S3 native regressions cover both presentations
and no resend. The existing common-window preparation UI is retained. GIF cover
editing is disabled because the reference's GIF sender ignores its custom cover;
reference-interface.md records this difference and the source pin. Recorder UI,
full ordered source options, Archive and image editing remain open.


## Internal offline recorded-voice codec

The internal `TelegramRecordedVoiceCodec` now encodes explicit mono48kHz Int16
PCM into Ogg/Opus, then independently parses and decodes its own recordings.
The separate explicit-recording path below connects it to durable preparations
and native Voice attributes. Microphone capture and recorder/playback UI remain open.
Existing picked audio remains ordinary music/file; filename/MIME never grants
recorded provenance. No microphone or account action is enabled.

Source-confirmed reference: pinned TelegramSwift's
`packages/TelegramMedia/Sources/AudioRecorder.swift:285–345`, its pinned iOS
`submodules/OpusBinding/Sources/opusenc/opusenc.m:115–135,157–174,214–280`, and
`Telegram-Mac/SenderController.swift:295–312`. Makosh matches the writer's48kHz,
mono,20ms/960 samples,30×1024bit/s, APPLICATION_AUDIO and16-bit depth. Encoder
lookahead supplies pre-skip dynamically; zero padding flushes delayed audio and
EOS trims to the exact input count. One packet per page, the Makosh-only vendor,
no comment padding and the600s/20MiB limits are independent implementation
choices. The decoder accepts only this bounded recording format, not arbitrary
Ogg imports: exact headers, mono/rate/gain/map, lacing, CRC, stream/sequence,
packet duration, final granule and output count all bind admission. CRC detects
container damage; it is not authentication. Durable integration below retains
the authenticated plaintext digest and explicit recorded provenance.

Framing is independently authored against
[RFC7845](https://www.rfc-editor.org/rfc/rfc7845.html) and
[RFC3533](https://www.rfc-editor.org/rfc/rfc3533.html), using the
[Opus1.5 encoder API](https://opus-codec.org/docs/opus_api-1.5/group__opus__encoder.html).
The only own C boundary calls the variadic control API through a fixed signature;
encoder/decoder pointers stay inside one synchronous utility worker with defer
cleanup and cancellation between frames. No helper/UI code was copied from the
reference. The exact portable Opus source/license/build review is in
THIRD_PARTY_NOTICES.md and Dependencies/Opus.lock.json. Build/test scripts prepare
that hash-verified local SwiftPM package without consulting `.references/`.

Real codec regressions independently inspect every page/CRC and use libopus's
native decoder to check audio correlation and exact trim. Silence, sub-frame
lengths, PCM/byte bounds, damaged/truncated/trailing data, rechecksummed header/
sequence/stream/EOS forgeries, bitrate bounds and pre-cancellation are covered.
In-flight cancellation and full600-second native playback remain unproved.
Recorder interaction and live delivery remain open; an offline codec
and synthetic native admission do not establish a completed recorder flow.

### Explicit recorded preparation and native Voice

`TelegramRecordedVoiceIO.prepare(samples:)` is the explicit recording entry point.
It encodes owned PCM, stages `Voice.ogg` in an owned0700 directory/0600 file and
retains strict voice metadata: Int32 sample count1…28,800,000, lowercase plaintext
SHA256 and an explicit nullable waveform. Duration is integral sampleCount/48,000,
including0 for a subsecond recording. Picked Ogg/Opus files remain ordinary files;
container/MIME/name never grants recorded provenance. The existing20MiB encoded
limit applies. This original preparation-only stage preceded the native recorder
connection documented below.

Schema11 accepts exactly one explicit voice item, no grouping, caption, spoiler,
caption-above, source pair or cover. Internal `.file` presentation is its payload
transport representation. Schema1–10 reject voice; their existing meanings remain
supported. Frozen metadata binds the archive record's plaintext digest. Capture,
restore and MediaBox preparation decode actual owned Ogg bytes and compare exact
PCM count/digest, holding a no-follow descriptor and checking source snapshot.
Malformed envelopes are refused before archive capture. Optional waveform, when
present, must be exactly100 packed5-bit values in63 bytes with zero unused bits;
new explicit recordings compute it from original PCM as described below. Existing
null-waveform schema11 preparations remain readable and are not recomputed.

The chat flag selects authenticated encrypted S3 or encrypted local preparation.
OFF forbids every new S3 copy, including this preparation. Local records survive
restart and never promote after re-enable. PostgreSQL stores no payload bytes.
Retry reuses the same record. Native mapping matches pinned
`SenderController.swift:295–312`: `audio/ogg`, only Audio(isVoice:true, integral
duration, nil title/performer, frozen waveform), nil media size, no FileName,
preview, immediate thumbnail, video thumbnail or cover. The local resource retains
its actual byte size. Existing guarded batch admission/ACK retains reply handling.

Real encrypted Postbox/PostgreSQL/S3 regressions restore exact bytes in ON/OFF,
read back native Voice attributes/MediaBox bytes and refuse stale resubmission.
The accepted pointer survives another reopen. Invalid captions and changed PCM
facts create no archive record. Exact main-actor test-fixture and hosted compiler
failures, gates and UI evidence are recorded in development-status.md. There is
no live Account/server, microphone or recorder interaction proof yet.

### Recorded PCM waveform

New explicit recordings freeze100 five-bit waveform values in63 bytes before
staging. The independently authored calculation matches pinned
`AudioRecorder.swift:594–745` and `AudioWaveform.swift:67–85`: preview only complete
960-sample packets, continuous100-sample peak windows, signed-minimum saturation,
and the reference's virtual zero/peak pair positions. Window peaks reduce into
100 bins; normalization sums running maxima, multiplies by1.8/100 and applies a
2500 floor. Integral values clamp to31 and pack least-significant bit first with
four unused high bits zero. The implementation uses fixed100-bin storage and
byte-safe packing; no reference pointer/helper/UI code was copied.

Incomplete encoder packets and the final incomplete100-sample peak window do
not affect waveform. The codec still encodes partial PCM to preserve exact audio
count, an existing independent difference from the reference recorder. Empty,
over600s and pre-cancelled inputs are refused; a complete600s waveform calculation
has a real native regression. This does not establish600s audio playback.

Waveform belongs to original PCM, not decoded lossy Opus. New preparations carry
it through existing authenticated local/S3 storage, schema11 and native Voice
receipts. Capture/restore decode for audio count/digest only and retain frozen
waveform. A native synthetic pulse yields original first value12 and decoded15;
the test asserts exact original bytes survive restoration and native enqueue in
both storage modes. Old explicit null waveform stays null. S3 OFF still forbids
all new copies and enabling later never promotes local preparations. No schema,
dependency, license, microphone action or recorder UI change is introduced.

### Recorded-voice controller admission

The internal `TelegramUploadController.prepareRecordedVoice(samples:target:)`
connects explicit PCM to the existing preparation and native batch queue. It
bypasses picker classification, requires the same-account batch capability and
a valid reply target, and refuses concurrent preparations. Following pinned
`ChatPresentationInterfaceState.swift:284–291`, new recording admission requires
more than25 complete960-sample packets at48kHz (strictly more than0.5s;
the first accepted count is24,960), up to the existing600s bound. The source
recorder passes only complete packets to the writer, whose encodedDuration uses
total_samples/coding_rate. Its pinned iOS `OpusBinding/Sources/opusenc/opusenc.m`
was source-confirmed separately; it is outside the desktop XERJ submodule scope,
where an encodedDuration query returned no match. The codec and schema retain
their previous broader format compatibility and exact partial-PCM preservation;
older explicit short preparations are not reinterpreted or rejected by this gate.

One owned `Voice.ogg` item retains original-PCM waveform, schema11 provenance,
File transport presentation, empty caption and no grouping. Both rich and legacy
caption mutations are refused, including before the encoder publishes its item.
Cancellation releases the voice restriction. Synchronous composer callbacks may
cancel or rebind the account before a worker starts; a stale task cannot publish
its stage. Staged resources retain the existing cleanup/recovery ownership rules.

Voice always requires a durable whole-batch record before `canSend`, even when
the controller's ordinary single-file path is configured without recovery. A
missing store blocks sending. The existing chat flag chooses encrypted S3 or
encrypted local preparation; OFF grants no S3 exception. This entry does not
automatically enqueue. Explicit send uses the complete schema11 native receipt,
and accepted preparations cannot be resent after an encrypted Postbox reopen.

Real controller regressions use native encoding and an isolated encrypted
Postbox/PostgreSQL/S3 stack, replacing only the unavailable server with native
local enqueue. They read back exact MediaBox bytes and Voice attributes, verify
stale context/no-resend and stage cleanup, and prove OFF objects remain absent
after enabling later. Gates and actual UI limits are in development-status.md.
At that controller-only stage microphone capture and recording controls were not
connected. The following stage now connects the native recorder.

### Native microphone recorder and eligibility

`TelegramVoiceRecordingController` owns permission/capture/held/locked/finishing
states. Model, native button and async eligibility use frozen account/chat/reply,
input-context, session and preparation IDs. An old cancelled final eligibility
result cannot enqueue or clear a replacement intent. Context/surface/app removal
cancels both capture and its matching cancelable durable preparation; accepted
native queue state remains governed by existing receipt/recovery rules.

The common empty composer uses hold300ms, inside release to send, outside release
to cancel and upward >100points to lock. Locked cancel confirms against the exact
session; accessible/keyboard activation locks explicitly. Availability and input
context are explicit NSViewRepresentable values, so completion of asynchronous
draft restoration refreshes the native button. A native600s cap ends in durable
preparation requiring explicit Send. Short recordings require >25 complete960
sample packets. Voice has no generic caption/file preview; storage/eligibility
failures remain visible with explicit retry/send/cancel controls.

The model prompts for microphone permission only after the user starts recording;
`NSMicrophoneUsageDescription` is included in the built bundle. Constructing
`TelegramMicrophoneVoiceCapture` has no filesystem/device/permission effect, and
start requires existing `.authorized` status. AVAudioRecorder writes a private
0700-directory/0600-file CAF,48kHz mono signed16 little-endian PCM, capped600s.
After native stop, held no-follow descriptors, directory/file identity/mode/stat,
finite CAF chunks/format/data extent and max28,800,000 samples gate AVAudioFile
utility reads. Positive short reads continue to exact EOF; oversize is refused,
not trimmed. Owned stage is removed on stop/cancel/error/deinit. Crash-time
plaintext-stage collection and forced in-flight native I/O cancellation remain
outside current runtime proof. The DEBUG synthetic capture requires explicit
isolated preview and never requests permission or opens a microphone.

Same-account Postbox transactions read peer/cache plus target-specific unsent
messages for slow-mode channels, using server-adjusted local time. Native user
privacy/block/payment, group membership/bans and channel access/media/boost/
admin/fee/slow-mode rules run before permission, again after permission and before
native admission. Missing required cache refuses. Paid contexts require separate
future explicit payment support; no charge is authorized here. Saved Messages
has no missing-cache exception; secret chat/monoforum are unsupported. The
slow-channel history scan is conservative and currently unoptimized. A fresh
local transaction does not establish current server permission or delivery.

Recorded PCM uses only the existing owned codec, original waveform, schema11 and
durable upload queue. S3 OFF forbids every new copy, including voice preparation;
encrypted local records survive restart and never promote on re-enable. Bytes
are not PostgreSQL payloads. Cancellation does not delete immutable archived
resources. Real isolated encrypted Postbox/PostgreSQL/S3 regressions verify ON/OFF,
blocked final permission with explicit later Send, cancelled eligibility,
replacement ownership, exact native bytes/Voice attributes and no resend after
reopen. Actual synthetic UI, full gate counts, setup failures and remaining
reference/hardware gaps are in development-status.md and reference-interface.md.
No dependency/schema/license/engine recipe or outer reference UI code was added.


### One-time recorded voice

The common locked recorder exposes an optional36-point once control. Selection
is false by default, available only after lock, and frozen before awaited stop.
Cancel/replacement resets it. The desktop pin's SingleTimeControl/VoiceSenderContainer
flow informs the interaction; the independently pinned native iOS recorder supplies
the supported destination gate: another CloudUser, no bot and no paid-message
context. Its presentation state preserves the raw optional price, including zero.
Missing cache, privacy/block and unsupported destinations refuse. Optional once
capability is checked before the final ordinary permission snapshot immediately
before capture. Final explicit send and the native queue transaction recheck once
eligibility; server rejection never retries as ordinary voice.

Ordinary Voice metadata retains its exact three-field representation and schema11.
One-time metadata adds only literal `isOneTime:true`, uses strict schema12 and
requires one voice, empty caption, File presentation, no grouping/spoiler/cover/
original pair. False/null/wrong-type/extra keys and schema11/12 mode mismatches
refuse. Existing schemas1–10 remain unchanged. Frozen metadata travels through
PCM staging, authenticated encrypted local/S3 preparation, restore and MediaBox;
Ogg probing verifies facts without inferring or clearing send intent.

The native request adds AutoremoveTimeoutMessageAttribute(viewOnceTimeout,0).
The pinned enqueue normalizes this to exactly one AutoclearTimeoutMessageAttribute
(Int32.max,nil); the upload request uses ttl_seconds. Receipt acknowledgement
requires that exact post-native lifetime for once, and no Autoclear for ordinary
Voice. Chat-wide Autoremove is independent and may coexist. Missing, duplicate,
changed TTL or an already-started countdown cannot become acceptedBatch.
Prepared restart requires explicit Send; submissionStarted stays uncertain and
cannot resend automatically. Retained preparation shows its frozen once label.

S3 OFF forbids every new copy, including once preparation; authenticated local
records never promote after re-enable. Cancellation, acceptance and remote
expiration do not purge immutable archived resources. The once flag controls
Telegram recipient playback, not Makosh archive retention. Incoming once playback,
real recipient/server execution and microphone hardware are not proved here.
Older binaries refuse schema12: preserve pending pointers, receipts, resources
and encryption keys through rollback. No dependency, license or engine recipe
changes; no outer GPLv2 source/assets copied.

Primary protocol/interaction references: [Telegram's once recording flow](https://telegram.org/blog/new-saved-messages-and-9-more#one-time-voice-and-video-messages),
[uploaded document TTL](https://core.telegram.org/constructor/inputMediaUploadedDocument).
The exact pinned source trace, tests and actual UI limits are recorded in
reference-interface.md and development-status.md.

### Explicit encoded round-video preparation

`TelegramRecordedRoundVideoIO.prepare(bytes:isOneTime:)` admits explicitly authored
MP4 data; a picked square video never becomes a round message through its name or
dimensions. The entry stages exact input bytes in an owned0700 directory/0600
file. A held no-follow descriptor, finite MP4 extents, disabled external/alias
references, complete AVAssetReader decoding and post-read inode/hash checks bind
the returned facts to those bytes. Restore repeats the probe on authenticated
local/S3 bytes. Cancellation removes owned staging; an in-flight native sample
pull is not forcibly interrupted. Decoder cancellation and reads share one actor.

This narrow local admission accepts one square H264 track (side<=1024), one mono
AAC44.1kHz track, raw finished-asset duration0.5...60s and at most128MiB. Decoding
refuses more than7,200 frames or2,647,024 audio samples without truncating. These
are Makosh bounds, not established Telegram server limits. It preserves physical
dimensions and Float32 duration separately from integer native duration, computed
with ceil on the raw full-asset duration. In particular1.00000001s can freeze as
physical1.0s while retaining native2. The desktop recorder instead measures its
audio-end capture timestamp minus writer session start; exact capture-clock
equivalence cannot be recovered from arbitrary finished MP4 data.

Strict schema13 contains one typed round `.video` item, Media presentation,
explicit `isOneTime:false` or `true`, native duration and plaintext SHA256. Caption,
grouping, spoiler, above-media text, cover and original-file pair refuse before
archive capture. Schema1–12 reject round metadata; their previous meanings remain.
Round items cannot project into generic File presentation. Older binaries refuse
schema13, so preserve pending state/resources/keys through rollback.

The canonical native file has only Video(integer duration,200x200,
instantRoundVideo), MIME video/mp4 and size:nil. Local resource size still describes
the exact payload. It has no FileName, Audio, Animated, supportsStreaming, cover or
alternative representation. The mapper permits a valid optional thumbnail; the
durable MediaBox path currently requires its ordinary transformed320px JPEG probe
to succeed. That stricter requirement differs from the reference's optional preview.
One-time round messages reuse frozen max Autoremove→Autoclear(max,nil) intent,
human/cache eligibility and exact native receipt checks; chat-wide Autoremove is
independent. Changed media or missing/changed/duplicate/started media TTL cannot
confirm acceptance. Prepared restore needs explicit Send, started submission
remains uncertain and accepted state cannot resend after encrypted Postbox reopen.

S3 OFF forbids every new copy, including this preparation. Encrypted local payloads
never promote after enable; PostgreSQL stores metadata, not attachment bytes.
Recipient expiration/cancellation does not purge immutable archive resources.
No new dependency, engine recipe or third-party source/assets are introduced.

`TelegramUploadController.prepareRecordedRoundVideo` now transfers explicit bytes
into one durable batch and admits schema13 restore/send. Missing recovery blocks
Send even when general uploads do not require recovery. Caption/options, cover,
item editing, File conversion and generic video preview remain unavailable for
this typed preparation. Synchronous cancellation/rebind cannot publish the probe;
prepared recovery needs explicit Send, and accepted records cannot resend.

`TelegramRecordingKind` keeps Voice as the default. Round selects native
banSendInstantVideos independently of banSendVoice/banSendVideos. Both kinds share
the existing privacy/cache/access/membership/boost/fee/slow-mode policy; once round
also requires another human CloudUser with no paid context. The native enqueue
wrapper checks fresh round rights before insertion in the same Postbox transaction
as receipt persistence, using current wall clock plus the Account network time
offset. Nonfinite/out-of-range clocks refuse. ACK does not repeat the pending-message
scan, which would count this transaction's own new message; it still validates the
frozen draft/media/once/reply receipt. Real local queue regressions cover distinct
bans, privacy/fees, exact slow deadline, prior pending messages and invalid clock.

### Asynchronous round capture in the common recorder

The shared recorder keeps Voice as its initial kind. A short click switches
voice/round; a300ms hold starts the selected kind, upward movement>100pt locks,
and release outside cancels. An accessibility custom action switches kind;
accessibility Press starts and locks. Kind, target, context and optional once mode
freeze for the current recording. Round has its own rights, permission and handoff
closures; voice behavior and its600s cap remain compatible.

Camera then microphone authorization occurs only after an explicit recording
action, with current-context checks before and after each asynchronous prompt.
The capture provider checks existing grants and never prompts. Its native session
configuration/start/cleanup run on a dedicated queue. Start stays pending until
both video and audio have arrived, under a10s startup deadline; cancelling warmup
or navigating away invalidates the capture before a late completion can publish.

An independent owned writer produces300x300 H264/mono AAC44.1kHz MP4. It centrally
crops BGRA input, mirrors horizontally and composites a white circular edge.
Samples use one serial writer queue, bounded input/output and pixel pool, strict
monotonic timing and cancellation. Capture duration uses audio end minus first
video timestamp, with60s sample/wall caps and a2s audio-stall bound. A finished
file still passes the existing full-asset schema13 admission; no capture-clock
equivalence is inferred from arbitrary MP4. Temporary files are private and
owned; cancellation/failure removes staging and refuses later publication.

The central300pt overlay contains a264pt circular preview and281pt/4pt progress
ring while the common composer retains hold/lock/cancel/once controls. A60s cap
prepares the record without sending. Prepared or restored round UI shows the
frozen mode and explicit Send/Cancel. Release/Send rechecks the correct round
rights; changed rights retain the preparation for another explicit action.
OFF remains encrypted local-only and never promotes after re-enable.

DEBUG synthetic QA generates its own pixels/PCM through the same writer without
constructing capture inputs or requesting permission. Its preview is explicitly
labelled synthetic. Native encoding and isolated durable-queue tests do not prove
camera hardware, physical orientation/routes, device throughput, system prompts,
personal Account/server/recipient behavior or minimum26 runtime. Placeholder/shadow
assets, exact modal/gesture parity and cap-time automatic send remain differences; Makosh cap-time preparation requires Send. Finished-file
preview is described below.

For isolated DEBUG screen QA, `--telegram-round-video-qa` can accompany
`--telegram-drafts-synthetic-preview <owned-test-Postbox>` to start with round
selected. It changes only this synthetic fixture's initial kind, never starts a
recording, and does not replace gesture testing. Pending recovery additionally
requires `--telegram-pending-upload-qa`, an isolated `qa_telegram_dossier_` schema
through `--database-config` and explicit `--storage-config`, as before.

### Finished round-video preparation preview

The explicit `openRoundVideoPreview(contextID:)` entry uses the existing native
preparation player. It requires a current ready single-item round preparation;
generic video preview continues to reject typed round metadata. Before attaching
a player, the round path repeats the full schema13 profile, decoded facts and
digest check, then uses fixed video/mp4 MIME and native round-video kind. It
borrows the immutable owned stage, without a new archive capture or S3 copy.

The common Telegram window keeps the264pt circular aspect-fill surface inside its
300pt overlay after recording finishes or prepared recovery succeeds. The capture
progress ring disappears. The player loops silently only in a visible key window,
with external playback disabled. Finished bytes already contain the writer's
mirror; playback does not mirror them again. The frozen once mode remains visible
beside explicit Send/Cancel and is not consumed or changed by local preview.

Cancellation, replacement and stale native views cannot publish or control a
later player. An already-cancelled load cannot detach a current preview. Send,
cancel, rebind and stage release detach the decoder first. Navigation dismisses
the surface; returning can load the retained prepared record again. Preview does
not bypass missing durable recovery, native admission or fresh Send rights.

Normal capture completion drains an already-entered asynchronous source append
before finishing the native writer. Cancelling that append would propagate to the
writer and destroy valid output. The generated QA source stops cooperatively and
waits for its bounded current append/sleep; explicit cancellation still cancels
the writer and rejects late publication. Manual and watchdog regressions hold an
actual native-writer append and require admissible retained bytes after stop.

S3 OFF continues to forbid every new copy; encrypted local recovery never promotes
after enable. This preview introduces no dependency, schema, engine recipe,
third-party source/assets, account access or recording permission change.

### ZIP reservation before storage capture

Ordinary Archive mode now reserves the ZIP/object IDs and installation revision
in encrypted native preferences before capturing storage bytes. The record binds
the full ordinary predecessor digest, ordered member names, ZIP size and plaintext
digest. A reopened Session can resolve/authenticate the same local or stored ZIP
and explicitly retry candidate retention/installation even when the earlier
candidate receipt never committed. If reservation committed before capture,
deterministic rebuilding uses the same reserved IDs. No automatic send occurs.

Native retention and installation require that reservation for new mode attempts.
Changing pointer writes clear it together with existing receipts; restoring an
old UUID cannot revive it. Exact no-ops preserve it. Corrupt/foreign/predecessor-
mismatched reservations, damaged storage receipts and orphan payloads refuse
recapture. Existing unreserved external descriptor paths remain compatible, with
their earlier handoff limitation. Pointer schemas1–16 stay unchanged.

Pending object recovery rechecks the conversation policy. OFF forbids every new
S3 copy, including ZIP/outgoing preparation and retry. Encrypted local records
remain local after enable. Single-Media cover actions follow the reference's
`totalCount == 1` guard; batch cover controls are not a missing migration feature.

## Account settings, local appearance and devices (2026-10-12)

The common workspace opens Telegram settings from its chat-list header. The
existing send-key/photo-size preferences remain shared with system Settings.
Local system/classic/day/night themes and four accents persist in app preferences;
only the selected Telegram workspace uses this appearance. A small MainActor
AppKit observer tracks application effectiveAppearance and explicitly resolves
system mode when leaving Telegram, avoiding a retained SwiftUI window override. No reference source,
assets, API credentials, dependency or engine preparation changes are introduced.

The selected authorized Account binds an independent sessions controller. Opening
Devices performs a bounded getAuthorizations read; closing or account replacement
cancels requests and invalidates captured confirmations. Immutable DTOs retain
current/pending/other devices, native disabled-bit inversion, timestamps and TTL.
Missing/duplicate current devices or hashes and oversized lists fail closed.
Before a mutation, a new list must match the confirmed account/current device and
target identity; terminate-all requires the identical confirmed device set.
Activity timestamps may advance; recreated devices and changed toggle/TTL bases
are rejected. Current-device termination is refused. TTL choices follow the
reference:7/31/93/186days. Picker selection is a draft until Apply and confirmation.

Typed pinned TelegramApi requests perform resetAuthorization/resetAuthorizations,
setAuthorizationTTL and changeAuthorizationSettings. No application-level retry
or flood-wait wrapper is used. A30s controller deadline cancels unresolved work,
marks the account uncertain and refuses another write until explicit refresh.
Closing during a write preserves that barrier across reopening/rebinding. Native
MTProto transport behavior remains upstream; cancellation is not server rollback.
Bool false and empty completion are never successful acknowledgements. Fresh-login
406 termination rejection is distinguished from uncertain transport/server failure;
TTL and acceptance-setting406 errors remain ordinary failures. UI changes
only after an ACK followed by a fresh list, with failure feedback in device details.

DEBUG synthetic workspace fixtures have three in-memory devices and no network
or personal account access. Native UI QA uses a distinct bundle/preferences and
explicit qa_telegram_dossier_ PostgreSQL schema. Session management does not delete
archived messages, change per-chat S3 policy, or store file bytes in PostgreSQL.
Cloud themes, wallpaper/night scheduling, QR linking and web sessions remain
unimplemented. Subsequent settings blocks are documented below. Actual
Telegram device acceptance requires separately authorized real-account testing.

## Privacy audiences (2026-10-12)

The existing Telegram settings opens a privacy overview and dedicated audience
editors for phone visibility/discovery, presence, profile photos, bio, birthday,
group invitations, forwarding attribution, calls and P2P. Discovery and P2P have
separate child pages/RPCs; no compound write claims atomicity across Telegram keys.
Forwarding privacy controls profile attribution, not forwarding permission.
Existing exception memberships are read-only in this slice. A parent draft must
be saved or explicitly discarded before opening its discovery/P2P child editor;
child ACK reloads cannot silently discard that draft. All native user/chat,
close-friend/Premium/bot/deny-contact rules and their order survive audience edits.
Recognized base/fallback rules alone are replaced; nonstandard bases stay read-only.
Malformed lists, nonpositive/duplicate peer IDs and bounded-list violations fail
closed. Phone discovery does not offer Nobody.

Immutable snapshots belong to the selected Account. Confirmation captures the
account/context and exact original rule sequence. A new getPrivacy must match
that basis before setPrivacy. Every preserved user is resolved from that fresh
response; missing/min/duplicate identities refuse the entire write instead of
omitting exceptions. Native typed keys and input rules are used. No application
retry/flood-wait wrapper is installed.30s read/write deadlines cancel unresolved
work; uncertain account barriers survive close/rebind and need explicit Refresh.
Native MTProto transport semantics remain upstream; cancellation is not rollback.
Empty/malformed/mismatching ACKs never report success. An accepted audience and
unchanged exception sequence are required; a fresh full read then updates the UI.
Telegram has no compare-and-swap argument here: another client can still change
rules between the fresh read and write. Category feedback belongs only to its
last admitted write; the uncertain/saving barrier applies to the whole Account.

There are no privacy records in PostgreSQL, file bytes, S3 policy changes, engine
preparation/pin/dependency changes or reference-runtime dependencies. DEBUG fixtures
bind ten in-memory settings to a synthetic Account with no Telegram access.
Native QA uses its own bundle/preferences and an explicit isolated PostgreSQL
schema.2FA, blocked peers, exception membership editing, Premium/voice-message/
global privacy settings and account removal remain open. No real-account privacy
change or private content retrieval is part of local acceptance.

## Privacy exception membership (2026-10-12)

Block7 extends the preceding read-only exception lists with user/group membership
editing. Allow/deny lists use distinct wire identity types; selecting a peer removes
only that peer from the opposite list. Edited membership is bounded, nonpositive/
duplicate identities are refused, and untouched bases/special rules remain intact.
Audience and membership changes share one immutable expected/replacement draft and
one explicit confirmation. Phone discovery does not expose exception editing.
Nested Done only stages a draft; Cancel/Discard and closing never send a write.
Editor basis captures account/context/original rules before interaction; stale
callbacks cannot borrow a later context even when the rule values are identical.
Audience input and membership sheets use that same basis. A draft from another
context is never composed into a new draft.

The account-bound directory reads the selected native Postbox, never system Contacts
or another account. Default candidates are cached Telegram contacts; a query searches
cached contacts/chats.200 results and a has-more notice bound the UI; query length128,
request generations/cancellation and a30s deadline bound its lifetime. Existing
memberships are retained independently of search results, including unresolved names.
Broadcast/secret/departed/migrated peers, self and non-personal/missing user hashes
are unavailable as new candidates. Ambiguous basic-group/channel wire IDs are refused.

Before writing, the exact fresh server rule basis must still match. Preserved and
moved users require hashes from that fresh server response. Only newly added users
may resolve personal hashes from a fresh native transaction; every new group must
still be eligible there. Missing/min/ambiguous additions refuse the whole write.
ACK validation compares the confirmed audience and complete exception sequence;
server normalization that changes that sequence remains uncertain. No automatic
retry, optimistic state, engine/cache update or persistence is added. The existing
account-wide uncertainty barrier and Telegram's lack of CAS remain as documented.

Tests exercise real native peer values and the production directory on an encrypted
Postbox fixture. Synthetic native UI uses its own signed bundle/isolated PostgreSQL
schema with no real account, private contents, network mutation or message delivery.
Global remote peer search, editing special categories,2FA and blocked users remain
open. Permanent message retention, per-chat prohibition of all new S3 copies and
file storage policy are unchanged; no schema, dependency or engine-pin change.


## Block8: blocked cloud users

The existing privacy workspace opens the blocked-user list; the selected user/bot
profile supplies Block/Unblock, following the locked reference's placement. Own
SwiftUI confirms both operations. Cloud groups/channels/secret peers are not
presented as users. Unsupported blocked peer kinds fail the complete read rather
than disappearing from the list. Missing names retain their original user IDs.

Typed `contacts.getBlocked(flags:0, offset, limit:200)` loads all raw pages before
publishing a snapshot. It counts raw records, validates unique positive bounded
IDs, a consistent total, progress, and a10000-record bound. Empty premature or
repeated pages fail. A30s controller deadline cancels the read. This intentionally
uses a complete list instead of reference scroll-triggered incremental display.
Each confirmed mutation independently repeats the complete read and checks the
target's expected membership/account. Unblock uses a non-min nonzero server hash
from that fresh response, without requiring a local peer. New Block resolves a
personal CloudUser identity in a fresh encrypted Postbox transaction. Self checks
compare encoded native identity, including IDs above32bits. The selected profile,
account and captured controller/conversation contexts must still be current.

`contacts.block/unblock(flags:0)` is sent once, without application retry/flood-wait
wrapping. Only typed BoolTrue admits the cache update; BoolFalse, empty completion,
transport ambiguity and write deadline remain uncertain. Cache updates preserve
other CachedUserData fields. No optimistic removal is published; ACK reloads the
list. Closing during a write retains the account's uncertainty barrier until an
explicit successful refresh. The barrier is process-local, as in privacy/session
settings. Telegram offers no CAS; a remote change after the final read can race
the request. Real-account acceptance and behavior of other Telegram clients are
not established by the synthetic workspace or native fixtures.

Block/unblock does not delete any message or attachment, change PostgreSQL schema,
S3 policy, preparation recipe, engine pin or dependency.2FA is described below.

## Block9: two-step verification

The existing privacy workspace opens the selected account's 2FA settings. Native
locked/current-password, management, pending-email, setup/reentry/hint/email,
recovery-code and scheduled-reset states follow the locked TelegramSwift source
(see `reference-interface.md`). Own SwiftUI uses SecureField and explicit consent
for writes; skipping recovery email requires a separate warning. Password changes
omit the email mutation, preserving its confirmed recovery address. Disable,
recovery and reset warn about protected Telegram Passport values when present.
No real account is selected, read or mutated by the synthetic QA workflow.

`TelegramTwoStepController` binds one provider/account. An immutable proposal
captures that account, snapshot and controller context before confirmation; the
native backend repeats `account.getPassword` before every operation. The opaque
basis hashes only the serialized current KDF algorithm/salts, excluding varying
SRP challenges, new algorithms and randomness. Metadata/basis drift fails closed.
The engine then performs its reviewed SRP/KDF/password/secure-secret operations;
Makosh implements no substitute cryptography. Telegram has no CAS for this path:
an external change after the fresh read can race the request.

Password comparison uses exact UTF8 bytes, including confirmation and the engine
result's echo; there is no normalization or trimming. The controller retains the
verified current password only in memory, for at most5minutes on a monotonic clock,
and clears its reference on refresh, close, every action, timeout or failure. A
successful re-unlock rotates context, so old consent cannot borrow a new proof.
Wizard/password/email/code fields and frozen confirmations clear on context change
or dismissal. Inputs have bounded byte lengths and redacted descriptions, are not
Codable and are never written to preferences, Keychain, PostgreSQL/S3 or logs by
this feature. Swift String/reference disposal is not guaranteed memory zeroization;
the native request retains its immutable payload until termination/disposal.

Preparation recipe20 retains the existing pin and adds exact-input/output-hash
GPLv3 adaptations for three native password/email ACK branches: BoolFalse cannot
become success; EMAIL_INVALID/EMAIL_UNCONFIRMED require numeric400 and strict
descriptions, and EMAIL_UNCONFIRMED requires a fresh nonempty pending pattern.
Two password-change reads refuse inconsistent protected-secret presence before
native re-encryption. Unsupported next secure SHA512 is refused before upstream's
precondition. Native cryptographic functions are unchanged. The generated own MIT
ACK/guard helper is linked into GPLv3 TelegramCore. See `THIRD_PARTY_NOTICES.md`.
Preserve a recipe19 preparation under an unused ignored backup name before
regenerating; do not edit ignored generated engine source.

Confirm/resend/cancel email and decline-reset require typed BoolTrue. Recovery
uses `auth.recoverPassword(flags:0, newSettings:nil)` to remove the forgotten
password and admits only a full authorization ACK with the already selected raw
self ID; no recovered login/future-auth token is installed. Reset requested-wait
is displayed as a date, not password removal; completion requires a later explicit
action. While a reset date is present, a native TimelineView recalculates only the
completion button once per second, following the reference's recurring refresh.
The button becomes available when the date passes without manual Refresh or a
server polling request; unsubmitted fields and controller context are retained.
Click/confirmation still require current controller eligibility and a fresh server
snapshot before the write. Time passing never performs a password reset or clears
an uncertainty barrier. All application writes are single attempts without automatic flood-wait
retry. Known RPC rejections require their expected numeric error code; malformed,
false, empty or unknown write results remain uncertain. Every read/action has a
30s cancellation deadline. Closing during a write preserves a process-local
account uncertainty barrier until an explicit complete successful refresh; restart
requires a fresh read. No optimistic account state or automatic resubmission.

The DEBUG-only provider is an explicit in-memory synthetic server fixture with
fake password/email/code. It opens no communication account or Telegram network.
Native fixture tests cover typed wire requests, ACKs, selected-account recovery,
fresh-basis checks, secure-value guards and exact password bytes; controller tests
cover deadlines, rebinding, uncertainty, proof expiry and stale consent. Actual
native synthetic UI QA covers all ordinary forms and confirmation cancellation.
These checks do not establish real-account acceptance, actual Telegram recovery
email delivery, server reset timing or live password/Passport preservation.
No PostgreSQL/S3 schema, permanent message retention or per-chat S3 policy changes.

For DEBUG-only isolated deadline QA, combine `--telegram-dossier-synthetic-preview`
with `--telegram-two-step-short-reset` and an isolated `--database-config`. Only
the in-memory synthetic provider then waits20seconds; ordinary synthetic fixtures
retain seven days. The flag does not configure the native account provider.


## Block11: data, cloud cache and proxies (2026-10-13)

Data and Storage opens in the existing common Telegram settings. Account-scoped
local automatic-download preferences cover photo/video/file size limits and
contacts/other private chats/groups/channels. Master defaults OFF; photos and
videos default10MiB/all peer classes, files default disabled10MiB. These are
explicit conservative differences from the reference's enabled master/unlimited
photos. Settings are versioned, bounded and account checked; corrupt values refuse
automatic work until explicit reset. Frozen editor contexts reject cross-window
changes. This feature does not alter server download preferences.

Actual visible incoming history rows in an eligible native window feed at most
100 candidates/three simultaneous automatic full transfers. There is no offscreen
background downloader in this slice. Fresh encrypted-Postbox transactions check
incoming cloud message, current exact resource descriptor, contact classification,
peer protection and unsupported/spoiler/paid/unknown-size exclusions. The latest
policy, account/history context and native window eligibility are checked again
before fetch and before accepting completion. Leaving a page or disabling the
policy cancels only automatic ownership; manual transfers remain independent.
Manual completion retains its existing archive callback. Before native automatic
fetch, a frozen source identity reserves one of three automatic archive slots;
that budget includes both in-flight admissions and FD-backed pending captures.
The existing eight-manual-capture budget stays independent, bounding total retained
handoffs at11. Unused reservations cancel with their media leases; a valid full
completion consumes its slot synchronously into a retained FD before publishing
Ready. Already granted completions survive intervening archive busy/error states.
Capacity exhaustion pauses new work without burning the candidate; archive changes
wake the queue after a durable handoff or explicit retry. FD-validation refusal
publishes Failed rather than Ready. Both paths use the same per-chat S3 gate.
Enabling auto-download never enables S3; S3 OFF continues to prohibit every new
copy there. Permanent message/version retention is unchanged.

Cache usage is the verified cloud-media subset from native CacheUsageStats joined
to fresh Postbox media/resource identities. It is NOT total application disk use.
Photos/videos/audio/files can be selected; consent freezes the catalogue and byte
estimate. A new scan and transaction must match before removal. Only confirmed
CloudDocument/CloudPhotoSize/CloudDocumentSize/CloudFile IDs pass the allowlist;
local originals, secret/unknown media, other/temp/immutable paths, sessions,
drafts, PostgreSQL and S3 are excluded. Native MediaBox removal uses force:false
and preserves occupied resources. Busy sending/recording/archiving or unconfirmed
file archive state refuses the action. Refresh after removal reports actual
remaining copies, without promising all selected bytes were freed. Unknown or late
results require a fresh scan. Clearing is permanent for those temporary copies;
redownload depends on their continued availability in Telegram. Existing retained
archive objects are preserved; this action does not backfill uncaptured files.
Automatic eviction, duration/size retention, per-chat cache browser and full disk
inventory remain reference differences.

One app-owned proxy coordinator is shared by normal Telegram windows. SOCKS5 and
MTProto profiles are validated locally, at most32, and stored as a versioned,
bounded, nonsynchronizing generic-password Keychain item. Password and secret
fields are secure; summaries and debug descriptions redact credentials. No
Keychain read occurs during ordinary model construction. Explicit opening of the
proxy pane or Connect reads this local configuration. Keychain item revision is a
real generic attribute, conditionally matched by SecItemUpdate; stale writers do
not overwrite a later edit. Locked/corrupt/failed/uncertain storage never silently
selects Direct. Add/connect/edit/remove/enable/disable require frozen explicit
confirmation; removal of the selected server disables proxy without picking
another. Successful local write is followed by runtime configuration ACKs from
all currently owned networks; ACK is not a successful proxy handshake. A30s
unknown/false ACK stops owned connections and requires explicit reread/reapply.
Closing an editor revokes unsubmitted consent but cannot cancel confirmed global
configuration work. No automatic retry is performed.

Recipe21 retains the reviewed engine revision and all cryptography. Exact
input/output hashes adapt only Network.swift/Account.swift and add an own MIT
source helper. A dynamic in-memory Signal supplies both initial and managed proxy
settings; Unauthorized-to-Authorized replacement reads its latest value. The
owned path does not subscribe to AccountManager proxy credential storage, and
disables the upstream proxy-issue probe that creates a direct reference ping.
Disabled settings carry no inactive credentials into the network. MTContext
application is observed on its serial queue before ACK. Existing callers with no
external source retain their previous behavior. Prepared recipe20 and interim
recipe21 trees are preserved under ignored backups; generated source is never
edited by hand. MtProtoKit is the already pinned/reviewed transitive dependency,
now declared directly for native proxy validation. See THIRD_PARTY_NOTICES.md.

Proxy links/import/export/QR, latency probes and proxying calls are not implemented.
DEBUG data-settings providers use synthetic in-memory cache and a separate fake
proxy store in that QA bundle's preferences; they never open Keychain, accounts
or transport. Native tests exercise actual Postbox/MediaBox cloud removal and a
real transport-free MTContext, plus generated dynamic source helpers. These do not
establish login-Keychain permissions, server reachability, live Telegram download
or authentication through a real proxy; those require separately authorized
account acceptance.

## Block12: extended privacy rules and global settings (2026-10-13)

The existing account privacy flow now includes voice/video messages, gift autosave
and paid-message exemptions through their independently typed privacy keys.
Premium allow exceptions are editable only for group invitations, bot allow
exceptions only for gift autosave. Other special rules, identities and relative
order are retained. New special allow rules precede the base; ambiguous duplicates
cannot be rewritten. Fee exemptions retain the Contacts base and existing rules;
new membership still uses the existing fresh native directory/hash validation.
Voice-message writes require known Premium status both at confirmation and in the
fresh encrypted-Postbox transaction that admits the native input rules.

A global privacy snapshot retains the complete pinned wire flags, optional Stars
amount and complete gift flags. Edits cover read-time hiding, incoming Everybody/
Contacts-and-Premium/Stars policies, and allowed unlimited/limited/unique/Premium
gifts. Archive/mute/keep-archive flags, display-gift-button and unknown bits remain
unchanged. Existing fees above a newly reduced limit survive unrelated edits.
Changing a fee requires a positive integral amount within the fresh configured
limit; an absent limit uses the reference10000 default. A configured limit must
be a positive integral JSON number within Int32; malformed limits disable fee
edits. Reference non-Premium restriction availability is read from native app
configuration. Gift type edits require Premium. Choosing Everybody explicitly
clears the Stars fee, as in the pinned reference.

Every global save freezes account/context/original wire settings, repeats
getGlobalPrivacySettings, then reads current own-user/configuration capabilities
from Postbox before a single typed setGlobalPrivacySettings with no application
retry/flood-wait wrapper. Only an exact valid ACK is accepted; missing or normalized/
changed ACKs remain uncertain. Global and selective writes share the existing30s
write deadline, account barrier, explicit refresh reconciliation and post-ACK full
reload. No optimistic update or automatic resend is introduced. Telegram provides
no CAS: another client can still change settings between the fresh read and write.
Closing/cancelling is not server rollback. The barrier is process local.

Own SwiftUI uses the existing common workspace and privacy forms. Read time and
gift types open separate child editors, each with its own save confirmation;
unsaved parent audience/fee drafts block child navigation. Incoming fee exemptions
use the existing peer editor. Invalid amount input disables Save and exemption
navigation; Discard restores the saved amount. Premium/bot
categories are explicit switches rather than invented ordinary peer identities.
Voice restrictions and gift filters are read-only when entitlement is unavailable;
there is no purchase/upsell flow. DEBUG fixtures are in-memory only, with an
explicit --telegram-privacy-basic-fixture for the non-Premium UI path.

No PostgreSQL/S3 schema, file policy, message retention, engine pin/preparation or
dependency change. Account/message auto-removal timers, public fallback photo,
remote peer search and the preceding UI parity gaps remain open.
Local Makosh passcode and automatic app locking are explicitly excluded by the
user (2026-10-13), rather than deferred migration work.
Native fixture/UI checks do not establish live account privacy mutations, Stars
charging or real server normalization; account acceptance is separately scoped.


## Block13 task1: remote peer discovery (2026-10-13)

The existing common global-search view now keeps local dialogue matches first,
then a separate remote-user/chat group. A bounded single text/username query
admits typed contacts.search (limit20),300ms debounce and30s deadline. Archive,
message-only media/scope filters, empty/control-bearing/oversized and #/$ queries
do not initiate discovery. The native boundary preserves errors rather than
converting network failure into an empty list; retry is explicit. Duplicate native
IDs appear once; user/group namespaces stay distinct.

An own MIT cache helper compiles inside independently pinned recipe22 TelegramCore.
It validates bounded native results and required identities/hashes before native
AccumulatedPeers/updatePeers. Invalid/unresolved/min results fail without partial
cache publication. Canonical source and complete prepared-file hashes gate reuse.
Opening freezes account/result context and resolves the current cached native peer
again before using existing conversation/history/draft paths. It never sends,
joins, imports communication contacts or changes archive/S3 policy. Reconnect,
query replacement and disconnect revoke old result authority. The explicit DEBUG
catalog contains synthetic remote Alice/Bob and a deterministic error query;
fixtures never open a real account or network.

Avatar editing, membership workflows, secret-chat expansion and native calls are
subsequent tasks in this same approved block. The existing privacy exception
picker's directory remains local at this slice. Real account/server acceptance is
separate from synthetic/native-fixture validation. See development-status.md.

## Block13 task2: static avatar editing (2026-10-13)

Own profile-photo editing opens from Telegram settings. Permitted group/channel
photo editing opens from the existing profile information editor; public fallback
photo editing opens inside profile-photo privacy for the same account. Native
picker cancellation leaves no draft; immutable selection/crop/rotation/flip yields
up to640px square metadata-free JPEG, with explicit save/remove confirmation.
Only current own identity or fresh group/channel change-info rights admit writes.
Photo basis/account/peer/kind remain frozen; changed basis requires new consent.

Recipe23's own MIT helper exposes existing native multipart upload and bounded
full-response photo conversion. Typed users.getFullUser/messages.getFullChat/
channels.getFullChannel supply fresh basis; own photos.uploadProfilePhoto/
updateProfilePhoto and messages/channels.editPhoto use automaticFloodWait:false.
Multipart progress and empty completion are not ACKs. Partial/min/duplicate/wrong
peer replies cannot authorize success. An exact returned photo identity plus a
fresh full read confirms upload/removal; missing ACK or post-write read failure
remains uncertain. Cancel before commit releases preparation; closing/rebinding
once committed retains a target uncertainty barrier until explicit refresh.

Photo history/export, permanent message retention and per-chat S3 policy are
unchanged; avatar bytes remain bounded transient memory/staging and native upload,
never PostgreSQL byte storage or a new S3 copy. Explicit DEBUG
--telegram-avatar-synthetic-preview uses account101 and native group/channel
namespaces in the common workspace with --database-config isolated fixtures.
It simulates server writes without opening accounts or Telegram network. The
usual preview identity stays-1. Real server/account acceptance is separately scoped.

## Block13 task3: group invitations and administration (2026-10-13)

The existing profile opens Add member, Invite links, Join requests and Recent
actions according to fresh native permissions. Discovery has its own account/
context; selecting a result imports no contact and sends no invitation until
explicit confirmation. A fresh full user, group rights and negative membership
check precede a single native invite with fwdLimit0. Exact missing-invitee privacy
refusal stays explicit; typed InvitedUsers plus fresh membership confirms success.

Active/revoked links preserve native date/link cursors and owner selection for
creators. Creation supports title32UTF16, optional expiry/positive Int32 usage
limit and administrator approval, without paid creation or implicit sharing.
Revoke checks the exact fresh link/owner and typed old/replacement ACK; the
follow-up read must show revoked. Creation redirects to the own active list.
Requests use date/user cursors; filtered rows are revalidated using bounded
unfiltered pages before a decision. Post-write absence requires a complete
unique scan (maximum10k/deadline30s) plus correct membership. Failure/overlap is
never treated as absence. Unknown writes block replay until an explicit fresh
state check; reconciliation cannot prove remote rollback or attribute concurrency.

Native channel admin history preserves actor/date, exact edited text, participant
rights/rank and invitation changes. The complete packet and peer directory are
admitted before cache/journal mutation. Observed deleted/edited message bodies,
attributes/media and CopyProtected metadata enter the durable archive journal
without resurrection in native chat history. Explicit unavailable content never
creates a fake empty archived version. Forum conversion uses fresh native scope.
No SQL byte payload, new S3 bypass, ownership transfer or group deletion is added.

Recipe24 independently generates own MIT peer/admin helpers and extends the
existing hash-checked GPL native retention adaptation. Python preparation/test
processes bypass timestamp bytecode caches after an actual same-second/same-size
stale-bytecode reproduction; no global Python configuration changes. Build/run/
test still use independent pinned sources. Native/local QA and remaining checks
are recorded in development-status.md; real-account/server acceptance remains
separately scoped.


## Block13 task4: native secret-chat workflows (2026-10-13)

A regular person's profile offers explicit secret-chat creation. Fresh full user
and requirement RPCs retain errors; consent freezes account/user/revision before
native createSecretChat. Native signed Int32 secret IDs (including negative IDs)
remain distinct from regular users. The common workspace observes handshake,
active and terminated sessions, public key verification, negotiated layer and
TTL; missing/malformed keys cannot authorize send or timer changes. Unknown
creation/TTL results require explicit fresh reconciliation and never auto-replay.

Formatting uses the pinned native layer encoder admission:8/46 plain text;
73 basic entities;101 underline/strike/noncollapsed blockquote;144 spoiler/custom
emoji with the existing full-document account/Premium checks. Lossy Pre language,
collapsed blockquote and unsupported entity kinds are refused explicitly. Replies
require a current same-secret source with a nonzero native global ID; cloud
selection quotes, forwarding and edit/delete expansion are not enabled here.
Prepared local photos/documents/video/voice/round video use existing resource and
native outbox paths, with checked legacy Int32 sizes and layer-dependent albums.
Cloud-only covers/media spoilers/caption placement are hidden and refused rather
than silently lost. Recording still requires current native participant privacy
and TCC; view-once recording retains its cloud-only contract.

Timer changes freeze session/key/layer/previous value and consent, then enqueue
and verify the exact native Local service message and update peer/state timer in
one Postbox transaction. UI says queued, never remote delivered. Native removal
retains observed secret text, attributes and media references in the permanent
journal. Secret personal files now defaultON; explicitOFF forbids every new S3
copy and preserves earlier archives. No file bytes are inserted into PostgreSQL.
Recipe25 safety/visibility changes and exact hashes are documented in notices.
Synthetic native UI and real local encrypted Postbox/PostgreSQL/S3 fixtures do
not establish a real account handshake, encrypted server delivery or hardware
capture acceptance; those remain separately scoped.


## Block13 task5: native one-to-one calls (2026-10-14)

A private user's chat offers an audio/video call after a fresh full-user read.
An active secret chat calls its regular participant; self, groups, channels,
bots and unavailable/terminated secret targets are excluded. Account-bound
incoming IDs require explicit Answer/Decline; answering a video call with audio
never starts the camera. Native CallSessionManager owns the authenticated key,
versions and signaling. Only real native transport Established marks Connected.
The app advertises the independently built versions2.7.7/5.0.0 and maxLayer92.

AppDelegate supplies one explicit call coordinator to all real workspaces.
Reservation precedes TCC and survives End/rebind/controller retirement until the
native audio and AVFoundation camera both acknowledge release. Context/token
checks reject late callbacks. Camera toggles await actual start/stop and recheck
context. Incoming observation performs no permission request or capture. Native
signaling is bounded to256 packets/1MiB,64KiB each; video retains only latest
bounded NV12 frames. Decoded rotation is applied before display. No call media,
keys, signaling or relay/proxy credentials are logged, recorded, archived or
written to S3/PostgreSQL. Existing permanent message/file policies remain intact.

The native module is built independently from Dependencies/TelegramVoip.lock.json
by scripts/prepare-telegram-voip.py. It compiles the reviewed native tgcalls/OWT
closure and VP8/Opus, has seven own C ABI exports and a private codec symbol
namespace. H264/HEVC/FFmpeg, group calls and screen sharing are excluded. The
existing restricted emoji VP9 decoder is unchanged. An injected audio factory
failure never falls back to physical devices. Unexpected C++ allocation errors
fail-stop at noexcept boundaries rather than returning a false capture-release
acknowledgement; recoverable admission/permission/device failures remain explicit.

P2P denial disables host UDP/TCP and STUN candidates in the real allocator.
An enabled proxy applies to calls too: SOCKS5 requires an advertised TCP relay,
with direct/UDP relay bypass disabled. MTProto-only proxies cannot carry calls;
unsupported combinations fail rather than fall back to a direct connection.
Proxy configuration is reread before wire/capture and monitored during the call.

A separate nonmodal native window shows status, duration, native verification
fingerprint, local/remote video, microphone/camera and End. Closing the window
hides it; the compact bar in the content column of the common workspace reopens
or ends it. Closing the owning workspace ends its call, including a pending
permission step, and retains the media reservation until actual release. Physical
camera/microphone and real Telegram remote-call acceptance remain separately
authorized checks. Local acceptance uses actual encrypted native pairs with
injected PCM/I420 and an explicitly labelled inert synthetic UI fixture selected
with --telegram-calls-synthetic-preview and an isolated --database-config.
