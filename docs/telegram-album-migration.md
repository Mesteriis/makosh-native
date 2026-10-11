# Telegram multi-file preparation migration

Telegram stays in the common Makosh service/sidebar/dialog/conversation/dossier
window. The selected reference remains TelegramSwift at the locked revision;
this is a workflow migration, with independently authored native views.

## Current boundary

Ordered schema6 Postbox/S3 storage and all-or-cleanup restoration are implemented.
The native batch provider now prepares every resource, verifies original payload
SHA256 before and after the MediaBox copy, derives the complete ordered send plan,
and admits all messages with one transaction and one complete-ID receipt. Both
the Account provider and isolated native enqueue use these hooks. The Account
path observes every queued ID; local acceptance/progress never means delivery.
Unsupported peer namespaces fail before resource preparation. Fresh reply
metadata and every queued reply attribute bind the complete batch to its source
thread, canonical quote and absence of a todo item.

The picker, upload controller, recovery protocol and preparation UI now carry
ordered schema6/7/8/9/10 items. Multi-selection, stable-ID reorder/remove, grouping,
later-item covers and whole-set restart use the existing upload state machine.
Grouped visual previews split at10; documents remain individual preview rows.
Existing schema1–5 preparations remain supported. Schema8 implements whole-list Media/File presentation and
basic grouping eligibility. Schema9 adds strict ordinary-audio/WebP metadata and
native attributes without reinterpreting legacy files. Schema10 adds a separately
retained raw GIF/validated MP4 pair, bound source SHA256/canvas/Float delays and
File/Media projection without recapture. Full upstream classification and archive preparation
remain open. New picker photo preparations, including single selection, retain
both normalized JPEG and a separately encrypted raw source. File mode selects
that source and verifies its digest during native enqueue. Existing schema1–6 photos have
no recoverable raw source unless it was separately retained. Real
Account/network delivery has not been exercised; native queue tests
use synthetic peers and encrypted Postbox.

## Target

Choose several files, preserve picker order and first-occurrence deduplication,
prepare/reorder/remove items, switch media/file presentation and grouped/separate
sending using verified reference rules. Grouped sends divide into at most10
items per group. Caption formatting, placement, spoilers and reply attribution
must reach the intended messages. Stable item IDs connect preview actions,
recovered files, covers and native resources across reorder and restart.

Every original payload and accepted cover is encrypted in S3 when the exact chat
choice permits it, or in the private local spool when disabled. PostgreSQL never
stores file payload bytes; encrypted Postbox pointers contain metadata only. The account-bound Postbox pointer publishes the
whole ordered preparation with one revision change. Failure may retain immutable
objects, but must not publish a partial album. Unknown enqueue outcomes remain
non-resendable. Native admission and receipts must cover all queued messages in
one transaction, rather than acknowledging the first item.

## Ordered implementation

1. Evolve the recovery payload to schema6 with ordered item identities and a
   grouping choice. Preserve legacy codecs, isolate each S3 attachment/cover,
   retain the whole set on caption/cancel/submission writes, and restore all
   items or release every newly restored temporary resource on failure. Existing
   single-file consumers must reject schema6 until their batch path is wired.
2. Build the reference-derived send plan and extend native resource preparation,
   enqueue admission, receipts and observation to every item. Validate exact
   local IDs, resources, group keys, reply and caption/entity assignments. Cover
   boundaries1/10/11/20/21, mixed types, rollback and unknown outcomes.
3. Evolve the existing controller/recovery protocol and picker to ordered items.
   Keep a single state machine for staging, persistence, cancellation and
   submission. Bind reorder/delete/editor actions to IDs, including later groups.
4. Implement the reference preparation UI inside the existing Telegram pane:
   grouped visual preview, file rows, mode/group controls and per-item actions.
   Validate actual pointer/keyboard flows and restart through isolated synthetic
   Postbox/PostgreSQL/S3; no personal account or Telegram network is required.

Each step is intermediate work. Completion requires the whole picker → preview
→ durable preparation → native enqueue → receipt → restart flow, plus the
remaining sequential product migration recorded in development-status.md.

## Validation and compatibility

Use behavior tests before changes, then `scripts/dev-db.sh up`,
`scripts/test.sh` and `scripts/build-app.sh`. Test real encrypted S3 payloads and
real Postbox transactions, including failure on a later item, unchanged
previous pointers, exact restored order/bytes and retained versions. Review a
frozen source snapshot independently. Refresh/check XERJ after tracked changes.
For each changed UI flow inspect the running native app; a build alone is not
runtime proof.

