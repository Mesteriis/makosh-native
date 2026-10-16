# WhatsApp block 1 implementation plan

> Execute inline with executing-plans; retain task evidence and decisions in the ledger.

**Spec:** docs/superpowers/specs/2026-10-15-whatsapp-block1.md

**Goal:** Protected independent WhatsApp core, QR connection, sessions, chats/history in the workspace.
**Architecture:** Zen-derived Rust facade and SQLCipher journal → framed local IPC → Swift service actor → encrypted PostgreSQL archive/projections → MainActor presentation.
**Tech stack:** Rust 1.97.0, whatsapp-rust 0.7.0, Diesel/SQLCipher, Swift 6.2, CryptoKit, PostgreSQL, SwiftUI/AppKit.
**Global constraints:** Preserve prior dirty work. No real-account access, reference runtime dependency, automatic session reset, private logs, media bytes in PostgreSQL or implicit network start. No commit/publication requested.
**Review focus:** FFI ownership/bounds, stop races, cache key verification, journal acknowledgement ordering, duplicate/version/delete retention, identity and paging isolation, UI generation checks and reproducible dependency/runtime closure.

- [x] Task 1: Independent Rust dependency and native ABI/cache foundation.
  Files: Dependencies/WhatsApp.lock.json, Dependencies/WhatsApp/{Cargo.toml,Cargo.lock,src/*,tests/*}, scripts/prepare-whatsapp.py, LICENSES/WhatsApp-*, THIRD_PARTY_NOTICES.md.
  Write failing tests for malformed/oversize ABI requests, stale handles, offline open, encrypted reopen/wrong key, duplicate ownership and stable paging. Implement per-account handle registry, bounded owned buffers, SQLCipher store and graceful lifecycle. Resolve/pin exact registry graph; review license/build features before compilation. Run cargo test/fmt/clippy. No reference installer or old session import.
- [x] Task 2: Protocol mapping and durable source journal.
  Files: Rust protocol/cache modules and tests.
  Failing tests: history/realtime mapping, edits/deletion keep text and versions, replay/ack boundary and timestamp ties. Implement Zen-derived Bot callbacks, transient QR expiry, connected/logout/disconnect states, append-only journal and read-only chat/history commands. Test with actual protobuf events without a network account. No automatic media fetch or mutation commands.
- [x] Task 3: Swift service, protected account store and PostgreSQL archive/projections.
  Files: Sources/MakoshWhatsApp/*, Tests/MakoshWhatsAppTests/*, Package.swift, scripts/{test.sh,build-app.sh}.
  Write failing native contract and PostgreSQL retention/replay/pagination tests. Implement worker-owned IPC sessions and keys, encrypted per-account metadata/projection, independent MessageArchiveStore writes before journal ack. Root integrates manifests and build/runtime packaging. Check missing keys, two accounts, cancel/close and stale snapshots.
- [x] Task 4: Common workspace and isolated native QA.
  Files: WhatsAppWorkspaceModel.swift, WhatsAppViews.swift, WorkspaceView.swift, MakoshApp.swift, model tests.
  Test selection/generation/cancellation behavior first. Match pinned Zen PairingView/sidebar/ChatRow/conversation source. Add accounts/QR/status/chat filters/search/paged history and isolated qa_whatsapp_ fixture route without personal Keychain/network. Build and inspect the actual signed app through native UI tooling. Preserve Telegram/mail behavior.
- [x] Task 5: Integration acceptance and documentation.
  Files: docs/{whatsapp-migration,development-status,reference-interface,architecture,main-thread-boundaries,service-integration}.md, README.md.
  Run scripts/dev-db.sh up, scripts/test.sh, scripts/build-app.sh and runtime/signature checks. Refresh XERJ changed scopes and confirm actual queries. Fresh same-model final reviewer on this block's bounded diff; fix significant findings with regression evidence. No commit/publication. Retain evidence and report real QA gaps honestly.

License decision (2026-10-15): user approved a separate Rust worker under AGPLv3 after Signal source headers contradicted Cargo MIT metadata. Swift does not link its code; keep main application licensing and provide separate worker notices/corresponding source.
