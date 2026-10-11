# Telegram multi-file preparation migration

Telegram stays in the common Makosh service/sidebar/dialog/conversation/dossier
window. The selected reference remains TelegramSwift at the locked revision;
this is a workflow migration, with independently authored native views.

## Current boundary

The picker, upload controller, recovery protocol, provider and transactional
enqueue receipt still carry one file. Step1 below now adds ordered schema6
Postbox/S3 storage and restoration, but the interactive path does not create or
submit such preparations yet. Existing schema1–5 preparations, covered videos,
unknown submission outcomes and immutable archive versions survive the transition.

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

## Open fidelity decisions

Source inspection shows the reference repeats its caption for each ten-item
chunk, reuses entity attributes on empty-text media, and uses local chunk
indices against the global URL list for some later-group actions. Record exact
source evidence and the chosen behavior before send/UI integration. Never copy
indexing mistakes that can act on a different attachment. Reference runtime and
live Telegram delivery remain separate, unexecuted evidence boundaries.
