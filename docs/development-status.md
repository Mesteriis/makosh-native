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
- `scripts/test.sh`: exit 0, **41 XCTest tests, 0 failures**: 24 contact tests
  against real PostgreSQL plus 17 Telegram configuration, draft, crypto,
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
  freshness were checked. The original project prefix refused the new license notice schema (exit 1); a separate `mk-own-v2` refresh then completed with exit 0, 60 indexed files and 35/35 classified code files. Actual own-source queries resolved the credential loader, explicit saved-data action, lifecycle cleanup and draft acknowledgement. All ten fingerprints (own project, engine, eight references) are current. The mutable status ledger is deliberately outside its scope.

Runtime limits remain explicit: login, incoming sync, server delivery, reconnect,
real cache-corruption handling, 2FA and account-state transitions require a
user-connected test account and separate live acceptance. Main list/history are
bounded to 50 entries; pagination/media/secret-chat UI/read receipts and dossier
identity linking are not implemented. Drafts persist only in this app process.
See `telegram.md` for actual behavior, local credential configuration and limits.
Prior contact-only CI is green; the Telegram commit's actual hosted result must
be checked on its PR/Actions run before claiming hosted acceptance.
