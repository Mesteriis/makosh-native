# Development status — 2026-10-10

## Implemented first slice

Native SwiftUI/AppKit contact workspace, PostgreSQL persistence, contact create/edit/search, multiple phones/emails, organization/title/tags, notes, provenance, schema-1 JSON import, reasoned duplicate queue, explicit merge and guarded undo. Communication sections truthfully remain disconnected. Telemost provides an official-link browser handoff; no account/API integration is claimed.

The project started in an empty directory. The user selected the separate public repository `Mesteriis/makosh-native`; the existing `Mesteriis/makosh` is outside this task. PostgreSQL superseded the unpublished SQLite prototype at the user's request.

## Decisions and execution

1. Eight references cloned at exact locked SHAs, license/build/auth boundaries inspected, and real XERJ searches checked against source. Coverage and skips are in `xerj.md`; reference applications/dependencies were not built or authenticated.
2. Independently written MIT Swift domain core with libpq. PostgreSQL 18.6 development container, digest-pinned official image, localhost-only port and persistent named volume. One JSONB aggregate uses a transaction and row lock; this deliberately serializes writes and needs future measured scaling work.
3. Source/account/external-ID identity uses exact UTF-8 bytes. Manual overrides and observations survive imports. Merge retains source identities and snapshots; monotonic revisions prevent unsafe or stale undo.
4. Native shell/editor/import/dossier/merge review implemented. Local bundle links Homebrew libpq; it is ad-hoc signed and is not a standalone notarized distribution.

`Package.swift` declares macOS 26.0 and Swift tools 6.0. Local verification used arm64 macOS 27.0.1, Xcode 27 and Swift 6.4. Minimum deployment configuration does not prove runtime acceptance on every supported OS.

## Actual checks

- `./scripts/dev-db.sh up`: exit 0, healthy PostgreSQL 18.6. A synthetic SQL probe survived `down` and `up` (container recreation) in the named volume; probe schema then cleaned. Credentials are generated in ignored mode-0600 files and are not tracked.
- `./scripts/test.sh`: exit 0, **24 XCTest tests, 0 failures** against real PostgreSQL. Coverage includes persistence across connections, concurrent writes, atomic validation/trigger-induced rollback, unsupported schema preservation, opaque Unicode identities, import idempotence/manual overrides, candidate reasons, lossless merge, reimport routing and undo conflicts/ABA protection. The shipped three-contact synthetic fixture also passes import → merge → reimport → undo → reopen.
- `./scripts/build-app.sh`: exit 0 after review fixes; executable and local `.app` built, ad-hoc signing and strict signature verification succeeded.
- Python syntax, shell syntax and staged diff checks passed. Tracked-file audit excludes clones, indexes, database/configuration files and generated credentials.
- Two scoped read-only reviews found and fixed CI password masking and the UI refresh-after-commit retry hazard. Domain transaction review found no further actionable defects. This is bounded review, not a security certification or crash/network fault campaign.
- XERJ final project refresh: exit 0, 35 indexed files, 21/21 classified code files. Real queries retrieved PostgreSQL parameter/row-lock code and merge/undo definitions, confirmed against source. All eight locked reference fingerprints are current; completed runs with explicit skips retain exit 3 and are not relabeled clean.

## Native UI evidence and blocker

Real app accessibility state showed the PostgreSQL workspace and empty list. The create sheet was opened and all synthetic fields were verified (including two phones, email and tags). Save was invoked; a subsequent database query confirmed exactly one synthetic contact in the isolated QA schema. A fresh bundle using the final built executable payload reopened that schema and visibly listed the expected contact and organization. The QA bundle changed only identifier/display name/signature; executable payload equality was verified after removing signatures from temporary copies.

The computer-use bridge repeatedly returned `Sky Computer Use native pipe closed before response` after UI state changes, including sheet dismissal and dossier selection. App processes remained running. Rebinding/reset did not restore that session; a fresh QA bundle allowed initial observation, then the failure recurred. **Full GUI edit/import/merge/undo acceptance and screenshots remain unverified.** Core acceptance and database evidence do not substitute for those UI checks.

## Publication and next stage

Public first commit and the actual `macos-26` Actions run are pending the final source/index checks. CI uses an isolated native PostgreSQL server on the hosted macOS runner (Docker is the local development service); credentials are generated per run and masked before entering step environments. CI success is not yet claimed.

Next: complete the GUI flows when the native bridge is available, then perform the TelegramSwift exact GPL/dependency audit and a synthetic account adapter contract before any real account authorization. Mail/WhatsApp/Teams sync, contact export/backup, normalized SQL tables, reconnect/conflict UI, and distributable libpq packaging remain future work.
