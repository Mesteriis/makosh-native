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
Fresh checkouts prepare recipe 6 directly, retaining the recipe-4 journal and
recipe-5 read scan. Preserve older prepared source under an unused ignored backup
name before preparing recipe 6.

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
Reply quotes/forward state and topic-aware edit navigation remain open.
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
