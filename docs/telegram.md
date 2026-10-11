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
Fresh checkouts prepare recipe 8 directly, retaining the recipe-4 journal,
recipe-5 read scan and recipe-6 enqueue hooks. Recipe 7 adds the hash-checked
cached ID index lookup used by Shift selection. Preserve older prepared source
under an unused ignored backup name before preparing recipe 8. Recipe 8 adds
exact-hash-checked selected-message admission inside native delete's transaction.

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
Secret-chat profiles, animated video avatars, member lists,
administration and other reference profile actions remain open. The static
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
retry without resend. The complete reference send menu, video/album preparation
and live Telegram acceptance remain open.
