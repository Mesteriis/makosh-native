# WhatsApp group workspace native QA — 2026-10-18

Source visual: [third displayed WhatsApp concept](docs/design/whatsapp-group-context.png).
Previous Telegram report: [telegram-folder-qa.md](docs/design/telegram-folder-qa.md).

## Comparison evidence

Source1487×1058; actual native2400×1708 at2×; logical viewport1200×854.
Both are normalized to1200×854 in `.local/whatsapp-layout/comparison-initial.png`
and `comparison-revised.png`; final canonical `comparison-final.png`. Final focused
comparisons: `detail-final-0.png` (chrome
and headers), `detail-final-1.png` (conversation/composer), `detail-final-2.png`
(group context). These combined inputs were opened and visually inspected.
State: synthetic personal account, Groups2, Team selected, right context open,
empty editor. Actual content differs intentionally:32 source participants and
synthetic identifiers/test-pattern avatars, rather than the concept's six invented
people/photos. The fixture has five text observations; no illustrative PDF or
remote delivery receipt is fabricated. Source-owned images use the existing
account/JID/revision/epoch scoped avatar pipeline; unavailable member names use
source IDs and standard native SF symbols.

## Findings and iterations

- Resolved P2, QA002 `initial.png`: short chat aligned at the bottom, leaving a
  large blank region above it. Keep the existing bottom initial offset for long
  history, but use top alignment for content smaller than the scroll viewport.
  QA003 `revised.png` and the revised combined image confirm the correction.
- Resolved P2, QA002: incoming group bubbles lacked sender attribution. Group
  bubbles now display a verified name from this account's chats, otherwise the
  source sender ID. QA003 shows different sender IDs above incoming text; outgoing
  messages retain their original receipt semantics.
- Resolved P2, QA002: context avatar/name stacked vertically and displaced member
  content. The compact horizontal identity row now matches the selected structure.
  Revised context comparison confirms the correction.
- Resolved P2, QA003: composer appeared as a full-width footer rather than the
  inset grouped surface. Native attachment/editor/voice/outbox/send controls now
  share a rounded surface with bottom spacing. Canonical QA004 actual capture
  `whatsapp-canonical.png`, `comparison-final.png` and `detail-final-1.png` confirm
  the fix at the same viewport. All final full/focused comparisons were opened.
  No actionable P0/P1/P2 differences remain within the inspected presentation.

## Required fidelity surfaces

- Typography: native SF text/icons, title/body/caption hierarchy; Russian labels
  readable at the normalized density. Source identifiers replace fictional names;
  sender labels truncate in the middle. No external font dependency.
- Spacing/layout: shared64pt account/filter/search row, three aligned54pt headers,
  350pt adjustable chat list,264pt closable context. Continuous backgrounds and
  transparent resize handle avoid light vertical gutters. The composer is now inset
  and grouped, with its empty-draft send guard retained.
- Color/tokens: shared graphite base, muted violet/indigo light, violet selection,
  outgoing bubble and controls. Native focus ring is intentionally retained.
- Assets: real account-owned avatar loader with bounded encrypted cache; synthetic
  test pattern makes its provenance explicit. Standard SF member icons are used
  where verified human names/photos are unavailable. No fake photographs.
- Copy/content: existing settings/archive/status/new-chat workflows retained. Media
  opens the actual retained media search, not an invented new library. Participant
  count and member roles are provider/fixture values. Missing info has a retry state.

## Native interactions verified on QA003

Groups filter reduces3→2 chats and popup closes. Search reduces2→1 and clear
restores2. Selecting a second group clears the first roster and displays its own
unavailable state. Return reloads32 members; Show all/Collapse works. Context
close/reopen works without changing the chat. Media opens the selected Media
search filter, displays a truthful empty result, and header search close restores
history. Draft entry enables send; clearing disables it; no send was invoked.
Chat settings opens and closes without changing storage/notifications. Archive
shows one archived chat, All restores3. Account switching clears selection,
roster/history/counts; returning restores only that account's list. New chat and
Statuses sheets open/close without creation, QR linking or provider access.

Native popover pixels/keyboard routing and physical splitter drag have prior
CUA limitations; they are not claimed as new visual acceptance. Shared semantic
menu activation was observed closing popups and applying the intended selection.
Common Contacts/dossier-route acceptance remains the prior separate CUA-pipe gap;
it was not retried. No real accounts, messages, calls, microphone/camera or OS
permission changes were used. Ordinary installation was not replaced.

## Final exact-source verification

scripts/dev-db.sh up, scripts/test.sh, scripts/build-app.sh and strict deep codesign
verification exit0. XCTest2872 (WhatsApp142,Telemost74,Telegram2315,Teams108,Mail100,
Core133), one existing microphone-precondition skip, zero failures. Rust58,
Python153/34runs and16 shared-dropdown navigation checks pass. All601 source hashes
match the checkpoint recorded before the Swift suite compiled and checked again
after the canonical build. QA004 is a signed isolated copy with executable text
matching the ordinary canonical bundle. No generated engine source was edited.

Final QA004 also verifies Groups2/selected group/context, attachment-menu open/close,
and draft entry/clear with send enabling/disabling, without sending. Prior QA003
flow evidence remains valid for its inspected controls; its only subsequent source
change is composer presentation. QA004 is left open. Real provider acceptance,
long-name/minimum-window/high-contrast cases and the prior CUA limits are not
claimed. Index freshness is reconciled separately in the development ledger.

## Follow-up polish

Optional P3: a second count badge inside the filter button; the factual count
already appears beside the chat-list heading. Keep native keyboard focus visible.
The concept's enabled empty-draft send/call buttons are intentionally replaced by
the existing capability guards. Source-only metadata and absence of an illustrative
PDF/description are content differences, not fabricated protocol evidence.

## Implementation checklist

- [x] Selected native structure, common tokens and preserved service controllers.
- [x] Initial/revised full and focused visual comparison.
- [x] Synthetic account/chat/filter/context/search/draft/sheet interaction checks.
- [x] Final full suite/build/signature and exact-source reconciliation.
- [x] Final composer capture and combined comparison.

final result: passed
