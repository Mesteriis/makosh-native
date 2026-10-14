# Telegram block14 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Finish Telegram settings, reference presentation and portable archive recovery.

**Architecture:** Extend existing account-bound controllers and native settings.
Keep protocol operations in the pinned engine and archive portability in MakoshCore.
No replacement shell or private-account QA is introduced.

**Tech Stack:** Swift6.2, SwiftUI/AppKit macOS26+, PostgreSQL, CryptoKit, S3.

**Spec:** docs/superpowers/specs/2026-10-14-telegram-block14-design.md

## Global Constraints

- Native SwiftUI/AppKit, macOS26+, Apple Silicon; common service sidebar.
- No local Makosh passcode or autolock.
- No copied outer GPLv2-only UI/assets/credentials. Own MIT, combined GPLv3.
- Pinned engine, no build/run/test dependency on .references, no private logs.
- Permanent PostgreSQL archive survives deletion/TTL. Bytes live in S3.
- Explicit OFF forbids every new S3 copy, including preparation and restore.
- Real account/hardware acceptance waits for the separately selected test scope.

## Review Focus

- Closing or changing accounts during confirmed writes preserves uncertainty.
- QR expiry/events cannot resurrect cancelled login or overwrite password state.
- Midnight/timezone/theme changes affect only the selected Telegram workspace.
- Cache eviction/download cancellation never destroys retained archive/originals.
- Corrupt/incomplete backup and conflicting keys/targets fail before publication.

---
### Task 1: Connected websites

**Files:**
- Modify/Create: `Sources/MakoshTelegram/TelegramWebSessions.swift`
- Modify/Create: `Sources/MakoshTelegram/TelegramEngineWebSessionsProvider.swift`
- Modify/Create: `Sources/MakoshApp/TelegramWebSessionsView.swift`
- Modify/Create: `Sources/MakoshApp/TelegramSessionsView.swift`
- Modify/Create: `Sources/MakoshTelegram/TelegramModel.swift`
- Modify/Create: `Tests/MakoshTelegramTests/TelegramWebSessionsTests.swift`

**Interfaces:**
- Consumes: current native account/context controllers and the spec invariants.
- Produces: TelegramWebSessionsController.bind/open/close/refresh/apply; immutable account-bound snapshot and typed one/all changes.

- [x] Step1: Add `TelegramWebSessionsTests` regressions exercising malformed IDs, changed targets/sets, false or absent ACK, close/rebind/late result and uncertain write barrier; derive expected values independently.
- [x] Step2: Run `python3 .local/block3-focused-test.py --filter TelegramWebSessionsTests`. Expected: failure caused by missing behavior; compilation/setup failures are separately recorded and repaired.
- [x] Step3: Implement the specified interfaces in the listed focused files; confirm reference source before UI edits.
- [x] Step4: Run `python3 .local/block3-focused-test.py --filter TelegramWebSessionsTests`. Expected: all focused regressions pass.
- [x] Step5: Commit the slice and run task-done with that focused command. Expected: exit0.

### Task 2: QR sign-in

**Files:**
- Modify/Create: `Sources/MakoshTelegram/TelegramQRLogin.swift`
- Modify/Create: `Sources/MakoshTelegram/TelegramModel.swift`
- Modify/Create: `Sources/MakoshApp/TelegramAuthorizationView.swift`
- Modify/Create: `Tests/MakoshTelegramTests/TelegramQRLoginTests.swift`

**Interfaces:**
- Consumes: current native account/context controllers and the spec invariants.
- Produces: TelegramQRLoginController.start/cancel; native auth-transfer token source consumed by existing authorization lifecycle.

- [x] Step1: Add `TelegramQRLoginTests` regressions exercising expiry, bounded renewal, cancellation, login event, password transition and stale generation; derive expected values independently.
- [x] Step2: Run `python3 .local/block3-focused-test.py --filter TelegramQRLoginTests`. Expected: failure caused by missing behavior; compilation/setup failures are separately recorded and repaired.
- [x] Step3: Implement the specified interfaces in the listed focused files; confirm reference source before UI edits.
- [x] Step4: Run `python3 .local/block3-focused-test.py --filter TelegramQRLoginTests`. Expected: all focused regressions pass.
- [x] Step5: Commit the slice and run task-done with that focused command. Expected: exit0.

### Task 3: General and appearance

**Files:**
- Modify/Create: `Sources/MakoshTelegram/TelegramAppearancePreferences.swift`
- Modify/Create: `Sources/MakoshApp/TelegramSettingsView.swift`
- Modify/Create: `Sources/MakoshApp/TelegramTheme.swift`
- Modify/Create: `Sources/MakoshApp/TelegramConversationView.swift`
- Modify/Create: `Tests/MakoshTelegramTests/TelegramAppearancePreferencesTests.swift`

**Interfaces:**
- Consumes: current native account/context controllers and the spec invariants.
- Produces: Versioned local appearance/general preferences consumed by actual workspace/composer; bounded wallpaper preparation.

- [x] Step1: Add `TelegramAppearancePreferencesTests` regressions exercising invalid preferences, image bounds/metadata, midnight schedule, cancelled draft and service isolation; derive expected values independently.
- [x] Step2: Run `python3 .local/block3-focused-test.py --filter TelegramAppearancePreferencesTests`. Expected: failure caused by missing behavior; compilation/setup failures are separately recorded and repaired.
- [x] Step3: Implement the specified interfaces in the listed focused files; confirm reference source before UI edits.
- [x] Step4: Run `python3 .local/block3-focused-test.py --filter TelegramAppearancePreferencesTests`. Expected: all focused regressions pass.
- [x] Step5: Commit the slice and run task-done with that focused command. Expected: exit0.

