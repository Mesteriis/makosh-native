# Telegram folder-rail native QA — 2026-10-18

Source visual: [selected third folder revision](telegram-folder-rail.png).
Previous mail report: [mail-reading-qa.md](mail-reading-qa.md).

## Comparison evidence

Source1487×1058, native2400×1708 at2×, logical viewport1200×854.
Both normalized to1200×854 in `.local/telegram-layout/comparison.png`;
focused chrome/folder/composer comparison is `comparison-details.png`.
Actual current-source QA003 screenshot: `revised.png`; first iteration: `initial.png`.
State: synthetic Work folder, Maria selected, open ordinary dossier, empty composer.
The reference contains an already-linked sample dossier; initial native evidence
shows the truthful unlinked state. It does not invent the sample job/email/notes.

## Findings and iteration

- Resolved P2: native gray rectangular editor did not match the composed field.
  Composer-only AppKit background/border are transparent; the native editor's
  formatting/selection/undo/send logic remains. The shared violet rounded surface
  now groups attachment/editor/emoji/voice controls. Minimum composer text height32pt;
  non-composer editors retain52pt and their native backgrounds.
- Resolved P2: unavailable pagination buttons advertised actions that could not run.
  Navigation/loading/error controls remain visible whenever the actual page permits
  them; an idle complete page no longer displays disabled navigation chrome.
- Resolved P2: dossier stacking consumed excessive height. Avatar/name now share
  a row, with bounded264pt width and the same54pt pane-header baseline.
- Correctness fix: closing the full peer card cancelled the profile observation;
  the open dossier now reloads the current profile after card dismissal.

## Required fidelity surfaces

Typography: native SF14pt message/list text,20pt list heading,14pt pane headings;
  comfortable wrapping, full identity text selectable. Real row previews differ
  from illustrative copy. Native labels and capability states remain readable.
Spacing/layout: same folder/list/conversation/dossier hierarchy and top search row;
 84pt folder rail, resizable320pt list,264pt dossier, aligned54pt headers. No bright
 vertical gutters. The native latest-message anchor deliberately retains the real
 chat workflow rather than freezing the raster's short top-anchored conversation.
Colors: existing graphite/violet WorkspaceStyle and shared backdrop; native semantic
 warning/disabled colors retained. Incoming/outgoing surfaces remain theme-owned.
Images/icons: existing native SF Symbols and account-owned avatar loader/initials;
 no fake photos or rasterized interactive UI. Arbitrary folders get a folder icon.
Copy/content: real account-supplied folder names; unread aggregate counts omitted
 when not authoritative; profile/manual notes shown only with actual ownership.
 The metadata-only synthetic attachment reports its unavailable bytes explicitly.
 The fixture's small safety footer is DEBUG-only and is absent in ordinary accounts.

## Interaction evidence and limits

Eight focused folder tests pass: unfiltered view, category/mute/read/mention rules,
explicit membership/exclusion, pinned/archive semantics, selection/invalid ID,
All/Archive reachability and off-main native page production. Final full gates
are recorded in development-status.md when completed.

QA003 native checks: Projects reduces list to the two matching chats while Maria's
conversation stays open; Work restores five rows. New Chat opens existing peer
search, selecting the already-open synthetic peer closes the sheet and clears the
query. A draft can be entered/cleared without sending. Full profile opens and closes,
then dossier source data is still visible. Creating a synthetic dossier succeeds:
“Источник связан с досье” and Open Dossier replace the repeatable create action.

CUA reports transient AXError.failure on several changing screens; settled reads
confirm the action already completed, so no write was repeated. Open Dossier then
reproduces the existing native-pipe-closed boundary; one fresh read repeats it.
The owned artifact/schema are preserved. That Contacts-route visual acceptance is
unverified, not a product success or a reason to reset data/use another UI backend.
No real-account folders, provider send/download, hardware or OS consent were tested.
Existing live QA remains paused. Popup keyboard and physical splitter-drag gaps from
the prior work remain separate. This is not exhaustive Telegram feature acceptance.

## Final artifact

scripts/dev-db.sh up, scripts/test.sh, scripts/build-app.sh, strict deep codesign
and git diff --check exit0. Full tests:2872 XCTest, one precondition skip, zero
failures; Rust58,Python153/34runs,16 dropdown checks. All463 app/Telegram source
hashes are unchanged. Canonical bundle/QA003/QA004 executable text is identical.
QA004 is a canonical copy with the preserved isolated QA003 database: the linked
contact survives process restart. Native pixels are `telegram-canonical.png`;
no notes, emails or job titles are invented when absent. QA003's source-equivalent
comparison above remains valid; the canonical linked state is compared separately
in `comparison-canonical.png`. Ordinary installation is untouched.

## Follow-up polish

P3: illustrative per-folder symbols/totals, avatar colors, sample header presence and
job/email copy vary from actual account capabilities/data. Native message-author/time
metadata and latest anchoring are retained intentionally. The selected composition
and inspected primary flows have no remaining actionable P0/P1/P2 issue.

final result: passed
