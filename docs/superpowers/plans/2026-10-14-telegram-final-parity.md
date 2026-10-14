# Telegram Final Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan inline task-by-task. Steps use checkbox syntax.

**Goal:** Закрыть перечисленные остатки Telegram одним проходом, кроме смены устройств в активном звонке.

**Architecture:** Account-owned cache maintenance and manual-transfer journal are separate from window-owned previews/automatic downloads. Existing native appearance and call views consume bounded typed state; reference behavior is independently implemented.

**Tech Stack:** Swift6.2, SwiftUI/AppKit, Postbox/TelegramCore pinned engine, PostgreSQL, S3, CoreGraphics/AVFoundation.

**Spec:** docs/superpowers/specs/2026-10-14-telegram-final-parity-design.md

## Global Constraints

- Native SwiftUI/AppKit, macOS26+, Apple Silicon; common service sidebar.
- Own MIT/combined GPLv3; no GPLv2-only UI/assets/API credentials; build independent of `.references/`.
- Permanent PG versions/S3 never deleted by cache; explicit S3 OFF forbids every new copy.
- Bind every operation to account/context/generation; refuse changed/unknown source and stale callbacks.
- Synthetic isolated QA; real Telegram account supplied by user at end; local passcode/autolock excluded.
- Live call device switching is an accepted gap; next-call selection retained.

## Review Focus

1. Active native cache leases and shared resources change during an age/size scan: no forced deletion or loss of outgoing originals.
2. A transfer finishes after chat/account change or restart while S3 policy changes to OFF: original attribution and current policy win.
3. Malformed/gzipped SVG patterns, extreme paths and alpha values: bounded decode, no external access, atomic apply.
4. A ringing call disappears while its window is hidden; video avatar changes mid-fetch: all audio/video owners release correctly.
5. Video preview movement/control hiding with resize, keyboard and VoiceOver: controls remain recoverable and End reachable.

---

### Task 1: Account-owned age/size cloud cache maintenance

**Files:** Create Sources/MakoshTelegram/TelegramCacheMaintenance.swift and Tests/MakoshTelegramTests/TelegramCacheMaintenanceTests.swift; modify TelegramCacheController.swift, TelegramCacheNative.swift, TelegramEngineCacheProvider.swift, TelegramModel.swift, Sources/MakoshApp/TelegramCacheSettingsView.swift.

**Interfaces:** Consumes existing TelegramCacheProvider.scan/clear, TelegramCacheSnapshot and permitsClear barrier. Produces TelegramCacheRetention (Codable, validated days/limit), TelegramCacheItem.modifiedAt:Int64? and TelegramCacheMaintenance.bind(provider:)/update(_:) account-owned scheduler. Provider gains exact selected-item deletion, preserving legacy clear callers.

- [ ] Write tests: testAgeSelectsOnlyKnownExpiredResources (cutoff equality stays), testSizeEvictsOldestAfterAge (ties stable), testFutureUnknownAndActiveRemain, testChangedScanRefusesRemoval, testRebindRejectsStaleCompletion, testPreferencesRoundTripAndRejectMalformed. Literal timestamps/bytes; explicit provider boundary fake only for asynchronous native side effects.
- [ ] Run `python3 .local/block3-focused-test.py --filter TelegramCacheMaintenanceTests`. Expected: RED missing feature; then implement typed selection + separate scheduler and native timestamp reading/fresh exact-item resolve/removal force:false. Wire barrier/account lifetime and grouped controls1/7/31/forever,5/16/32/unlimited.
- [ ] Run same filter plus TelegramCache tests. Expected: GREEN all, no false ACK. Commit task.
- [ ] Task-done command: `python3 .local/block3-focused-test.py --filter 'TelegramCache'`. Expected: exit0.

### Task 2: Durable manual transfers across chat selection