### Task 4: Cache and transfer management

**Files:**
- Modify/Create: `Sources/MakoshTelegram/TelegramCacheController.swift`
- Modify/Create: `Sources/MakoshTelegram/TelegramCacheNative.swift`
- Modify/Create: `Sources/MakoshTelegram/TelegramAutoDownloadQueue.swift`
- Modify/Create: `Sources/MakoshApp/TelegramCacheSettingsView.swift`
- Modify/Create: `Tests/MakoshTelegramTests/TelegramCacheManagementTests.swift`

**Interfaces:**
- Consumes: current native account/context controllers and the spec invariants.
- Produces: Per-chat cache confirmations and transfer management reuse existing resource/context admission.

- [x] Step1: Add `TelegramCacheManagementTests` regressions exercising stale scans, busy resource, OFF chat, automatic/manual ownership separation, retention boundary; derive expected values independently.
- [x] Step2: Run `python3 .local/block3-focused-test.py --filter TelegramCacheManagementTests`. Expected: failure caused by missing behavior; compilation/setup failures are separately recorded and repaired.
- [x] Step3: Implement the specified interfaces in the listed focused files; confirm reference source before UI edits.
- [x] Step4: Run `python3 .local/block3-focused-test.py --filter TelegramCacheManagementTests`. Expected: all focused regressions pass.
- [x] Step5: Commit the slice and run task-done with that focused command. Expected: exit0.

### Task 5: Reference presentation

**Files:**
- Modify/Create: `Sources/MakoshApp/TelegramSettingsView.swift`
- Modify/Create: `Sources/MakoshApp/TelegramPeerProfileView.swift`
- Modify/Create: `Sources/MakoshApp/TelegramCallWindow.swift`
- Modify/Create: `Sources/MakoshTelegram/TelegramGroupAdminHistory.swift`
- Modify/Create: `Tests/MakoshTelegramTests/TelegramReferencePresentationTests.swift`

**Interfaces:**
- Consumes: current native account/context controllers and the spec invariants.
- Produces: Reference-derived profile/secret/admin/call presentation with existing typed controllers.

- [x] Step1: Add `TelegramReferencePresentationTests` regressions exercising protected event content, exact event/admin filters, terminated call recall and stale profile actions; derive expected values independently.
- [x] Step2: Run `python3 .local/block3-focused-test.py --filter TelegramReferencePresentationTests`. Expected: failure caused by missing behavior; compilation/setup failures are separately recorded and repaired.
- [x] Step3: Implement the specified interfaces in the listed focused files; confirm reference source before UI edits.
- [x] Step4: Run `python3 .local/block3-focused-test.py --filter TelegramReferencePresentationTests`. Expected: all focused regressions pass.
- [x] Step5: Commit the slice and run task-done with that focused command. Expected: exit0.

### Task 6: Portable archive recovery

**Files:**
- Modify/Create: `Sources/MakoshCore/MessageArchiveStore.swift`
- Modify/Create: `Sources/MakoshCore/MessageArchiveKeychain.swift`
- Modify/Create: `Sources/MakoshCore/ArchiveBackup.swift`
- Modify/Create: `Sources/MakoshCore/ArchiveFileRepository.swift`
- Modify/Create: `Sources/MakoshApp/TelegramArchiveBackupView.swift`
- Modify/Create: `Tests/MakoshCoreTests/ArchiveBackupTests.swift`

**Interfaces:**
- Consumes: current native account/context controllers and the spec invariants.
- Produces: Authenticated manifest/key envelope; snapshot export/inspect/restore into new empty target without overwrite or S3 OFF bypass.

- [x] Step1: Add `ArchiveBackupTests` regressions exercising wrong key/corruption/truncation/path escape, consistent snapshot, existing target/key conflict, object integrity and OFF before copy; derive expected values independently.
- [x] Step2: Run `python3 .local/block3-focused-test.py --filter ArchiveBackupTests`. Expected: failure caused by missing behavior; compilation/setup failures are separately recorded and repaired.
- [x] Step3: Implement the specified interfaces in the listed focused files; confirm reference source before UI edits.
- [x] Step4: Run `python3 .local/block3-focused-test.py --filter ArchiveBackupTests`. Expected: all focused regressions pass.
- [x] Step5: Commit the slice and run task-done with that focused command. Expected: exit0.

### Task 7: Native acceptance and integration

**Files:**
- Modify/Create: `docs/development-status.md`
- Modify/Create: `docs/reference-interface.md`
- Modify/Create: `docs/telegram.md`

**Interfaces:**
- Consumes: current native account/context controllers and the spec invariants.
- Produces: Verified native artifacts and actual UI evidence; independent whole-branch review and exact-head merge.

- [x] Step1: Run `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh`. Expected: all exit0; any skips named.
- [x] Step2: Inspect actual native changed flows in a dedicated synthetic QA app/schema. Expected: concrete visible outcomes, no private accounts.
- [x] Step3: Refresh/check project/ref/engine XERJ and review the complete diff. Expected: fresh evidence; actual failures retained.
- [x] Step4: Commit verified docs, perform one independent whole-branch review and one TDD fix pass. Expected: no unresolved Important/Critical.
- [x] Step5: Publish PR, attach, wait for exact-head checks and merge under existing authorization; verify final tree. Expected: exact checked tree integrated.
