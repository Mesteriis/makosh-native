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


The search head `13b5d9052c11c900135f2b74e2d212643cb6a1fe` subsequently
passed [PR CI 38057972256](https://github.com/Mesteriis/makosh-native/actions/runs/38057972256):
reference-free cold build, 73 XCTest tests and 18 Python regressions.

## Telegram photo/file download and export — 2026-10-10

History and search share a pure attachment projection. Photo full/thumbnail
resources and file resources retain message provenance for engine reference
revalidation; opaque IDs include message/media/resource identity. Unknown and
paid/locked media expose no runnable download. The account-bound provider uses
TelegramCore's real fetchedMediaResource/MediaBox APIs. Only explicit actions
fetch bytes; progress, cancellation, failure and a 60-second deadline are
separate states. Complete zero-offset data is required for ready. Own disposable
handles never cancel other resource consumers. UUID guards reject stale events;
file leases survive an ongoing preview/export borrow during reset.

A conversation owns one image/export operation. ImageIO validates regular-file
size, 20 MiB encoded bytes, 8,192 per side and 40 million pixels, then downsamples
to 1,280 on a worker. Arbitrary files never auto-open. A native Save panel copies
bytes to a mode-0600 temporary file and atomically replaces the selected regular
file; the cache source is never moved/overwritten. Symlinks, special files,
size mismatch and a destination sharing the source inode are rejected. Panel
cancellation creates nothing; already-cancelled callers start no file work.

Actual checks:

- `scripts/dev-db.sh up`: exit 0, existing Docker PostgreSQL healthy.
- `scripts/test.sh`: exit 0, **99 XCTest tests, 0 failures** (24 real-PostgreSQL
  contact tests and 75 Telegram), plus **18 Python regressions**. The 26 new
  Swift tests cover actual-engine media projection, independent purpose/consumer
  cancellation, synchronous completion, stale callbacks, timeout/retry, borrowed
  leases, replacement/chat/search integration, atomic copy/source preservation,
  safe special-file failures, decoder bounds and pre-cancelled file work.
- `scripts/build-app.sh`: exit 0, complete native app and strict ad-hoc signature
  verification. The first test compilation failed because a paid-media fixture
  omitted the upstream `media:` argument label; the fixture was corrected and
  the full checks above passed. Failed logs remain local.
- A separate source copy with `.references/` absent, bare source cache moved
  aside and HTTP(S)/ALL_PROXY set to a closed loopback port built/signed and
  passed all 99 XCTest/18 Python tests. Neither excluded directory was created;
  the preserved source cache was restored. Test DSN was supplied only in memory.
- Actual isolated DEBUG native UI showed photo/file/unsupported attachments,
  no automatic load, progress, explicit cancellation and successful retry.
  A real image sheet displayed the generated synthetic image from full data
  and separately from a search thumbnail. A native Save panel was cancelled,
  then saved a separate 59-byte synthetic file. Its bytes matched the original,
  original cache remained intact, output mode was 0600 and no export temporary
  remained. Replacing the history window released all three fixture caches;
  the exported copy remained. Returning to latest showed idle download actions.
- Two scoped same-model source reviews confirmed subscription/borrow ownership,
  export/decoder boundaries and projection/integration behavior. Root added the
  current-history request guard before resource-map mutation and integration
  regressions for replacement, failed search and independent attachment cancel.
  Worker builds/account checks were not run; root owns all integration/runtime
  evidence. Observed worker provider/model/usage are unknown, with no quorum.

No account login, private message read or real media network fetch was performed.
Cloud cache-miss/cached-hit, expired reference recovery, real progress/cancel,
secret-media decryption and reconnect remain unverified. Media upload, audio/video
playback, message actions, dossier linking and later channels remain open in the
active sequential goal. A release build and broader OS/accessibility/resize
matrix were not run; synthetic UI is not Telegram server acceptance.

Final media project XERJ refresh: exit 0, 87 indexed files, 60/60 classified code.
Project and unchanged recipe-3 engine freshness checks passed; actual queries
resolved withDownloadedFile and fetchedMediaResource and were checked against
current controller/provider and upstream source. Indexes and review artifacts
remain ignored; product build/run/test does not use them or research clones.


## Telegram file/photo upload slice — 2026-10-10

Implemented explicit native single-file selection, private staging and separate
recipient/caption confirmation. Chat changes retain the captured recipient;
account-generation validation rejects a panel opened before stopping/replacing
the account, even when its account ID later matches again. A document streams
unchanged bytes (1 MiB chunks, 4 GiB product cap). Photo mode separately validates
20 MiB / 8,192-side / 40-million-pixel input, normalizes orientation and encodes
JPEG at no more than 2,560 pixels without copying source metadata. Owned copies
are 0700/0600, and sources remain untouched.

The production provider copies into this account's MediaBox, then requires
complete zero-offset data and a measured, regular, nofollow cache file with the
expected size before calling real TelegramCore enqueue. Its local MessageId
acknowledges only the outbox. Captured caption acknowledgement preserves another
chat/account and byte-distinct edits. Progress/nil/100% never establishes server
delivery. Cancellation is available before enqueue; closing observation after
possible commitment never deletes/recalls a message. The 30-second deadline
keeps an uncertain operation observable for a late acknowledgement and blocks
another enqueue of that active operation. No app automatic resend is added.

Actual checks:

- `scripts/dev-db.sh up`: exit 0, existing Docker PostgreSQL healthy.
- `scripts/test.sh`: exit 0, **122 XCTest tests, 0 failures** (24 against real
  PostgreSQL and 98 Telegram), plus **18 Python regressions**. The 23 new Swift
  tests exercise actual document/photo staging, metadata/orientation/bounds,
  safe special-file/cleanup failures, cancellation, frozen recipient/caption,
  synchronous/stale callbacks, pre/postcommit deadlines and late acknowledgement,
  media projection/cache verification, account/chat/Unicode draft preservation
  and rejection of an old picker context before staging.
- `scripts/build-app.sh`: exit 0, native bundle built and strict ad-hoc signature
  verification passed. The initial test compilation failed because an implicit
  catch `error` shadowed the controller's published property; explicit `self.error`
  fixed it. Both subsequent full test runs passed; failed logs remain local.
- The separate source copy with `.references/` absent, its bare source cache
  preserved outside the expected location and closed HTTP(S)/ALL_PROXY routes
  built/signed and passed all **122 XCTest / 18 Python tests**, exit 0. Neither
  excluded directory was created. The source cache was restored, and the test
  DSN was passed only in process memory.
- Actual isolated DEBUG native UI: cancelling the Open panel retained the draft;
  a 51-byte synthetic document reached explicit confirmation. Switching to a
  second chat retained the first recipient. The labeled fake queue acknowledged
  only the first caption, preserving the second chat's newer draft. Opening the
  first chat showed its caption cleared. Closing observation showed the possible
  queue notice. Photo selection prepared a 780-byte JPEG; 1,026 UTF-16 units
  disabled send. Cancel removed the sole owned stage and both original fixture
  hashes remained unchanged. The final rebuilt executable also showed the updated
  JPEG explanation and successful ready-to-cancel transition. No real send occurred.
- Scoped same-model source reviews covered staging, controller/provider and
  UI/model integration; no additional confirmed findings. Root independently
  added the same-account reconnect/picker guard and regression, and owns the
  final build/test/UI evidence. Worker SwiftPM/live checks were not run and
  observed route/usage metadata remain unknown; no quorum was used.

The preceding download head `8a288d12e8c105fcfec60c32b12a70645b70b709` passed
[PR CI 38059043973](https://github.com/Mesteriis/makosh-native/actions/runs/38059043973).
This is evidence for that head, not a CI result for the new upload changes.

No account login, private message read, real file/photo send or network media
acceptance was performed. Cloud quota/restricted-peer behavior, genuine MediaBox
copy failure, sandbox-scoped documents, cancellation/mutation during streaming,
crash/restart uncertain-send reconciliation, local-to-cloud message mapping,
secret-chat upload, queued-send deletion and delivery/read status remain open.
Queued engine work may resume after reconnect; exactly-once remote delivery is
not claimed. Audio/video playback, message actions, dossier linking and subsequent
services remain in the active sequential goal.

Final upload project XERJ refresh: exit 0, **95 indexed files, 68/68 classified
code**. Project and unchanged recipe-3 engine fingerprints passed. Actual own
queries retrieved the native panel, caption acknowledgement and context guard;
engine queries/source reads confirmed enqueue, local resources, MediaBox copy
and pending status. An intermediate refresh failed because source changed while
indexing; its stale fingerprint was not reported as fresh. The stable final
refresh supersedes it. Product build/run/test still does not use indexes/clones.

## Telegram local audio/video playback slice — 2026-10-10

Engine attributes now classify voice, audio, video and round video without
fetching. Contradictory attributes and MIME-only guesses remain ordinary file
downloads. The full resource must already be downloaded before explicitly
opening the native AVFoundation player; opening never autoplays. Play/pause,
seek and 0.5/1/1.5/2 speed controls operate on one player and actual native timing.

A streaming private 0700/0600 copy has a 4 GiB cap. Container hints for Ogg/WAV/MP4
come from bytes, never a message's name or MIME label. Actual playable tracks,
finite positive duration up to seven days and video dimensions up to 8,192-side /
40 million pixels are checked. AVURLAsset forbids all external references and
alias resolution before property loading; no network/resource-loader fallback
exists. This config is tested, but a valid unrestricted/restricted reference-movie
baseline pair was not executed. Native decoder sandbox/resource isolation is not
established by the file/dimension caps.

The source cache borrow spans loading, playing and pause. Stop/end/failure,
account/chat/page changes, changed descriptors, search query and view dismissal
detach the decoder before releasing that borrow and deleting the private copy.
Late callbacks are token guarded. Preparation has a 30-second deadline. Unsupported
native files remain exportable. No playback/account state is persisted.

Actual checks:

- `scripts/dev-db.sh up`: exit 0, Docker PostgreSQL healthy.
- `scripts/test.sh`: exit 0, **146 XCTest tests, 0 failures** (24 PostgreSQL,
  122 Telegram), plus **18 Python regressions**. New coverage includes pure
  classification, real private IO, borrow/cancellation/deadline/stale events,
  actual WAV/MP4/Ogg native loading, no autoplay and real model boundary cleanup.
- `scripts/build-app.sh`: exit 0, native build and strict ad-hoc signature passed.
- A source copy with `.references/` absent, its bare source cache preserved
  outside the expected location and closed HTTP(S)/ALL_PROXY routes built/signed
  and passed all **146 XCTest / 18 Python tests**, both exit 0. Neither excluded
  directory was created, source cache restored, test DSN supplied only in memory.
- Actual isolated DEBUG native UI showed the synthetic video frame at 0:00,
  explicit playback/time advance, pause, seek to about 0:08, 1.5 speed and normal
  end. Ogg/Opus opened, played, advanced and paused; changing chat removed the
  player and left zero playback stages. WAV opened at 0:00 / 0:20, explicitly
  played/advanced/paused; changing history page removed it. Personal accounts /
  network / real sends were disabled. Audio-device output was not captured or
  verified.
- The final rebuilt QA binary also rejected a task-owned symlink replacing its
  playback stage, showed the cleanup error after closing, and preserved the
  target sentinel's hash. The test-owned link/saved stage were then removed,
  leaving zero playback stages; dismissing the error restored idle controls.
- Two bounded same-model source reviews covered engine/IO and controller/UI.
  One confirmed observation gap was fixed: status KVO now includes its initial
  state after readiness. Worker SwiftPM/runtime checks were not run; root owns
  integration evidence, observed worker provider/model/usage remain unknown.

Failed checks remain recorded: Foundation stripped an embedded NUL before the
IO API received a URL, invalidating one test expectation (removed). Native Ogg
opening also failed for an opaque extensionless copy; byte-derived container
suffixes fixed that actual integration failure. Ogg duration reporting differs
by OS codec version, so the codec fixture checks bounded native timing rather
than an assumed exact duration. Both earlier failures are separate from the
successful final checks above.

Upload head `e9c0e4aaf4691b54e01beeeede0bdced50b9fc41` passed
[PR CI 38060157464](https://github.com/Mesteriis/makosh-native/actions/runs/38060157464).
That is not CI evidence for these subsequent playback changes.

No account login/private-message read/real network-media acceptance occurred.
Broader codecs, OS versions, audio-device output, protected/secret media and
reference-container runtime denial remain unverified. Recording, message actions,
dossier linking and subsequent channels remain in the active sequential goal.
No release build, complete accessibility/resize matrix or remote delivery claim.

Final playback project XERJ refresh: exit 0, **105 indexed files, 78/78 classified
code**. Current project and unchanged recipe-3 engine fingerprints passed; actual
queries resolved the playback controller/cache-borrow and engine attribute APIs,
which were checked against source. Research indexes and clones remain optional,
ignored tooling; product build/run/test uses neither.

## Independent Telegram text/version retention — 2026-10-10

The user's additional requirement is permanent local retention when a peer
deletes a message. Before message actions, recipe 4 now captures central Postbox
history snapshots before overwrite/removal and after writes, in the same ValueBox
transaction, including unknown peers and more than one displayed page. A separate
encrypted append-only PostgreSQL archive retains original text, edits, full
scoped IDs and attachment metadata. Stable observation receipts make retries
idempotent. Exact journal acknowledgement follows archive commit; PostgreSQL
failure keeps the journal pending. The offline native viewer has 100-record
pages and no automatic expiry/delete action. Removal is labeled source-cache
removal with unknown cause, never inferred from a changing visible window.

The random archive key uses a separate nonsynchronizing macOS login Keychain
item. Missing/wrong keys and future schemas fail without replacing data. AES-GCM,
HKDF-separated keys, HMAC identity tokens, authenticated sequence/vault binding,
parameterized transactions and append-only event/receipt triggers are tested.
Contacts retain their existing state schema. Normal login-Keychain ACL/unlock
semantics apply; no iOS device-only/lock-screen guarantee is claimed.

Actual checks:

- `scripts/dev-db.sh up`: exit 0, existing Docker PostgreSQL healthy.
- `scripts/test.sh`: exit 0, **173 XCTest tests / 0 failures** (136 Telegram,
  37 core including real-PostgreSQL contacts/archive), plus **22 Python
  regressions** (15 preparation, 3 search, 4 retention adaptation).
- One joint integration test uses the production journal read/ACK builders,
  encrypted temporary Postbox and a generated real PostgreSQL schema. It stores
  55 unknown-peer messages, edits/deletes one in the same source transaction,
  forces an archive insertion rollback, verifies zero ACK/no journal loss,
  retries, reopens the independent archive, recovers original/edit/removal and
  verifies UUID redelivery creates zero new records. Store tests also cover
  A→B→A, dedup receipts, account/UTF-8 isolation, tamper, two-connection writes,
  atomic bounds validation and rejection of ordinary archive rewriting.
- `scripts/build-app.sh`: exit 0, native build and strict ad-hoc signature passed.
- Separate source snapshot: recipe-4 app build/sign and **173 XCTest / 22 Python
  tests** passed, both exit 0, with `.references/` absent, its bare source cache
  moved outside the expected path and HTTP(S)/ALL_PROXY set to a closed loopback
  port. Neither excluded path was recreated; the source cache was restored.
- Actual final isolated DEBUG native UI, copied from the final built payload
  and separately identified/signed, opened the archive without selecting a chat.
  Screenshot and accessibility state showed the original, edit and removal
  marker together. Refresh kept all three; dismissal returned to navigation.
  Data were visibly synthetic; no Connect, private account/message read or real
  peer deletion was performed. An earlier QA process was accidentally relaunched
  without its preview argument during exit inspection and showed only a missing
  database configuration error; no account connection occurred. The final check
  used a fresh isolated bundle identity and explicit preview argument.
- A task-owned synthetic Keychain item in an ad-hoc signed helper was created
  and reopened through the final macOS login-Keychain API path, then deleted by
  its exact generated UUID. No existing personal keys were retrieved. The probe
  used a deterministic test key; system random generation is covered by source
  inspection/injected tests, not claimed as exercised by this probe.
- Final project XERJ refresh: exit 0, **121 files, 94/94 classified code**;
  engine refresh: exit 0, **721 files, 686/686 classified code**. Fresh actual
  own archive/transaction and engine replay/deletion queries were confirmed
  against source. Postbox is outside the TelegramCore index and was read directly.
- Bounded inherited-model worker reviews and root diff review covered journal,
  storage, mapping and controller boundaries. Runtime tests exposed and fixed
  test MainActor callbacks on a background Postbox queue; production transaction
  builders are now nonisolated and exercised by the joint test. Worker provider,
  actual model and usage metadata remain unknown; no quorum/voting was used.

Failed probes remain separate: an early run preceded prepared journal generation;
the first adapted build incorrectly converted existing MessageFlags; a new test
initially failed Swift sending checks, then trapped on the queue boundary above.
The entitlement-gated data-protection Keychain returned OSStatus -34018 for the
ad-hoc helper; the final explicitly selected macOS login-Keychain path passed.
After successful XCTest completion, temporary Postbox fixtures emit SQLite
`no such table: t19` messages (four in the final full run). Exit 0 and passing
assertions do not establish clean upstream fixture teardown; that remains open.

Playback head `28dae6afd91052f3307b13d8342b8c1a51759298` passed
[PR CI 38061439041](https://github.com/Mesteriis/makosh-native/actions/runs/38061439041).
This is previous-head evidence; the retention head needs its own hosted check.

This slice retains **text and attachment metadata**, not permanent attachment
bytes. Downloaded-file retention is next, before reply/edit/delete/forward.
Untouched historical cache backfill, author names/rich entities, referenced-media
only mutations, raw versions optimized before Postbox, graceful disk-full
backpressure, portable archive/key backup and real-account acceptance remain
unfinished. Deleted-before-reception content cannot be reconstructed. No physical
loss/admin-deletion immunity is claimed. The complete sequential goal, message
actions, dossier linking and subsequent channels remain active.

## S3 attachment retention — 2026-10-10

Local development now starts PostgreSQL and an independently pinned SeaweedFS
4.48 S3 container together. Only the authenticated S3 API is published, on
loopback port 55440, with a separate persistent volume and private generated
administrator/application credentials. Application access is bucket-scoped;
the initialized bucket enables versioning and denies object/version/bucket
deletion and lifecycle/versioning changes. This is protection against ordinary
client deletion, not immunity to administrator policy changes or volume loss.

Full Telegram downloads are captured synchronously by an open file descriptor
before async work. AES-GCM frames, per-object HKDF keys and authenticated sizes
allow streaming encryption without loading the complete file. S3 receives only
the encrypted envelope; PostgreSQL receives encrypted append-only metadata and
receipts, never attachment payload bytes. Previews and files not downloaded
remain attachment metadata. Automatic fetching of all remote history is not
implemented.

An encrypted disk queue survives S3/PostgreSQL failure after receipt publication.
Conditional PUT and HEAD/hash reconciliation recover an uncertain upload without
blindly replacing the object. A stored PostgreSQL receipt precedes queue cleanup.
Before durable publication, up to eight open captures survive cache unlink and
can be retried while the process remains open. Failure is visible; closing the
process at that stage can lose the unqueued capture. A crash between envelope
creation and receipt publication can leave orphan encrypted envelopes; these
are not silently deleted. Portable backup of S3, PostgreSQL and the archive key
remains a later migration task.

Actual checks for this slice:

- `scripts/dev-db.sh up`: exit 0 after fixing the container's volume/identity
  ownership boundary. Both development services are healthy. Authenticated S3
  PUT/GET and exact hash checks passed before and after a container restart;
  anonymous/invalid signatures and prohibited deletion returned denial.
- `scripts/test.sh`: exit 0, **193 XCTest tests / 0 failures** (138 Telegram,
  55 core), plus **22 Python regressions**. Real S3/PostgreSQL tests cover
  capture-before-unlink, encrypted round trip, metadata-only schema, immutable
  receipt guards, account isolation, post-upload database rollback and retry
  through a new repository instance. Official AWS signing vectors, frame
  tamper/truncation/reordering, wrong keys/UUIDs and unsafe paths are covered.
- A missing-configuration regression retains the prequeue descriptor, unlinks
  the source, restores configuration and successfully retries/exports. Duplicate
  descriptors use positional reads, so the original capture can be retried.
- `scripts/build-app.sh`: exit 0, native build and strict ad-hoc signing passed
  after the final shared save-panel change.
- The pinned official macOS SeaweedFS binary used by hosted CI was verified and
  exercised locally in a separate native service. Its S3 initialization/probe
  and **11 S3/repository tests** passed; the Docker service was restored and its
  authenticated probe passed afterward. This is local CI-strategy evidence,
  not a hosted result for the new commit.
- Actual final isolated DEBUG native UI showed the original/edit/removal
  archive entries and `Копия в S3`. The native Save sheet was enabled and export
  completed with `Сохранено`. The restored synthetic file matched all 67 bytes
  and SHA256 `60e30bfd36666396a06fcd74993d83788296599be1e7a13a24e6c687ceefd8aa`;
  the synthetic Telegram cache copy was absent and the encrypted queue empty.
  No personal account, Keychain item, message or Telegram connection was used.
- Final project XERJ refresh: exit 0, **137 files, 108/108 classified code**;
  project and unchanged engine fingerprints passed. Actual current queries on
  capture duplication, pending retry and archive export were source-confirmed.
- Two bounded inherited-model source reviews found the prequeue retry gap and
  non-atomic receipt publication. Both were fixed and covered by regressions;
  final follow-up reviews and root diff review are recorded separately. Worker
  runtime model/provider/usage remain unknown; no quorum was used.

A final review also identified a post-publication directory-fsync error being
misclassified as a prequeue failure. A new injected-failure test first failed at
the queued-state assertion (exit 1). The publication callback now marks the
receipt as queued immediately after `link`; uncertain sync recovers that exact
object instead of recapturing. The complete **4 repository tests** then passed
(exit 0), including source unlink, restart, exact object ID and exported bytes.
The reviewer confirmed the fix by source/hash checks; runtime gates are root's.
The earlier reference-free snapshot also passed build/sign and **192 XCTest /
22 Python** tests with research/source-cache paths absent and then restored.
That snapshot predates this final fsync fix. The final source snapshot then built
and signed, and passed **193 XCTest / 22 Python** tests (both exit 0, no S3 test
skips) with research/source-cache paths absent, closed outbound proxy routes and
the original source cache restored afterward. The main checkout independently
passed the same full tests and app build after the fix. Both successful full
test runs retained the four upstream `t19` teardown diagnostics noted above.

Failed probes remain separate: the initial container could not write its volume;
the second could not traverse the changed ownership with dropped capabilities.
The final launcher copies identities into private tmpfs and drops to the service
UID. Initial native CI probes observed S3 before bucket creation; initialization
now waits with bounded read-only readiness checks before applying policy. One
new async test initially used an unsupported XCTest autoclosure and was fixed.
The first native archive export opened a disabled standalone save panel; the
final shared, retained sheet path passed the real export check above. Temporary
Postbox fixtures still emit four `no such table: t19` teardown messages after
successful XCTest completion; clean upstream teardown remains unverified.

Retention head `70e85c0133af524de367c6fabed1c6a87fbcd4c3` passed
[PR CI 38063471351](https://github.com/Mesteriis/makosh-native/actions/runs/38063471351)
and [push CI 38063467369](https://github.com/Mesteriis/makosh-native/actions/runs/38063467369).
Those are previous-head results. S3 head `d52bad870c2e79f957da9b69637d275f6e08cb8e` subsequently passed [PR CI 38065475578](https://github.com/Mesteriis/makosh-native/actions/runs/38065475578) and [push CI 38065471951](https://github.com/Mesteriis/makosh-native/actions/runs/38065471951): cold reference-free build, isolated S3 initialization, all 193 XCTest and 22 Python regressions.

Real-account media/download/deletion acceptance, untouched cache backfill,
secret/protected media, administrator/disaster recovery and portable backup
remain unverified. Reply/edit/delete/forward, dossier linking and subsequent
channels remain in the active sequential goal.

## Telegram message-action slice — 2026-10-10

History and search rows now expose typed reply, plain-text/supported-caption
edit, forward and deletion. Account/chat/native message identity, thread and
content/version fingerprint are captured before confirmation. A fresh Postbox
transaction checks the source, current rights and explicit forward destination.
Incoming private revoke uses current limits; group creator/admin and channel
rights are included. Replies/deletion do not depend on renderer support.

Reply preserves its chat draft and clears only exact text after local enqueue
acknowledgement. Edit owns an account/message draft that survives closing,
rejection, uncertainty and controller rebind; exact applied acknowledgement
clears it. Forward has no selected recipient by default. Deletion has no scope
selected by default, shows the chosen scope and states retained versions/S3
copies remain. All mutations still use the central Postbox retention journal.
Post-commit uncertainty blocks automatic repeat and preserves composition.
Queue acceptance is explicitly distinct from server delivery/recall.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; existing development PostgreSQL/S3 healthy.
- `scripts/test.sh`: exit 0, **215 XCTest / 0 failures** (160 Telegram, 55 core)
  plus **22 Python regressions**. The 22 new action tests cover frozen typed
  sources, account/chat/context guards, synchronous/stale callbacks, exact ACK,
  uncertainty/no retry, edit draft retention, real peer permissions, UTF16
  limits and production preflight on an encrypted synthetic Postbox.
- The real Postbox test changes and deletes a source, rejects stale/deleted
  action targets and verifies original, edited and removal journal entries.
  It has no Account/network object. Initial fixture runs failed because the
  peer codecs were not registered; explicit `initializeAccountManagement()`
  and committed-peer/author assertions fixed the fixture without weakening the
  production validator. Failed logs remain separate from the passing run.
- `scripts/build-app.sh`: exit 0; native app and strict ad-hoc signing passed.
- A separate reference-free snapshot passed build/sign and the same **215
  XCTest / 22 Python** checks with no S3 skips. Research/source-cache paths
  stayed absent under closed outbound proxy settings; the original cache was
  restored afterward. These are source-snapshot results, not hosted CI.
- Actual native DEBUG QA verified reply selection/cancel/draft preservation and
  labelled local-queue acceptance; forward was disabled until explicit recipient
  selection and then displayed the recipient. The final bundle's unsigned
  executable matched the built app. It verified independent edit text surviving
  close/reopen while the main draft remained, edit outcome, initially disabled
  deletion confirmation, explicit local scope and the retention notice.
  Actions were visibly simulated; fixed preview history was not mutated and
  no personal account, message, Keychain or Telegram network was used.
- Final project XERJ refresh: exit 0, **145 files, 116/116 classified code**;
  project and unchanged engine fingerprints are current. Actual validator and
  edit-draft query hits were checked against current source.
- Two scoped same-model source reviews found the edit-draft reopening gap and
  missing basic-group administrator deletion permission. Both are fixed and
  covered by current tests; follow-up review confirmed the group fix. Runtime
  provider/model/usage remain unknown; no quorum was used.

The full runs retain six upstream `no such table: t19` temporary-fixture teardown
diagnostics after successful XCTest completion; clean teardown is unverified.
Preflight and engine mutation are separate transactions; Telegram's server
rules still decide changes after preflight. Rich-entity editing, media replies,
destination topics, secret/paid capabilities, premium caption limits and live
account acceptance remain unfinished. Dossier linking and subsequent channels
remain in the active goal. Published action head
`55806b858724ecf003508c84bc81e7741d521714` passed
[PR CI 38066942485](https://github.com/Mesteriis/makosh-native/actions/runs/38066942485)
and [push CI 38066939636](https://github.com/Mesteriis/makosh-native/actions/runs/38066939636).


## Rich actions and reference UI correction — 2026-10-10

The user corrected the earlier independent UI design. Telegram now follows
verified TelegramSwift input/row patterns: 70-point dialog rows with 50-point
initial placeholders, a 36-point header placeholder, message context menus,
one attachment menu, inline reply/edit accessories and selection formatting.
The standalone edit sheet and persistent formatting toolbar were removed.
[The reference mapping](reference-interface.md) records exact source pointers,
license boundaries and remaining visual gaps. This is a partial UI adaptation,
not a claim of complete TelegramSwift visual parity or copied outer UI code.

Formatted edits retain exact UTF8 text and typed UTF16 entity ranges, including
Telegram metadata. Validation rejects malformed/crossing ranges and server
conversions that would silently drop entities. Format-only edits are supported;
a newer formatted draft survives an older applied acknowledgement. Current
channel send-as permissions are checked. File/photo replies freeze account,
chat, native message/thread and fingerprint before the picker, then freshly
validate after MediaBox storage. Deleted/stale sources reject without ordinary
message fallback; captions may be empty.

Actual checks for this source slice:

- `scripts/dev-db.sh up`: exit 0, development PostgreSQL/S3 healthy.
- `scripts/test.sh`: exit 0, **236 XCTest / 0 failures** (181 Telegram, 55 core)
  and **22 Python regressions**. Coverage includes entity/sticker-pack round
  trips, UTF16 scalar boundaries, attributed-text integrity, dynamic label
  colors, format-only draft/ACK, channel permissions and typed media replies
  with stale/deleted/mismatched sources and empty captions.
- Native app build/strict ad-hoc signing: exit 0 after correcting an ambiguous
  CGFloat size initializer. The failed build remains a separate retained log;
  parse success alone was not treated as compilation proof.
- Actual isolated DEBUG native QA verified context-menu edit opening in the
  lower composer, preserved original bold text, format-only italic by keyboard
  and menu, Undo/no-change disabled confirmation, close/reopen preserving rich
  draft while the normal draft remained, twelve-line growth/scroll and Undo,
  and a labelled simulated applied result returning to the normal composer.
  The final QA unsigned executable matched the built application.
- Native reply QA verified source accessory, one paperclip menu, actual
  NSOpenPanel selection of a purpose-created 61-byte text file, frozen recipient
  and source in preparation, empty caption and labelled fake queue acceptance.
  An earlier fixture in a hidden project directory could not be selected;
  changing to a normal temporary fixture passed without a speculative panel fix.
- Earlier keyboard QA did not apply the style. The final native control handles
  formatting in both key-equivalent and key-down paths with physical command
  key fallback; the final observed test passed. Menu QA required no extra Return
  after selecting an action; the extra Return in an earlier probe inserted text
  and was undone. No personal content was selected or transmitted.
- Final separate snapshot with research checkout/source cache absent and closed
  outbound proxy routes passed build/sign and **236 XCTest / 22 Python** checks,
  without S3 skips; the original source cache was restored afterward.

Six upstream temporary Postbox-fixture `no such table: t19` teardown diagnostics
remain after passing tests. Synthetic UI actions did not mutate the fixed
preview history or use an account, Keychain, PostgreSQL or Telegram network.
Fresh preflight and mutation still have a concurrency boundary; live server
formatting/action acceptance is unverified. App-restart edit-draft persistence,
full reference UI, topics, secret/paid capabilities, dossier linking and the
subsequent channels remain in the active sequential goal.

Final source review found no confirmed must-fix findings in six functional and
four UI files. Both same-model workers used bounded read-only diff/source/hash
checks, without independent native/runtime execution; provider/model/usage
metadata is unavailable and no quorum was used. Root's final unsigned-payload
comparison still matched after the indentation-only cleanup. Secret-match audit
of 158 publishable files found zero matches to the selected local credential
fields. Final project XERJ refresh/check passed: **153 files, 123/123 code**;
engine freshness also passed. Actual inline-draft and upload-preflight queries
were checked against the current source. No generated engine/dependency lock or
reference checkout was changed in this slice.

The reference-input head `4121afb81942bb96830ea4e3d4d33740550421b3` passed
[PR CI 38068709500](https://github.com/Mesteriis/makosh-native/actions/runs/38068709500)
and [push CI 38068706569](https://github.com/Mesteriis/makosh-native/actions/runs/38068706569).
These results apply to that head, not the subsequent reading slice.

## Reference message reading — 2026-10-10

History/search now use independently written reading presentation over captured
Telegram entities. Combined fonts, underline/strike, code/pre, safe links and
spoiler masks follow verified TelegramSwift scenarios. Hidden TextUrl activation
asks with the actual target; unsupported schemes stay text. Chat previews and
reply/action/upload source summaries mask spoilers. Original text/entities are
unchanged. Malformed or mismatched formatted metadata fails closed. The full
quote/code renderer and custom emoji remain unfinished; paragraph attributes do
not establish SwiftUI visual parity.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; development PostgreSQL and S3 healthy.
- `scripts/test.sh`: exit 0, **244 XCTest / 0 failures** (189 Telegram, 55 core)
  and **22 Python regressions**. New checks cover actual native Message mapping,
  malformed surrogate boundaries, exact UTF8 metadata, nested/adjacent spoilers,
  removal of hidden URL attributes, supported/unsafe URL handling, combined
  styles and reveal keys rejecting a changed context, text, entities or Unicode
  bytes. Source values remain unchanged after presentation and reveal.
- Native build/strict ad-hoc signature verification passed. A later direct-Text
  menu build first failed because generic Swift types do not permit stored static
  properties; changing the fixed reveal URL to a computed static property passed.
  The failed log remains separate. No generated engine/lock/dependency changed.
- Final separate source snapshot with `.references/` and bare source cache absent
  and closed outbound proxy settings passed build/sign and the same **244
  XCTest / 22 Python** checks, with no S3 skips; original cache restored.
- Actual isolated DEBUG native QA visibly showed bold text and masked spoilers
  in search/history. AX reveal exposed only the selected synthetic message;
  changing results reset concealment. Hidden-link activation displayed the exact
  `https://example.invalid/docs` confirmation and Cancel returned without an
  external open. Final native selection-copy pasted masks, not original spoiler
  text, into the synthetic composer; the draft was then cleared.
- The final QA unsigned executable matched the built app. Right-click actions
  worked on the bubble author. Direct right-click on selectable rich text did
  not show a menu through the bridge, even after placing the same context menu
  directly on Text. This remains unverified, not a passing acceptance check.
  Coordinate pointer attempts also returned `noWindowsAvailable`; no conclusion
  about actual spoiler/link pointer activation is drawn from AX-action success.

A bounded source review found the initial reveal Bool could apply to a newly
updated message before onChange reset. Reveal and pending-link state now use a
context plus exact-version key, checked before rendering, with key regressions.
Six upstream temporary Postbox-fixture `no such table: t19` teardown diagnostics
remain after passing tests. No personal account, message, Keychain or Telegram
network was used. Full reference UI, archive rich entities, quote/code folding,
protected-copy parity, app-restart drafts, topics/secret/paid capabilities,
live account acceptance, dossier linking and subsequent channels remain in the
active sequential goal.

Final bounded reviews checked eleven source/test files; root verified all final
SHA256 values against worker reports, with no remaining confirmed source
must-fix. Workers did not run independent build/native tests; observed model,
provider and usage remain unavailable, and no quorum was used. Final project
XERJ refresh/check passed: **156 files, 126/126 code**; unchanged engine freshness
also passed. Actual reveal-key and masked-preview query hits were checked against
current source. Credential-match audit of **161 publishable files** found zero
matches to the selected local credential fields. Private QA, raw logs, worker
records, indexes and configuration remain ignored.


## Telegram reference peer profile and dossier linking — 2026-10-10

The conversation header now opens peer information, preserving TelegramSwift's
confirmed title-bar entry and profile → phone/username ordering. The independently
written native view reads only the selected account's cached TelegramUser after
explicit opening. It adds an explicit new/existing PostgreSQL dossier action,
source refresh and the existing dossier navigation; it does not introduce a
second dossier renderer. Photos/presence/about and other reference profile
features remain unfinished. Group/channel/secret-chat profiles, bot person
linking and linking a nameless profile are outside this slice.

Identity attachment is one row-locked PostgreSQL mutation. It preserves manual
fields, notes, source observations and identity history, reuses an existing
owner, rejects another owner's identity or a missing explicit target without
partial writes, and never silently merges/moves contacts. Repeated snapshots
are idempotent; stale source data cannot overwrite newer observations. Link and
source changes advance revisions to block stale merge undo. Username is shown
in the profile but is not stored in an unrelated dossier field. The timestamp
records a local cache observation, not server freshness.

Actual evidence:

- `scripts/dev-db.sh up`: exit 0; existing PostgreSQL and S3 containers healthy.
- Focused initial run: 14 XCTest tests, exit 0. Final `scripts/test.sh`: exit 0,
  **259 XCTest tests (196 Telegram + 63 core), 0 failures**, plus **22 Python
  regressions**. Eight new real-PostgreSQL tests cover attachment/restart,
  account/service/exact-UTF8 isolation, idempotence/stale source data, rollback,
  corruption, concurrent connections and merge/reimport/undo guards. Six new
  profile/model tests cover actual TelegramUser mapping and stale callbacks.
  A seventh profile test exercises the production peer reader on an actual
  encrypted synthetic Postbox, including a missing peer.
- A scoped review found an inherited-MainActor risk in the first Postbox read.
  Moving its transaction body to a nonisolated signal builder and adding the
  actual Postbox regression resolved that finding. Database integration review
  found no additional confirmed defect. Reviewers did not independently rerun
  runtime gates; observed model/provider/usage metadata are unavailable.
- One intermediate full run exited 1 during an existing retention test's
  temporary-directory teardown (Cocoa 513/EPERM); its journal assertions had
  completed. The isolated test and subsequent full runs exited 0. The failed
  log is preserved; no production or old-test fix is claimed for that transient
  cleanup failure. New fixture cleanup waits for both MediaBox stores to finish
  initialization and reports cleanup errors. Upstream t19 diagnostics after
  completed Postbox tests remain separately recorded, not treated as assertions.
- `scripts/build-app.sh`: exit 0; native executable/bundle built, ad-hoc signed
  and strictly verified. A separate source copy also built and passed all 259
  XCTest/22 Python tests with research/source-cache directories absent and
  network proxy endpoints closed. Its original source cache was restored.
- Actual isolated native QA, with executable payload matched to the built app:
  opening the header displayed profile/phone/username; new dossier creation
  showed the linked state. Choosing an existing contact was disabled until an
  explicit target; a changed search cleared the target and disabled linking.
  Native actions produced two synthetic contacts with four Telegram identities,
  confirmed directly in PostgreSQL. A restart visibly rediscovered a saved
  identity owner. Explicit refresh showed the linked state without creating
  another contact or identity. Manual-override preservation and conflicting-owner rollback
  are established by core tests, not asserted as GUI acceptance.
- Clicking Open Dossier again caused the computer-use bridge to report
  `Sky Computer Use native pipe closed before response`; screenshot observation
  also failed. Restarting only the task-owned synthetic app restored the bridge.
  Full-dossier navigation/edit/note acceptance therefore remains open. No real
  account login, private data access, network profile fetch or Telegram send was
  performed.

The new DEBUG QA branch requires an explicit private database configuration and
an isolated `qa_telegram_dossier_…` schema; ordinary configuration fallback and
normal archive setup are disabled. Account/chat/request guards and cancellation
protect profile results and writes. The overall sequential migration remains
active; this entry does not mark Telegram or later services complete.

The preceding reading head `d9fb0fe6a97cd3505776e9617f3bfb331a4f356b`
passed [PR CI 38069901169](https://github.com/Mesteriis/makosh-native/actions/runs/38069901169)
and [push CI 38069899225](https://github.com/Mesteriis/makosh-native/actions/runs/38069899225).
Those results do not establish hosted CI for the later dossier change.

## Telegram reference code/quote blocks and copy controls — 2026-10-10

History now follows the confirmed TelegramSwift language-header/code-copy and
quote-folding scenarios using own SwiftUI/AppKit code. Collapsible quotes longer
than three measured visual lines initially show two. Code copying preserves
spaces, Unicode and newlines; spoilers remain masked until explicit reveal.
Language hints are bounded, reject controls and remain hidden while a spoiler
is concealed. Expansion/reveal use the exact message version and context.

Lossless UTF16 block projection rebases nested styles. Ambiguous nested/equal
structural entities and links crossing block boundaries retain the original
rich-text fallback, preventing a sliced link from restoring a hidden target.
Current reader/search/action-sheet selection and code copy use an independent
copy capability mapped from message, channel and group protection. Unspecified
permission defaults to unavailable; it is not inferred from forwarding.

Actual evidence:

- `scripts/dev-db.sh up`: exit 0. Focused checks: 14 XCTest tests, exit 0.
  Final `scripts/test.sh`: exit 0, **267 XCTest (204 Telegram + 63 core),
  0 failures**, and **22 Python regressions**. Eight added tests cover lossless
  blocks, UTF16/emoji/style slicing, ambiguous entities, cross-block secret-link
  fallback, measured quote thresholds, language hints and native copy flags.
- The first full run failed six assertions because new synthetic fixtures
  replaced text expected by existing search/edit tests. Restoring their original
  searchable prefix and the existing bold fixture resolved those failures.
  Raw failed output is preserved. Eight upstream t19 teardown diagnostics occur
  after the final Telegram suite passes; they are recorded separately.
- `scripts/build-app.sh`: exit 0; strict ad-hoc signature verification passed.
  A separate current-source checkout also built and passed 267 XCTest/22 Python
  tests with research/source-cache directories absent and closed proxy endpoints.
  Its original source cache was restored; neither directory was recreated.
- Final native QA executable payload matched the built app. Search → In History
  visibly reached the four-line quote; expand/collapse showed two/four/two lines.
  A three-line quote had no toggle. Code-header copy pasted the exact masked
  string, including leading spaces, Unicode and trailing newline, into the
  synthetic composer. Explicit AX reveal then copied the exact original code.
  The draft was cleared. Protected code copy and forwarding were disabled;
  the protected Delete preview used nonselectable Text and Cancel returned
  without submitting any action.
- Earlier native QA found the lazy history ending visibly at message 119 when
  the selected result was 123. Its exposed AX scroll-to-bottom action produced
  SIGTRAP in SwiftUI lazy Accessibility traversal. Using eager layout for the
  bounded 50-message history window restored visible target reachability and
  ordinary AX scroll up/down without a crash. The old lazy AX action is no
  longer exposed, so it was not falsely reported as rerun. Heavy-media
  performance and the broader OS matrix remain unmeasured.
- Source review found an unconditional selectable action preview bypassing
  the copy capability. An explicit capability branch fixed it; the reviewer
  confirmed the final source and native QA checked the protected preview.
  Root verified eleven reviewed source/test hashes. Workers did not rerun
  runtime gates; observed model/provider/usage are unavailable, with no quorum.
- Final project XERJ refresh/check: exit 0, **165 files, 135/135 code**;
  engine freshness passed. An earlier refresh overlapped fixture edits and
  correctly refused to record freshness; a subsequent stable refresh passed.
  Current projection query hits were confirmed against source. Credential-match
  audit covered **170 publishable files**, with zero selected-secret matches.

Syntax highlighting, inline-code click-to-copy, continuous selection across
blocks, archive entities/copy capabilities, custom emoji and pointer/menu
acceptance remain open. The live reader's copy controls are not a global DRM
claim. Earlier full-dossier UI acceptance and live-account/server acceptance
remain open. No private account, real Telegram network or real send was used.
The sequential migration goal remains active.

Preceding dossier head `94fa9945409e2c71ca3400ddef6c45ae52fba917` passed
[PR CI 38071236523](https://github.com/Mesteriis/makosh-native/actions/runs/38071236523)
and [push CI 38071233642](https://github.com/Mesteriis/makosh-native/actions/runs/38071233642).
Hosted CI for the later code/quote change is tracked separately after publication.

## Telegram reference composer persistence — 2026-10-10

The existing composer now restores its ordinary text after app restart, following
the reference's Postbox state-saving workflow. Own versioned snapshots use the
engine's account-local persistent interface preference, preserving exact UTF8,
spaces and newlines. This does not invoke server draft synchronization. Unknown,
malformed, foreign-account or future data is preserved and reported. The 64 KiB
UTF8 storage limit rejects oversized persistence without truncating visible text.

Each edit has a fresh revision; an explicit empty snapshot prevents a delayed
load from resurrecting cleared text. Chat/account/binding/request checks reject
stale reads. Plain send, reply and file enqueue clear only their captured matching
revision, including A → B → A and a composer edited before submission. Failed
or pending snapshots remain dirty and can be retried explicitly or on account
rebind. Writes capture the original Postbox and continue after UI unbinding.
The small retry action appears in the existing error area; no input/navigation
redesign was introduced.

Actual evidence:

- `scripts/dev-db.sh up`: exit 0, PostgreSQL and S3 healthy.
- Final `scripts/test.sh`: exit 0, **286 XCTest (223 Telegram + 63 core),
  0 failures**, and **22 Python regressions**. Nineteen new tests exercise
  revision/tombstone behavior, stale and synchronous restoration, retry/rebind,
  captured reply/ABA acknowledgements, and the production repository on encrypted
  Postbox. Reopen verifies release of the previous public Postbox; tests also
  check ordered writes and preservation of unknown/foreign data. Sixteen upstream
  t19 fixture-teardown diagnostics remain after the passing Telegram suite.
- An initial build rejected transferring a raw non-Sendable Postbox through the
  DEBUG fixture continuation. Returning its MainActor repository resolved that
  compiler error; no unchecked Sendable exemption was introduced. The first
  focused filter selected only 21 existing/pure tests; the corrected filter
  selected all 32 tests at that point. Later regression additions are included
  in the final full suite. Failed/raw intermediate outputs remain private.
- Final `scripts/build-app.sh`: exit 0; native bundle built, ad-hoc signed and
  strictly verified. A separate current-source checkout also built and passed
  all 286 XCTest/22 Python tests with research/source-cache directories absent
  and closed proxy endpoints; its original source cache was restored.
- Final native QA executable payload matched the built app. Two different chat
  drafts, including combining Unicode, emoji, leading/trailing spaces and a
  newline, visibly returned after process exit/relaunch. Clearing one draft and
  restarting again kept it empty while preserving the other. Both synthetic
  drafts were then cleared. This explicit DEBUG route uses only a distinctly
  named private synthetic encrypted Postbox; ordinary synthetic preview remains
  memory-only. No personal account, Keychain, PostgreSQL or Telegram network was
  used in this UI test. Native error/retry injection remains unverified.
- Bounded reviews identified the missing failed-write retry and insufficient
  reopen-release assertion; both were fixed and reviewed. Root additionally
  fixed captured submitted text overwriting a composer changed before submission.
  Final source hashes for twelve reviewed files were verified. Workers did not
  independently run runtime gates; observed model/provider/usage are unknown,
  and no quorum was used.
- Final project XERJ refresh/check: exit 0, **170 files, 140/140 code**;
  unchanged engine freshness also passed. Actual persistent-preference and
  own restore/retry queries were checked against source. Credential-match audit
  covered **175 publishable files**, with zero selected-secret matches.

The completed NoError transaction is not a promise of disk-full diagnosis or
survival of a power loss while a write is pending. Server drafts, restart
restoration of reply target/edit/attachment caption, selected-dialog restoration,
remaining reference UI/capabilities, archive backup/file opening, live-account
acceptance and later channels remain open. The sequential migration goal remains
active.

The preceding code/quote head `e998e9c34d03f1f385f145d7ae1b81ad56acacd3`
passed [PR CI 38072274699](https://github.com/Mesteriis/makosh-native/actions/runs/38072274699)
and [push CI 38072272059](https://github.com/Mesteriis/makosh-native/actions/runs/38072272059).
Hosted CI for this later composer change is tracked after publication.

## Telegram reference message status indicators — 2026-10-10

Own native rendering now follows `ChatRightView`'s timestamp/clock/error and
single/double-check arrangement. The history adapter retains the engine's
`MessageHistoryEntry.isRead`; read-only changes update the guarded existing
window. Message-only search does not manufacture read context. Failed/sending/
queued flags take priority, including pending channel posts. Stable incoming
and broadcast posts have no check; unsupported namespaces are not called sent.
Saved/bot conventions have distinct descriptions and exclude support peers.

Actual evidence:

- `scripts/dev-db.sh up`: exit 0, PostgreSQL/S3 healthy. Full `scripts/test.sh`:
  exit 0, **293 XCTest (230 Telegram + 63 core), 0 failures**, and **22 Python
  regressions**. Seven added tests cover typed priorities/direction/namespaces,
  history versus search, delivery-only updates and stale window/chat/reset
  rejection. A real encrypted Postbox test observes sent → read on the same
  subscription, checks peer/namespace isolation and unchanged message content,
  then verifies the state after public Postbox release and reopen.
- The first focused run failed because production seed history holes clipped
  the manufactured random message. Committed-message/peer assertions and explicit
  removal of holes in this fully loaded synthetic fixture resolved it. The
  corrected fixture and full suite pass. Eighteen upstream t19 teardown
  diagnostics occur after the passing Telegram suite; raw logs remain private.
- `scripts/build-app.sh`: exit 0, including a later UI-only layout correction;
  strict ad-hoc signature verification passed. The full test suite preceded
  that Grid correction; the final build and native QA exercised it. Dependency
  preparation is unchanged; no additional reference-free rebuild is claimed.
- Final isolated native QA executable payload matched the built app. Accessible
  descriptions exposed all five ordinary states and no incoming status. Search
  → In History visibly showed clocks, the red failure indicator and single and
  double checks beside time. An initial flexible metadata frame widened short
  bubbles; a one-column native Grid with a trailing metadata cell restored
  their content width, verified in final screenshots. Code blocks still render.
  A capture error and a later `noWindowsAvailable` response interrupted the UI
  bridge; reselecting the exact task-owned app restored observation. Its process
  remained running; no new crash report appeared. The failed scroll action is
  not claimed as verified. No personal account, Keychain or network send was used.
- Two bounded source reviews found no remaining confirmed issue after the
  pending-broadcast correction. Root verified reviewed file hashes. Worker
  runtime metadata/usage are unknown; no quorum was used. Stable project XERJ
  refresh/check passed: **175 files, 145/145 code**. One earlier refresh refused
  freshness because source edits overlapped it; stale results were not reused.
  Actual own status/mapping and engine seed queries were checked against source.
  Credential-match audit checked 180 publishable files against four selected
  local secret fields: zero matches.

One check denotes a stored Telegram message, not recipient-device delivery;
group read state is not an individual reader list. All source-reference messages
conservatively retain one check; full crosspost/pinned/custom-mode presentation
remains open. Incoming mark-read, live server receipts/pending ID reconciliation,
other reference screens, earlier dossier acceptance and later channels remain
unfinished. This slice does not complete the sequential migration goal.

Preceding composer head `05217cf64add1b0e78ec5e34a7a9f46813fd7cc5` passed
[PR CI 38073276605](https://github.com/Mesteriis/makosh-native/actions/runs/38073276605)
and [push CI 38073273655](https://github.com/Mesteriis/makosh-native/actions/runs/38073273655).
Hosted CI for the later message-status change is tracked after publication.

## Telegram reference header search — 2026-10-10

The selected references remain the UI specification; this constraint is now
explicit in AGENTS.md. Telegram's permanent header search field was a confirmed
difference. Own SwiftUI code now follows TelegramSwift's right-hand search icon,
separate 44-point search row and cancellation that clears the query. A focused
scene command follows the reference's distinct Cmd-F behavior: open/focus the
field without erasing the query. The command is unavailable without a selected
Telegram chat. Search closes on chat change. No upstream UI code/assets copied.

Actual checks:

- `scripts/dev-db.sh up`: exit 0. Final `scripts/test.sh`: exit 0,
  **293 XCTest (230 Telegram + 63 core), 0 failures**, plus **22 Python tests**.
  Eighteen existing upstream t19 fixture-teardown diagnostics remain after the
  passing Telegram suite. The initial attempt stopped at compile errors in
  unfinished, unpublished history-read tests. Those files were preserved outside
  build/test sources while prioritizing this UI correction; they are not part
  of the delivered change or claimed as an integrated read-receipt feature.
- Final `scripts/build-app.sh`: exit 0; ad-hoc signature verified. The final
  focused-scene command correction followed the full test run; the subsequent
  final build and native QA exercised that UI-only change.
- A separate synthetic QA bundle's unsigned executable payload matched the
  final built app. Native accessibility and screenshots verified collapsed
  initial search, mouse opening with focus, actual fixture results, Cmd-F
  opening/focusing, repeated Cmd-F preserving the query, Escape and mouse close
  returning to history, a result's In History action, and chat switching clearing
  the old search. Cmd-F without a selected chat did not open search. Ten focused
  checks passed. No personal account, Keychain or Telegram network was used.
- Two bounded read-only source reviews found no confirmed issue in the final
  three UI files; root verified their hashes and owns runtime evidence. Worker
  model/provider/usage metadata are unavailable, and no quorum was used.
- Final project XERJ refresh/check passed: **176 files, 146/146 code**;
  TelegramSwift's locked reference fingerprint also passed. Actual title-bar
  and own focused-command queries were checked against source. The publication
  audit found zero matches for four selected local secret fields in 181 files.

This is a corrected reference workflow, not full visual parity. Sidebar/header
chrome, archive-state placement, themes/avatars, upstream search author/date
filters and result navigation, incoming mark-read, live-account acceptance,
earlier dossier GUI acceptance and later channels remain open. The sequential
migration goal remains active.

The preceding message-status head `4847417f7b351a9042fdcc4ced706bde88d2dd07`
passed [PR CI 38074067211](https://github.com/Mesteriis/makosh-native/actions/runs/38074067211)
and [push CI 38074063471](https://github.com/Mesteriis/makosh-native/actions/runs/38074063471).
Hosted CI for this header correction is tracked after publication.

## Telegram reference sidebar in the shared workspace — 2026-10-10

Telegram remains inside the common three-column WorkspaceView. The service
selector is followed by Telegram's chat list and conversation. Own SwiftUI
now follows the reference's 50-point list header, 40-point search row and
scrolling archive entry with a back action that cancels chat search. The large
branding/connection panel, segmented folder picker and permanent stop footer
are replaced by compact chrome. Connection details/stop remain in a popover.
The peer header no longer presents global connection state as peer presence.

The own PostgreSQL/S3 archive opens from a compact header button, distinct from
Telegram's archived-chat folder. It observes both archive and file controllers;
errors and activity remain visible on that button. Full status, errors and retry
are inside the existing archive sheet. Storage algorithms and schema are unchanged.

Actual evidence:

- `scripts/dev-db.sh up`: exit 0, PostgreSQL and S3 healthy. Full
  `scripts/test.sh`: exit 0, **293 XCTest (230 Telegram + 63 core), 0 failures**,
  and **22 Python regressions**. Eighteen existing upstream t19 teardown
  diagnostics follow the passing Telegram suite. The full suite preceded the
  later back-query and DEBUG/AX UI corrections; the final build/native QA
  exercised those changes. Only indentation changed after that final build.
- `scripts/build-app.sh`: exit 0; strict ad-hoc signature verification passed.
  The final synthetic QA executable payload matched that built app. Native
  screenshots and AX verified **15 focused conditions**: all six shared service
  choices and synthetic identification, Telegram conversation in the shared
  shell, archive folder/back query cancellation, preserved selection/draft
  across folder changes, honest unconnected mail, contacts in the same window,
  preserved draft across service switches, connection details, local archive
  records/status, an unconfigured file queue error, the retained button warning,
  and Cmd-F opening/closing in the shared scene. The synthetic draft was cleared.
  The file-queue error proves configuration-error visibility, not S3 outage
  recovery. No personal account, Keychain, Telegram connection or send was used.
- Actual unified-window QA exposed clipping caused by the DEBUG preview's
  outer VStack. A normal root on a separate empty synthetic PostgreSQL schema
  showed the headers correctly. A bottom-inset attempt then overlapped the
  footer. The final DEBUG route uses WorkspaceView directly, with its synthetic
  identifier in the native toolbar; final screenshots show both headers and
  footer. Failed/intermediate captures remain private. Production root unchanged.
- Two bounded final source reviews found no confirmed issue in the five UI
  files; root verified all reviewed SHA256 values. Workers did not run runtime
  gates; observed provider/model/usage are unavailable, and no quorum was used.
- Stable project XERJ refresh/check passed: **177 files, 147/147 code**;
  TelegramSwift's locked reference freshness passed. Actual sidebar/archive
  queries were confirmed against source. The publication audit checked four
  selected local secret fields against **182 publishable files**, with zero
  matches. No new dependency or copied upstream UI was introduced.

This slice verifies shared navigation and specific reference chrome, not full
Telegram parity. Themes/real avatars/presence, upstream filters and remaining
screens, incoming mark-read, live-account acceptance, earlier full-dossier GUI
acceptance, archive file opening/backup and later service implementations remain
open. The sequential migration goal remains active.

The preceding search head `d8214b3b291baead91929fdaf028c54bce38fd84` passed
[PR CI 38074869238](https://github.com/Mesteriis/makosh-native/actions/runs/38074869238)
and [push CI 38074866782](https://github.com/Mesteriis/makosh-native/actions/runs/38074866782).
Hosted CI for this shared-sidebar change is tracked after publication.
