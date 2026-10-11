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
ordered schema6/7 items. Multi-selection, stable-ID reorder/remove, grouping,
later-item covers and whole-set restart use the existing upload state machine.
Grouped visual previews split at10; documents remain individual preview rows.
Existing schema1–5 preparations remain supported. Whole-list presentation and
group eligibility, original-file mode switching and archive preparation remain
open. New picker photo preparations, including single selection, retain both normalized JPEG and a separately
encrypted raw source under schema7. File-mode switching is still pending; it must
use that source, never renamed normalized bytes. Existing schema1–6 photos have
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

Every original payload and accepted cover lives in encrypted S3; PostgreSQL
contains authenticated metadata. The account-bound Postbox pointer publishes the
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

Whole-list presentation/grouping eligibility, reference trimming of unformatted
input and mode/archive normalization remain for step4. Per-item actions are now
bound to stable IDs; native context-menu reorder/remove across the10/11 boundary,
whole-set restart and local queue acceptance are verified. The drag/drop gesture
and reference runtime remain unexecuted.
A whitespace-only leading text is currently rejected by text admission rather
than silently dropped. Later-group actions must use stable item IDs, never the
reference's local-chunk index against the global URL list. Reference runtime and
live Telegram delivery remain separate, unexecuted evidence boundaries.