Schema1–5 keep their original resource IDs and representation. Schema6 has one
canonical ordered representation and cannot be downgraded by dropping extra
items. A binary predating schema6 must fail closed on it. Roll back code only
after resolving any pending schema6 preparation; preserve S3 objects and the
pointer instead of rewriting them into a single-file draft. No destructive data
migration or archive-object deletion is part of this change.

Schema7 binds a photo's raw source to `original:<item UUID>`, separately from its
`prepared:<item UUID>` JPEG. All photo items in a schema7 pointer must carry an
original; schema6 cannot carry ignored original references. Reorder, cancellation,
submission and acceptance retain both records. Removing the final source-bearing
item can produce schema6 for the remaining source-free items; immutable S3
objects remain retained. Rollback to a schema6-only binary must leave pending
schema7 data intact and unavailable, rather than dropping its originals.

## Confirmed send behavior and remaining fidelity decisions

At locked TelegramSwift revision579cebbf, PreviewSenderController.swift:1823–1832
moves a nonempty caption to one leading text message for separate multi-media
sends. Lines1890–1898 split grouped sends into ten-item chunks and repeat the
caption for each chunk. SenderController.swift:647–704 assigns one group key per
chunk, consumes the caption on the first interactive visual or last ordinary
file, and places additional text first. Makosh follows this ordering, including
the final singleton chunk, and retains a reply on every resulting message.

Makosh deliberately gives empty-caption media no text entities. The reference
reuses original entity attributes on these messages, which can leave ranges
outside empty text. Empty or100% pending status is not server delivery. A missing
or malformed native acknowledgement after queue insertion remains uncertain;
it does not roll back or justify resending. A durable complete receipt survives
lost callbacks and rejects stale resubmission.

Whole-list Media/File presentation and basic grouping eligibility are integrated.
Reference trimming of unformatted input, the complete ordered source-option fold and recorded voice
and archive preparation remain for step4. Per-item actions are now
bound to stable IDs; native context-menu reorder/remove across the10/11 boundary,
whole-set restart and local queue acceptance are verified. The drag/drop gesture
and reference runtime remain unexecuted.
A whitespace-only leading text is currently rejected by text admission rather
than silently dropped. Later-group actions must use stable item IDs, never the
reference's local-chunk index against the global URL list. Reference runtime and
live Telegram delivery remain separate, unexecuted evidence boundaries.

## Explicit presentation and local-only compatibility

Schema8 stores Media/File alongside the same ordered canonical resources. File
uses raw photo originals and strips active video metadata/cover from the selected
file representation; switching back preserves their canonical records. Media
requires at least one photo/video, and mixed Media cannot group its whole list.
Deleting its final visual item changes the remaining set to File atomically with
its order; previous mode/order/grouping guard the write and exact lost-ACK retry.
Mode and item changes retain the original store and latest caption/options across
rebind, failure and retry; cancellation/newer pointers stay protected.
Strict decoding still rejects externally supplied document-only Media.
Caption placement/spoiler controls remain available for mixed Media independently
of mosaic eligibility. A frozen mode CAS survives navigation/failure and retries
only the original store; cancelled/newer pointers are never revived. Send and
restoration remain blocked while the retained write needs confirmation.

Existing schema1–7 are readable; explicit mode fields cannot hide in older schemas.
An older binary must fail closed on schema8. Resolve pending preparations before
rollback, preserving pointers, local encrypted spool, S3 objects and archive keys.
Mode switches are metadata-only and cannot recapture or promote local resources,
even after the S3 choice is enabled later. Local collection/portable backup remain
unfinished. Current gates and actual native UI evidence are in development-status.md.

## Verified classification contract and next implementation

Source research at TelegramSwift579cebbf0c01fd41b712eff3647fa7f69db9665d
confirms that option eligibility, grouping, generated payload kind and File/Media
presentation are separate decisions. `ThumbUtils.swift:222–260` scans current
original URLs in order; images failing NSImage logical-size/decode checks contribute
no option, and exact WebP removes already accumulated Media. File always appears
in the menu; initial Media additionally requires `asMedia` and exactly `[Media]`.
`CoreExtension.swift:2953–3015` probes attributes with `inCollage=true`. Ordinary
audio is music; GIF/silent MP4 do not get Animated in that probe. Singleton
preparation can also have `inCollage=true`, independently of actual send grouping.