**Files:** Create TelegramDownloadJournal.swift, TelegramEngineDownloadJournal.swift, TelegramBackgroundDownloadTests.swift and TelegramBackgroundDownloadArchiveTests.swift; modify TelegramMediaController.swift, TelegramEngineMediaProvider.swift, TelegramFileArchiveController.swift, TelegramPlaybackController.swift, TelegramModel.swift, Sources/MakoshApp/TelegramDownloadsView.swift, TelegramAttachmentActions.swift, TelegramVisualMediaView.swift and Tests/MakoshTelegramTests/TelegramMediaIntegrationTests.swift. Existing transfer management/automatic/cache tests are regression consumers.

**Interfaces:** Consumes TelegramMediaTransfer token/context, TelegramAttachmentSource and existing completedFullFile/reserveAutomaticFile policies. Produces account-owned retained manual full jobs, bounded journal records (message IDs/attachment IDs/state plus name/byteCount/photo validation metadata), encrypted Postbox store, native fresh resolver. No resource paths/access hashes/bytes. Manual transfer context lasts until account rebind; automatic/preview ownership stays visible-window-bound.

- [ ] Write tests: testManualLeaseSurvivesUnrelatedChatRetention, testAutomaticPreviewStillCancelOnLeave, testStaleAccountTransferCannotCancelReplacement, testManualRetryPreservesOriginalAttribution, testJournalRoundTripAndBounds, testRestartChangedSourceRefuses, testPersistenceFailureVisible, testS3OffAtCompletionRefusesCopy. Expected literal original identities/lease use and actual metadata persistence.
- [ ] Run `python3 .local/block3-focused-test.py --filter 'TelegramBackgroundDownloadTests|TelegramTransferManagementTests'`. Expected: RED behavior/lacking journal. Implement sources pinned by account manual jobs, journal writes serialized with revision/generation, bounded fresh resume resolver and explicit failure state. No resource path/access hash persistence. Manager wording/account-wide exports follow pinned transfers.
- [ ] Run same tests plus AutomaticDownload/MediaController tests. Expected: GREEN, visible automatic barrier preserved. Commit task.
- [ ] Verify advancing progress/growing partial data renew the60second idle deadline; duplicate/invalid progress does not. Same-file previews stop on chat leave, queued manual jobs block cache removal, stale timer/restore/cleanup callbacks cannot act on renewed or replacement state.
- [ ] Verify manual capture backpressure/frozen recipes, callback capture admission and whole-file export during `capturing`. Actual PG/S3 test grants8FDs, injects direct pressure/config failure, unlinks original and restores exact bytes. OFF progresses with8blocked copies and a5second policy refresh unblocks an already waiting file. Pending capture errors remain visible until waiting data is resolved.
- [ ] Task-done command: `python3 .local/block3-focused-test.py --filter 'TelegramBackgroundDownload|TelegramTransferManagement|TelegramMediaController|TelegramMediaIntegration|TelegramAutoDownload|TelegramAutomaticArchiveReservation|TelegramFileArchiveController|TelegramPlayback|TelegramCache'`. Expected: exit0.

### Task 3: Complete bounded wallpaper and palette variants

**Files:** Create TelegramWallpaperPattern.swift and TelegramWallpaperVariantTests.swift; modify TelegramAppearancePreferences.swift, TelegramCloudPalette.swift, TelegramEngineAppearanceCatalog.swift, TelegramWallpaperFiles.swift, Sources/MakoshApp/TelegramWallpaperEditor.swift and TelegramAppearanceCatalogView.swift, TelegramAppearanceCatalog.swift, TelegramView.swift, TelegramMessageTextView.swift, WorkspaceView.swift and TelegramSettingsView.swift. Native SVG rendering is preflight allowlisted; no new dependency.

**Interfaces:** Consumes existing preference encoding/local UUID images and catalog prepare. Produces1–4color wallpaper with two-color45degree rotation and3/4color placement advance and normalized pattern overlay/intensity; legacy solid/gradient/image decode unchanged. Palette alpha encoded with actual SwiftUI consumer support.

