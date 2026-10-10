# Development status — 2026-10-10

## Historical contact-book slice

Native SwiftUI/AppKit contact workspace, PostgreSQL persistence, contact create/edit/search, multiple phones/emails, organization/title/tags, notes, provenance, schema-1 JSON import, reasoned duplicate queue, explicit merge and guarded undo. Communication sections truthfully remain disconnected. Telemost provides an official-link browser handoff; no account/API integration is claimed.

The project started in an empty directory. The user selected the separate public repository `Mesteriis/makosh-native`; the existing `Mesteriis/makosh` is outside this task. PostgreSQL superseded the unpublished SQLite prototype at the user's request.

## Decisions and execution

1. Eight references cloned at exact locked SHAs, license/build/auth boundaries inspected, and real XERJ searches checked against source. Coverage and skips are in `xerj.md`; reference applications/dependencies were not built or authenticated.
2. Independently written MIT Swift domain core with libpq. PostgreSQL 18.6 development container, digest-pinned official image, localhost-only port and persistent named volume. One JSONB aggregate uses a transaction and row lock; this deliberately serializes writes and needs future measured scaling work.
3. Source/account/external-ID identity uses exact UTF-8 bytes. Manual overrides and observations survive imports. Merge retains source identities and snapshots; monotonic revisions prevent unsafe or stale undo.
4. Native shell/editor/import/dossier/merge review implemented. Real UI checks led to an appearance-aware background, an explicit AppKit JSON panel and an item-driven merge confirmation requiring survivor selection. Local bundle links Homebrew libpq; it is ad-hoc signed and is not a standalone notarized distribution.

The contact-only baseline declared macOS 26.0 and Swift tools 6.0; Telegram now requires Swift 6.2 (Xcode 26+) for isolated lifecycle teardown. Local verification used arm64 macOS 27.0.1, Xcode 27 and Swift 6.4. Minimum deployment configuration does not prove runtime acceptance on every supported OS.

## Actual checks

- `./scripts/dev-db.sh up`: exit 0, healthy PostgreSQL 18.6. A synthetic SQL probe survived `down` and `up` (container recreation) in the named volume; probe schema then cleaned. Credentials are generated in ignored mode-0600 files and are not tracked.
- `./scripts/test.sh`: exit 0, **24 XCTest tests, 0 failures** against real PostgreSQL. Coverage includes persistence across connections, concurrent writes, atomic validation/trigger-induced rollback, unsupported schema preservation, opaque Unicode identities, import idempotence/manual overrides, candidate reasons, lossless merge, reimport routing and undo conflicts/ABA protection. The shipped three-contact synthetic fixture also passes import → merge → reimport → undo → reopen.
- `./scripts/build-app.sh`: exit 0 after the final UI fixes; executable and local `.app` built, ad-hoc signing and strict signature verification succeeded.
- Python syntax, shell syntax and staged diff checks passed. Tracked-file audit excludes clones, indexes, database/configuration files and generated credentials.
- Two scoped read-only reviews found and fixed CI password masking and the UI refresh-after-commit retry hazard. Domain transaction review and the final four-file UI/documentation diff review found no further actionable defects. This is bounded review, not a security certification or crash/network fault campaign.
- XERJ final project refresh after the UI fixes: exit 0, 35 indexed files, 21/21 classified code files. Real queries retrieved PostgreSQL parameter/row-lock code, merge/undo definitions, the current `chooseImportFile` and item-driven merge sheet, confirmed against source. All nine scope fingerprints (own project plus eight references) are current; completed runs with explicit skips retain exit 3 and are not relabeled clean.

## Native UI evidence and remaining limitation

Real app accessibility state showed the PostgreSQL workspace and empty list. The create sheet was opened and all synthetic fields were verified (including two phones, email and tags). Save was invoked; a subsequent database query confirmed exactly one synthetic contact in the isolated QA schema. A fresh bundle using the final built executable payload reopened that schema and visibly listed the expected contact and organization. The QA bundle changed only identifier/display name/signature; executable payload equality was verified after removing signatures from temporary copies.