| Original input | Reference native behavior | Required owned pipeline |
| --- | --- | --- |
| GIF | Media: H.264 MP4, Video wire duration0/flags[], Animated only when not inCollage. File: original GIF. | Bounded frame/timing decode, independent conversion, separately retained raw and transformed digests; actual MP4 duration separate from wire duration. |
| WebP | Original bytes, ImageSize/FileName/Sticker even in File; grouping disabled. | Verified bounded decoder and explicit first-frame dimension policy; no JPEG replacement or inferred animated sticker. |
| Ordinary audio | Original bytes, Audio(isVoice:false) with integral duration/title/performer even in File. | Validated AVFoundation duration and bounded tags, retained through native enqueue and restart; OGG/Opus filenames never imply voice. |
| Recorded voice | Explicit recorded provenance, Ogg Opus, Audio(isVoice:true), waveform. | Reviewed codec, original-PCM waveform, ordinary schema11/one-time schema12, native capture and authenticated local/S3 recovery implemented; exact overlay parity remains open. |
| Recorded round video | Explicit recorder intent, original MP4 and Video(ceil duration,200x200,instantRoundVideo). | Encoded H264/AAC entry, strict schema13 controller prepare/restore/explicit Send, authenticated local/S3 recovery and atomic native round ACL/queue/reopen implemented. Camera/common recorder/model/UI remain open; full-asset timing is an explicit local policy. |

Ordinary music now has a verified owned pipeline for synthetic WAV, tagged M4A
and ID3 MP3. Schema9 carries exact duration/title/performer through File/Media
projection, policy-aware storage, byte re-probe, MediaBox and complete native
receipts. Generic legacy files never acquire music metadata from their suffix.
When any item is typed music, File grouping requires every item to be typed music;
a generic `.wav` cannot join it by name. The full ordered classifier above remains
open, including ordinary OGG/Opus. Explicit recorded provenance now uses schema11.

WebP now has a strict schema9 owned original pipeline too. Content-derived
ImageIO inspection proves bounded frame0/canvas dimensions for static and animated
inputs, including a partial first frame. Native ImageSize/FileName/Sticker order,
canonical MIME, forbidden grouping, independent restore re-probe and original
local/S3 bytes are covered through native queue receipts. Exact RIFF length,
20MiB/8192-axis/40M-pixel/256-frame limits deliberately refuse unsafe input instead
of inventing upstream512×512 fallback dimensions. The separate optional320px
JPEG transport preview is regenerated from authenticated original bytes in
MediaBox, with complete native receipt checks. The whole-list option fold remains
open. The local native proof is on
host27; minimum26 runtime is separate evidence.

GIF now uses an owned ImageIO/AVFoundation codec: bounded source
canvas/Float delays, independently staged H.264 and real decoded pixel/PTS tests,
including disposal2/3 and a single frame. Raw GIF remains unchanged. Strict schema10
binds separate encrypted raw/transformed records to the source hash and facts;
both storage policies, retry, File/Media and whole-pair restoration are implemented.
Native Media uses measured MP4 bytes with wire duration0; File uses the raw GIF
with image/gif/ImageSize independent of its suffix. An optional raw frame0 JPEG
is regenerated only in MediaBox; complete native receipts cover its distinct ID
and representation flags. No new S3 copy is permitted while the chat flag is off,
including outgoing preparation; local pairs are never promoted on re-enable.
Recorded voice now has an explicit typed PCM entry, strict schema11 digest/count
binding and native Voice mapping. Both storage modes and encrypted Postbox reopen
are covered without a microphone. New recordings freeze the reference's100-value
5-bit waveform from original PCM through native enqueue; old nullable schema11
waveforms remain readable. Native microphone capture and held/locked/cancel
controls now connect this path; full recorder parity remains open. The prepared engine
a24bbe45f9861f736a79916a50898512f751e0dc exposes native attributes but does not
currently expose GIF conversion or Opus products. Its WebP helper is not adopted;
Makosh uses the independently verified Apple decoder. UIKit wrappers
and the outer GPLv2-only UI remain reference material. New codec source/build
recipes and their licenses must be reviewed and pinned independently; generated
engine files and `.references/` cannot become build dependencies. Apple decoder
availability must be proved with real fixtures before selecting it as a substitute.
Music tag helper source returns both strings even when empty; its apparent
nil-based filename fallback is not evidence of effective empty-tag behavior.

Literal whole-list cases to retain in regression coverage:

| Input in order | Source options | Initial asMedia mode / grouping |
| --- | --- | --- |
| Valid PNG, valid decoded WebP | File (WebP removes Media) | File / off |
| Valid decoded WebP, valid PNG | Media (PNG re-adds it) | Media / off |
| Undersized PNG, valid PNG | Media (first image contributes nothing) | Media / on |
| GIF, valid PNG | Media | Media / on; preparation suppresses Animated |
| Ordinary MP3, ordinary OGG | File | File / on; both music |
| Music, document | File | File / off |
| AVI/MKV alone | File | File / eligible |
| Valid PNG, AVI/MKV | Media then File | File / eligible; explicit Media generates video too |

