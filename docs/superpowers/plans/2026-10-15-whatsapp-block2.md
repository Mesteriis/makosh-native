# WhatsApp block 2 implementation

**Goal:** Complete the accepted remaining Zen workflows in Makosh's native workspace.
**Architecture:** Existing Swift service actors + encrypted PostgreSQL/S3 + separate
Rust/SQLCipher protocol process; concrete service contracts, no universal plugins.
**Tech Stack:** Swift6/macOS26, Rust1.97/whatsapp-rust0.7, libpq, encrypted S3.
**Spec:** docs/superpowers/specs/2026-10-15-whatsapp-block2.md
**Global Constraints:** Preserve dirty baseline, paused real QA, own pins/notices,
no secrets/logs/reference runtime, no automatic resend/deletion/retention expiry.
**Review Focus:** unknown submission, receipt regressions, media/S3 admission,
cross-account results, notification privacy, call teardown and dependency changes.

### Task 1: Durable outgoing attempts
Files: Sources/MakoshWhatsApp/WhatsAppOutbox.swift, WhatsAppRepository.swift,
WhatsAppPostgres.swift; Tests/MakoshWhatsAppTests/WhatsAppOutboxTests.swift.
Interfaces: consumes encrypted db transaction/seal/token; produces prepare,
claim, settle and resolve attempt APIs, immutable draft identity and snapshots.
- [ ] RED: real PG prepare/reopen/claim tests; expected missing API/failing behavior.
- [ ] Implement durable encrypted drafts, cross-process claim ownership and unique
  attempt settlement; ambiguous restart blocks replay and late settlement.
- [ ] GREEN: focused Swift tests; expected all new cases pass.

### Task 2: Protocol commands and receipts
Files: Dependencies/WhatsApp/src/{session,protocol,cache,commands}.rs;
Sources/MakoshWhatsApp/{WhatsAppModels,WhatsAppNativeSession,WhatsAppWorker}.swift;
native and Swift tests.
Interfaces: consumes Task1 attemptID; produces typed mutation results, enriched
journal/message DTO and monotonic receipts; explicit commands only.
- [ ] RED: offline command admission, malformed targets, receipt order and
  rich protobuf fixtures; expected new behavior absent.
- [ ] Implement text/reply/edit/revoke/reaction/forward/read and chat/profile/
  group/poll/contact/location controls based on the pinned SDK/reference.
- [ ] GREEN: Rust tests/clippy and Swift transport/worker tests pass.

### Task 3: Attachments and policy
Files: Sources/MakoshWhatsApp/WhatsAppFiles.swift; native media command module;
Core file contracts only where necessary; focused file tests.
Interfaces: consumes ArchiveFileRepository and message identity; produces bounded
transfer, authenticated local/S3 receipts, download/preview/export leases.
- [ ] RED: S3 OFF/new outgoing, toggle race, invalid file and encrypted reopen.
- [ ] Implement image/video/document/audio/sticker transfer without large IPC
  frames or database bytes; preserve preparation after uncertain submission.
- [ ] GREEN: real PG/S3 and native framing tests pass.

### Task 4: Status and rich history
Files: native protocol mapping/durability recipe, Swift presentation models/views.
Interfaces: consumes Task2 journal and Task3 media; produces retained status,
location/contact/poll/reply/reaction cards, search/star/pin/export workflows.
- [ ] RED: status acknowledgement failure and expired-but-retained fixtures.
- [ ] Implement non-destructive SDK durability and rich presentation paths.
- [ ] GREEN: actual protobuf/history tests pass, no source-string pseudo-tests.

### Task 5: Notifications and dossier/settings
Files: WhatsApp preferences/repository; App notification/controller/settings/
profile views; shared opaque notification registration only where necessary.
Interfaces: consumes committed incoming events, Core source contact contracts;
produces persisted show/preview/sound/S3 settings and source-scoped dossier links.
- [ ] RED: initial-history baseline, muted replay, account isolation, stale callback.
- [ ] Implement policy, notification routing and dossier/group/account controls.
- [ ] GREEN: synthetic PG/native notification and contact tests pass.

### Task 6: Calls and dependency closure
Files: reviewed Cargo/pin/notices/preparation; Rust call module; Swift call media/
controller/view; lifecycle/codec tests.
Interfaces: consumes account generation and SDK call handle; produces bounded
PCM/H264 IPC, explicit media permissions, incoming/outgoing/mute/end state.
- [ ] RED: bounded queues, stale generation and asynchronous teardown regressions.
- [ ] Review exact feature graph and implement owned native audio/video media.
- [ ] GREEN: native/media tests and source/package verification pass. Real calls
  stay unrun while live QA is paused.

### Task 7: Workspace completion and UI
Files: WhatsAppViews.swift, WhatsAppWorkspaceModel.swift, cohesive child views.
Interfaces: consumes Tasks1–6 worker APIs; produces reference-derived composer,
attachment previews, outbox/actions/settings/status/call/profile screens.
- [ ] RED: generation-safe action/model tests and native pre-change screenshots.
- [ ] Implement complete available controls, explicit uncertainty/error handling.
- [ ] GREEN: model tests and isolated native flows at normal/zoom sizes pass.

### Task 8: Integration acceptance
Files: docs/status, reference-interface, whatsapp-migration, architecture/boundaries,
service-integration, migration-plan, notices/readme/build recipe as changed.
Interfaces: consumes tested Tasks1–7; produces review packet and honest acceptance.
- [ ] Run dev-db up, scripts/test.sh, scripts/build-app.sh; inspect actual isolated UI.
- [ ] Verify pinned sources, corresponding source archive, signed ARM64 runtime.
- [ ] One fresh reviewer; one RED→GREEN fix pass for Important/Critical findings.
- [ ] Refresh changed XERJ scope/fingerprints, record checks/skips and live gaps.

Pre-flight failure inputs: lost send reply/restart (T1), late account result (T2/T7),
S3 toggle during preparation (T3), expired status replay (T4), muted notification
callback after account removal (T5), end call with queued media (T6).