In the normal development schema, the actual native JSON panel imported the shipped fixture: three contacts, one email/phone duplicate pair, with the unrelated same-name person kept separate. Reimport reported 0 created / 0 updated. The comparison sheet visibly showed both full cards and source identities. An explicitly chosen survivor produced two cards, zero candidates and a journal entry; this state persisted after restarting the app. Reimport after merge again reported 0/0 and kept two cards. UI undo marked the journal entry undone and restored the candidate pair; restarting visibly restored all three cards. The final confirmation button was observed disabled without a survivor and enabled only after explicit selection; Cancel preserved the pair. Search by the synthetic company's name visibly filtered the list to one contact. Actual screenshots verified the dark workspace, comparison and undo journal.

The computer-use bridge intermittently returned `Sky Computer Use native pipe closed before response`, especially after closing the outer sheet and selecting a dossier. App processes remained running; restarting the task-owned app restored initial observation and allowed the import/merge/undo checks above. **GUI editing and adding a dossier note remain unverified because the bridge fails on dossier selection.** These behaviors pass core tests, but those tests do not substitute for the missing UI acceptance. Light appearance, resizing/accessibility matrices and network/crash fault campaigns are also unverified.

## Publication and next stage

Published public repository: [Mesteriis/makosh-native](https://github.com/Mesteriis/makosh-native). First commit `dbca5b0095f50889c0cd91dadb63557e387807b5` passed the actual [macOS Actions run 38049878040](https://github.com/Mesteriis/makosh-native/actions/runs/38049878040): build and 24 tests, 0 failures, on `macos-26`, Xcode 26.6 / Swift 6.3.3. CI uses an isolated native PostgreSQL server on the hosted macOS runner (Docker is the local development service); credentials are generated per run and masked before entering step environments. The subsequent UI fixes have passed local build and focused native UI checks. For later commit-specific CI results, consult the [actual Actions runs](https://github.com/Mesteriis/makosh-native/actions/workflows/ci.yml); this ledger records completed checks at the time of its commit.

The following Telegram stage implements the selected real engine. Contact GUI edit/note acceptance remains limited as recorded above. Mail/WhatsApp/Teams sync, contact export/backup, normalized SQL tables and standalone dependency packaging remain future work.

## Telegram first channel — 2026-10-10

Implemented `MakoshTelegram` over the actual TelegramSwift iOS engine gitlink
`a24bbe45f9861f736a79916a50898512f751e0dc`, with original native SwiftUI setup,
phone/code/password forms, root chat list, recent text history and text composer.
PostgreSQL still owns contact dossiers; encrypted Postbox/SQLCipher is only the
Telegram protocol/session cache. No existing client session or private messages
were read. Optional locally imported API settings are loaded only by an explicit
Connect action and are never displayed or published. No real account login or
message send was performed.

The fork pin's entire tree is byte-identical to official ancestor
`0699602bbc2756d1feaeb67df485e376dce44ad2`; all selected 21 SwiftPM packages
were audited. The official iOS GPLv2-or-later grant permits selecting GPLv3 for
the combined app; outer GPLv2 macOS UI is excluded. Full license texts and
retained notices are tracked in `LICENSES/`, with provenance/build adaptations
in `THIRD_PARTY_NOTICES.md`. Own Makosh code retains MIT. No binary release is
published; libpq/OpenSSL remain local dynamically linked dependencies.

Actual checks:

- `scripts/prepare-telegram.py`: exit 0; 21 packages and 1,333 prepared files,
  committed-source-only extraction, pinned official FlatBuffers 24.12.23 built
  locally, generated serialization sources, exact prepared file-set/checksum
  verification on reuse. Session data is untouched by preparation.
- `scripts/test.sh`: exit 0, **43 XCTest tests, 0 failures**: 24 contact tests
  against real PostgreSQL plus 19 Telegram configuration, challenge mapping, draft, crypto,
  logging and credential-file tests. Genuine OpenSSL provider modular arithmetic
  and binary roundtrip tests execute successfully. Synthetic file tests reject
  permissive modes, symlinks, invalid/oversize JSON, directories and FIFOs.
- `python3 scripts/test-telegram-preparation.py`: exit 0, **8 tests** covering
  untracked-source exclusion, extra/changed/missing-file detection, unsafe tar
  members/cache symlinks and credential import selection/no-eval/no-overwrite.
- `scripts/build-app.sh`: exit 0; complete real-engine app linked and local
  bundle ad-hoc signed/strictly verified. Initial integration failures (missing
  generated FlatSerialization, then logger/lifecycle review issues) were fixed;
  failed probes remain recorded locally and are not represented as passing.
- Real native app showed the Telegram setup with secure hash field, explicit
  connection action and unofficial-client notice. Deliberately invalid synthetic
  API values were rejected before account work, the secure field cleared, and
  Stop returned to configuration. The final rebuilt app visibly offers saved-data Connect with empty manual fields; the imported values remain hidden and that action was not invoked. No real API values were shown in UI testing.
- Scoped same-model reviews identified/fixed untracked source injection,
  cross-chat draft loss, missing mandatory engine logger, stale authorized
  subscriptions/previews and missing deinit disposal. Follow-up source reviews
  found no additional actionable issue in the corrected scopes. Observed model
  metadata/usage are unavailable; reviews are not quorum votes or independent
  runtime auth acceptance.
- Final engine XERJ scope: exit 0, 721 files, 686/686 classified code; actual auth
  queries resolve to current `Authorization.swift`. Source preparation and index
  freshness were checked. The original project prefix refused the new license notice schema (exit 1); a separate `mk-own-v2` refresh then completed with exit 0, 62 indexed files and 37/37 classified code files. Actual own-source queries resolved the credential loader, explicit saved-data action, lifecycle cleanup and draft acknowledgement. All ten fingerprints (own project, engine, eight references) are current. The mutable status ledger is deliberately outside its scope.

Runtime limits remain explicit: login, incoming sync, server delivery, reconnect,
real cache-corruption handling, 2FA and account-state transitions require a
user-connected test account and separate live acceptance. Main list/history are
bounded to 50 entries; pagination/media/secret-chat UI/read receipts and dossier
identity linking are not implemented. Drafts persist only in this app process.
See `telegram.md` for actual behavior, local credential configuration and limits.
The Telegram head `b6c50add915b07cffd87c751c926f6ea8eccedae` passed actual
[PR CI 38054159972](https://github.com/Mesteriis/makosh-native/actions/runs/38054159972):
build, 43 XCTest tests and 8 Python regressions. This is evidence for that head;
later changes require their own CI result.

## Build independent of research folders — 2026-10-10

Makosh now owns `Dependencies/TelegramEngine.lock.json`, a separate bare source
cache in `.local/telegram-source.git`, and the adapted SwiftPM engine packages.
The audited revision/tree and generated engine content are unchanged. Build,
test and run neither read nor create `.references/`. Research preparation and
indexes remain optional tools. A verified prepared engine is checked before any
source-cache/network access; a changed cache fails closed. Account/session data
and PostgreSQL storage are outside this change.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; existing PostgreSQL development service healthy.
- `scripts/test.sh`: exit 0, 43 XCTest tests (19 Telegram + 24 real-PostgreSQL
  contact tests), 0 failures; 15 Python regressions passed. New checks cover
  independent bare-cache fetch/reuse, tree mismatch, atomic source publication,
  source symlinks/replacement refs, full prepared pin and offline reuse.
- A separate source snapshot contained only publishable project files, no
  `.references/`, prepared engine, source or compiler cache. It downloaded the
  locked source and compiler itself. Its first preparation exposed a missing
  marker-variable binding (exit 1); that failed log and unmarked output were
  preserved. After correcting the producer, build and strict ad-hoc signature
  verification passed with `.references/` still absent.
- In that separate copy, the bare source cache was temporarily moved aside and
  HTTP(S) proxy settings pointed to a closed loopback port. Repeat app build and
  all 43 XCTest/15 Python tests passed without recreating either `.references/`
  or the source cache. The preserved source cache was then restored.
- Prepared file sets/checksums match the prior audited 21-package engine exactly.
  Binary load commands contain no reference/legacy-directory dependency. Python/
  shell syntax, build-path exclusion, lock provenance consistency and diff checks
  passed. No product UI/account flow changed; no account authorization or private
  message acceptance is inferred from these build results.
- XERJ v2 rejected the lock file's new JSON fields (actual exit 1, preserved).
  Following its diagnostic, a separate `mk-own-v3` refresh passed: exit 0,
  63 indexed files, 37/37 classified code files, including the dependency lock.
  Current preparation/pin queries were confirmed against source; engine content
  and its existing scope fingerprint remain unchanged.

CI now explicitly checks that `.references/` is absent before/after the cold
build and after tests, and verifies the separate bare source cache. Adding these
gates does not itself establish a hosted pass; consult this change's PR check.

The independent-build head `25e05c04b86ba46e1e20c53c78b14c763bc3472a`
subsequently passed [PR CI 38055123194](https://github.com/Mesteriis/makosh-native/actions/runs/38055123194):
cold build without `.references/`, 43 XCTest tests and 15 Python regressions.

## Telegram pagination and archive — 2026-10-10

Dialogs, archive and message history now use live Postbox cursor windows with
older/newer/latest controls. The requested batch size is 50; around-anchor
windows can overlap and contain entries on both sides. No fixed first-50 limit
remains in the adapter. Selected chat and account/chat drafts survive list-page
and folder changes. Each replaced request has a fresh token; account/chat
generations and token checks reject delayed emissions, including same-anchor
retries. Empty loading snapshots retain displayed data, stable empty snapshots
clear it, and each loading period has a 30-second UI deadline. A timeout keeps
the live subscription and permits explicit retry or subsequent recovery.

Source inspection for the next media stage also found the missing
`setupAccount(account)` call. It now installs TelegramCore's built-in MediaBox
fetcher on the authorized account. Its defaults do not supply cached image
transformations; no media UI or successful download is claimed here.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; healthy existing PostgreSQL Docker service.
- `scripts/test.sh`: exit 0, **54 XCTest tests, 0 failures** (24 real-PostgreSQL
  contacts + 30 Telegram), plus **15 Python regressions**. Eleven new tests cover
  cursor boundaries/duplicate anchors, stale callbacks/reset, loading/timeout
  recovery, independent windows, traversal beyond 50, archive, selection/drafts,
  stable-empty versus loading-empty data, and synthetic isolation.
- `scripts/build-app.sh`: exit 0, complete app built and strict ad-hoc signature
  verification passed. The first pagination build failed Swift 6 concurrency
  checking for a non-Sendable static navigation value; adding Sendable to the
  immutable value fixed it. Failed and successful logs remain local.
- Actual separate native QA bundle visibly showed a synthetic badge, main list
  beginning at dialog 51 after paging, archive ending at dialogs 51–65 with
  older disabled, history moving from messages 120–130 to 31–41 then 1–11,
  older disabled at the beginning, newer and latest restoring later windows.
  A selected dialog/history and entered draft remained when the list moved to
  a page without that row. Sending and account connection were disabled. The
  preview bypasses the PostgreSQL workspace and uses only in-memory data.
- Two scoped same-model read-only reviews checked engine cursor/holes/lifecycle
  and preview isolation/tests. A release-test compilation gap was found and
  fixed by guarding DEBUG-only fixture tests with DEBUG. Other reviewed paths
  had no confirmed findings. Root confirmed the engine source and owns build,
  test and GUI evidence; observed worker provider/model/usage remain unknown.
- Final project XERJ refresh: exit 0, 69 indexed files, 42/42 classified code.
  Current receiver/deadline/fixture query results were confirmed against source;
  project and engine scope fingerprint checks passed.

The preview, fixture and its model tests are DEBUG-only. A release build was not
run. Real account authorization, server-side pagination/hole filling, incoming
sync, delivery and media remain unverified. Search, media/file UI, message
actions, dossier linking and the other service transfers remain open in
`migration-plan.md`; this slice does not complete the user's active goal.

The pagination head `616a2e91d0818f917e4bdc330c8ce4105416e2df` passed
[PR CI 38056547261](https://github.com/Mesteriis/makosh-native/actions/runs/38056547261):
reference-free cold build, 54 XCTest tests and 15 Python regressions.

## Telegram search — 2026-10-10

Native chat search covers known Postbox dialogs in the selected main/archive
folder beyond the displayed page; it is cache-local and does not discover remote
peers. Per-dialog message search uses TelegramCore, accumulates cursor pages,
shows a total and offers an explicit history jump. Query/chat/account changes
cancel requests and invalidate tokens. Search has separate loading, ready,
failed and timed-out states. Failed pages retain results and the last successful
cursor; successful zero matches are distinct. A bounded recipe-3 adaptation
uses exact input/output SHA256 and counted contexts to keep RPC failure from
becoming an empty completed result. Either migrated-peer RPC failure retains
both cursors atomically. Hashtag search and local secret/saved-reaction branches
remain unchanged. History jumps accept associated migrated history while
checking the active search's chat; that real-account case is not runtime-tested.

Actual checks:

- `scripts/dev-db.sh up`: exit 0, existing Docker PostgreSQL healthy.
- `scripts/test.sh`: exit 0, **73 XCTest tests, 0 failures** (24 real-PostgreSQL
  contact tests and 49 Telegram tests), plus **18 Python regressions**. The 19
  new Swift tests cover engine failure reduction/equality, cursor preservation,
  stale requests, debounce cancellation, page accumulation, successful zero,
  retry, folder/query/selection, composer retention and history-focus readiness.
- `scripts/build-app.sh`: exit 0; native app and strict ad-hoc signature check
  passed. Initial recipe preparation used the wrong upstream search-file path
  and failed before adaptation; that incomplete output was preserved and the
  tracked path was corrected. Generated engine files were never hand-edited.
- In a separate publishable source copy, `.references/` was absent and the bare
  source cache temporarily moved aside, with HTTP(S) proxy at a closed loopback
  port. Build/sign and all 73 XCTest/18 Python tests passed without recreating
  excluded directories. The first test attempt stopped because that copy had
  no database config; the retry supplied the test DSN only in process memory.
  The source cache was restored. Default search-adaptation regressions require
  only the verified prepared engine, with no source cache or skipped tests.
- Actual isolated native UI found dialog 125 outside the first page and archive
  dialog 65, displayed search pages 50 → 100 → 130, retained 50 matches after an
  injected next-page failure, and reached 100 after explicit retry. A successful
  unmatched query showed zero results. Changing the sidebar filter to omit the
  selected chat retained its history and draft. The history button opened
  message 25 outside the latest window, with the composer unchanged and sending
  disabled. Synthetic mode uses no account, credentials, Keychain, database or
  network. Screenshots and accessibility observations confirm those states.
- UI inspection found a List row did not expose/activate the history button via
  accessibility. Search results now use a lazy scroll stack with explicit
  accessible buttons; the final button activation succeeded. A coordinate probe
  returned `noWindowsAvailable`; button accessibility remained usable.
- Scoped same-model source reviews found a retained-window focus race: initial
  rendering could consume the focus before the new anchor was ready. Root gates
  focus on current navigation readiness, observes that computed value, and added
  a regression for loading/stale/ready emissions. Observed worker model/provider
  and usage remain unknown. Root owns integration and execution evidence.

Final project XERJ refresh: exit 0, 77 indexed files, 50/50 classified code.
Project and recipe-3 engine freshness checks passed; actual search queries were
confirmed against current controller, reducer and history source. Two earlier
project refreshes stopped with exit 1 because files changed during indexing;
those logs were preserved and not reused as fresh evidence.

Real server search, authorization, migrated history, incoming messages, delivery,
reconnect and timeout recovery on a connected account remain unverified. A
release build and broader OS/accessibility/resize matrix were not run. Media,
message actions, dossier linking and later service transfers remain open; this
slice does not complete the active migration goal.