The existing static-image step now uses source logical size and retains its
no-follow/byte/pixel/frame safety bounds. It does not implement this whole-list
table. Existing strict schema8 normalization after removing the last visual is
retained; upstream may leave unavailable Media/stale grouping after removal or
reorder. Do not serialize invalid Makosh state to reproduce that upstream quirk.

Continue in this dependency order:

1. Extend strict typed metadata/schema9–11 while preserving schema1–8 meanings.
   Separate source facts, canonical payload and raw projection; reject unknown,
   missing or cross-kind metadata. Never reinterpret legacy generic files from
   suffixes. Bind source facts to stable item ID, owned raw size/digest and resource
   role, including logical image eligibility independent of JPEG pixels.
2. Extend the owned music probe with the remaining byte probes and typed transformations. Music and WebP retain
   original bytes; WebP's separate optional first-frame320px JPEG transport preview
   is now regenerated from authenticated bytes in MediaBox only. GIF now retains
   both original and validated MP4 with a separate optional raw-frame JPEG. Explicit voice
   now has a reviewed offline Opus/Ogg codec, original-PCM waveform and durable
   native path through the preparation controller, with strict >0.5s new-recording
   admission and durable native enqueue. Native capture, peer/slow-mode gates and
   common-window hold/lock/cancel now connect it. Full visual/gesture parity,
   end-file round preview, hardware and server proof remain open. Bound frames, dimensions,
   duration, tags, output, cancellation and source mutation before publication.
3. Extend existing policy-aware capture and all-or-cleanup restoration for every
   typed resource. Off remains encrypted local-only; mode edits never recapture.
   Re-probe restored bytes against frozen metadata and retain exact hashes/order.
4. Map exact native attributes/resources in both presentations. Extend complete
   FIFO MediaBox readback, admission equality and transaction-bound receipts.
   Test mixed/chunked sets, raw/converted bytes, missing/extra attributes, partial
   failures and no-resend state using actual native enqueue/reopen.
5. Reduce ordered frozen source descriptors into options/default/group controls.
   Preserve previous/new ordered IDs, mode/group CAS and original-store detached
   retries across rebind, lost acknowledgement, cancellation and newer pointers.
6. Implement real Archive mode using original dependencies, explicit basename
   collision/failure/lifetime rules and restart recovery. Inspect remaining
   archive/caption helpers, then implement unformatted-only trimming, caption
   capability, slow-mode archive forcing and relevant peer control gates.

Completion needs the full native picker/preview/durability/enqueue/receipt/restart
flow for each supported type, full gates and actual owned UI. Reference source
research, offline codecs and synthetic local acceptance do not prove Account
network transformation, server acceptance or delivery. Remaining Telegram and
other services still follow the sequential product migration.


One-time recorded Voice now uses strict schema12 while ordinary Voice keeps11.
Its frozen true-only metadata binds native media TTL through restoration and the
complete queue receipt; ordinary chat auto-delete stays separate. OFF forbids all
new S3 copies. See telegram.md and development-status.md for supported targets,
compatibility, raw RED/GREEN checks and current UI/server limitations. Full round
preview parity, remaining classifier order, Archive/caption normalization and sequential migration
remain open; this is not completion of the full Telegram migration.

Explicit encoded round-video now uses schema13, its own native mapper and durable
controller preparation/restoration/explicit Send. Fresh native admission selects
banSendInstantVideos independently of voice/ordinary-video bans and checks current
privacy/fees/slow mode before insertion in the receipt transaction. ACK excludes
the pending scan of its own insertion. Picked square files still never infer round.
The async camera+audio provider now waits for both sample formats, owns timeout/
cancellation and feeds an independent300-square mirrored/circular H264/AAC writer.
The common recorder/model handles short-click kind selection, hold/lock/once,
permission/context cancellation, durable handoff and retained explicit Send UI.
The60s cap prepares without automatic send. OFF/no-promotion and immutable retention
remain. Actual UI checks and full gates are recorded in development-status.md;
reference modal/end-file player parity, physical hardware/routes/orientation,
server/recipient and minimum26 proof remain open. Next complete round preview
parity, then ordered classification and Archive/caption normalization. See
telegram.md and reference-interface.md for the strict profile and differences.
