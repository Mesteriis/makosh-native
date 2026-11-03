# Mail reading-first native QA — 2026-10-18

Selected target: [second mail concept](mail-reading-focus.png).
Earlier shared-shell report: [retained historical report](main-window-qa.md).

## Visual comparison

Source: 1487×1058. Native capture: 2400×1708 at 2×; viewport1200×854.
Both were normalized to1200×854 and inspected together, including focused chrome,
headers and attachment crops. Local evidence: `.local/mail-layout/comparison-final.png`,
`comparison-details.png`, `mail-main.png`, `mail-dossier.png`.
Final canonical-copy QA011 pixels are retained as `mail-canonical.png`; executable
text matches both the ordinary bundle and QA010. The canonical capture reproduces
the reviewed layout with only the synthetic initialization timestamp changed.
The screenshot backend omits the separate popover window; `mail-filter.png` is a
main-window capture, not proof of popup pixels. Dropdown content/open/closed state
and action results are verified through native accessibility.

Implemented hierarchy: section dropdown beside traffic lights, centered title,
graphite titlebar, account/folder/search/compose row, message list and reader,
optional dossier. Shared54pt headers align across panes. Continuous backgrounds
replace light vertical split/inspector gutters. Reader body and adaptive attachment
cards remain readable with the dossier open. Selected-row background is drawn once.

Native symbols and deterministic initial avatars replace generated image symbols.
Unread counts/dates reflect synthetic records. HTML and dossier controls, pagination,
metadata details and adaptive icon actions preserve existing product functionality.
These are intentional native/product differences; pixel equality is not claimed.
No actionable P0/P1/P2 visual issue was found in the inspected mail states.

## Iterations and behavior

User-reported gray titlebar, system dropdowns, mismatched header heights and bright
side strips were addressed. Initial reader body/attachments clipping was corrected
using bounded width and adaptive cards. System List double selection was replaced
by plain selectable rows. Shared dropdowns cover27 menus and40 dropdown pickers;
segmented/radio and context controls remain appropriate native controls.

A real AX activation defect was reproduced: a PrimitiveButtonStyle action was
bypassed while the underlying Button action executed, leaving the popup open.
Dismissal now belongs to MakoshMenuItem's semantic Button action. Final QA010
verifies filter application and reset, each with popup closure and correct list.
Final QA010 also verifies Sent→Inbox and nested account settings→Close.
Navigation-model regression checks cover16 cases including rendered order, wrapping,
selection preference, removed rows, reorder and independent menu state.

Native synthetic QA verifies message reading, aligned headers, dossier open/close,
and accessible split adjustment400→380→400. Earlier iterations also exercise folder
switching, search, reply form, isolated HTML, account settings and outbox; these are
not represented as exhaustive final-version acceptance of every migrated control.
No send, provider session, notification, microphone/camera or private account access.

## Build evidence

Final scripts/dev-db.sh up, scripts/test.sh, scripts/build-app.sh and strict deep
codesign exit0. Tests:2864 XCTest, one precondition skip, zero failures; Rust58,
Python153/34runs and16 dropdown navigation checks. The165 app-source checkpoint
hashes remain unchanged. Build/test preparation uses the existing reviewed pins.

## Limits

Physical divider dragging could not be verified: CUA returned noWindowsAvailable
twice; the accessible adjustment succeeds. Popup arrow-key routing is unverified
because CUA refocuses the main window; model tests do not substitute for keyboard
acceptance. Popup pixels are omitted by this capture backend. Not every dropdown
state across all services has been executed. Earlier synthetic dossier Save transport
failure remains separate; the visible mail dossier presentation now has pixel proof.
Real-account acceptance remains paused. Raw failed attempts and gate logs are retained
under ignored `.local/mail-layout/` rather than relabelled as passing checks.

final result: passed for the inspected mail presentation and pointer/AX flows;
keyboard popup and exhaustive all-service interaction acceptance remain unverified.

XERJ project refresh records exit0 (1532files,1205/1205code). A subsequent freshness
check correctly reports STALE after QA-report edits; final reconciliation is run
with source/docs held unchanged. Aether reference freshness check exits0. Earlier
v24 durable-generation refusal is preserved; v25 uses the prescribed new prefix.