- [ ] Write tests: testFourColorWallpaperRoundTrip, testPatternMalformedExternalAndComplexityRefusal, testPatternIntensityAndRotationPixels, testPaletteAlphaSurvivesPersistenceAndRendering, testOldPreferencesStillDecode, testCloudPatternUsesBoundedDecoder. Test real renderer output/side effects; no source-text checks.
- [ ] Run `python3 .local/block3-focused-test.py --filter 'TelegramWallpaperVariantTests|TelegramAppearance'`. Expected: RED. Implement bounded owned decoding/rendering, matching reference editor/color/pattern workflow; private atomic file writes and same preview/application renderer.
- [ ] Run same filter + wallpaper/palette tests. Expected: GREEN. Commit task.
- [ ] Task-done command: `python3 .local/block3-focused-test.py --filter 'TelegramWallpaper|TelegramAppearance|TelegramCloudPalette'`. Expected: exit0.

### Task 4: Call video avatars, decoration/audio/key and video controls

**Files:** Create TelegramCallPresentation.swift and TelegramCallPresentationTests.swift; create TelegramAvatarVideoPlayback.swift, TelegramCallEmojiTable.swift, Sources/MakoshApp/TelegramCallPresentationViews.swift, TelegramAvatarVideoTests.swift and TelegramCallWindowPresentationTests.swift; modify Sources/MakoshApp/TelegramCallView.swift, TelegramAvatarStore.swift, TelegramEngineAvatarProvider.swift and TelegramNativePlaybackEngine.swift plus its tests and TelegramSyntheticPeerAppearance.swift for owned QA video. Approved GPLv3 key dataset and recipe/lock/notices only if exact license reviewed. Update docs/reference-interface.md and docs/telegram.md including accepted live-device gap.

**Interfaces:** Consumes TelegramCallController.call/incoming/fingerprint/localFrame/remoteFrame and account-bound avatars. Produces state-derived ringtone/wave, compatible emoji key, muted video-avatar owner, bounded preview corner and activity visibility state. No new capture or live device switches.

- [ ] Write tests: testCallKeyKnownVectors, testRingtoneStopsOnConnectEndAndOwnerLoss, testVideoAvatarStaleResourceCannotPublish, testReduceMotionStopsDecoration, testVideoControlsRevealWithKeyboardAndVoiceOver, testPreviewClampsAfterResize. Boundary sound/video doubles only beneath owned real state machine.
- [ ] Run `python3 .local/block3-focused-test.py --filter 'TelegramCallPresentationTests|TelegramAvatar'`. Expected: RED. Implement existing own native view conventions and reviewed compatible key mapping, synthetic local sound, teardown and accessibility.
- [ ] Run same filter + call/audio tests. Expected: GREEN. Commit task.
- [ ] Task-done command: `python3 .local/block3-focused-test.py --filter 'TelegramCall|TelegramAvatar'`. Expected: exit0.

### Task 5: Integrated native acceptance, final review and integration

**Files:** New private owned QA helpers/evidence only; docs/development-status.md, docs/reference-interface.md, docs/telegram.md, docs/roadmap.md. No real identity operations.

**Interfaces:** Consumes all previous public controllers/views and background owners. Produces actual observed native evidence, complete check results and exact-head merged source. User's real-account acceptance remains pending until supplied.

- [ ] Run `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` through preserved raw logs. Expected: all exit0, enumerate any actual skip.
- [ ] Launch dedicated owned synthetic bundle/schema/config. Observe changed cache controls/background transfers/restart/wallpaper/palette/call/key/preview/autohide with real UI, verify PostgreSQL/S3 policy outcomes and strict signature. Record observed vs synthetic-only/hardware-only evidence distinctly.
- [ ] Final one inherited-model independent whole-branch review; regrade by user effect, one RED→GREEN fix pass for Important/Critical and full suite. Expected: no unresolved Important/Critical. No per-task implementer/reviewer dispatch.
- [ ] Update exact result docs. Create/attach PR with source head, wait required exact-head CI, merge under standing authorization and prove main matches checked tree. Stop only owned QA, archive owned evidence/delete only this plan's private workspace.
- [ ] Task-done command: `scripts/test.sh`. Expected: exit0; follow build/native checks after fixes where changed.

Self-review: five spec sections map to tasks1–5; all cross-task interfaces named,
review-focus inputs have regression owners. This single plan follows explicit
user request over author default suggestion to split independent projects/approval stages.
