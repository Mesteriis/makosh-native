# Telegram block13 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline, task-by-task. One whole-branch review at the end.

**Goal:** Complete the five approved Telegram communication parts in the existing workspace.
**Architecture:** Keep existing account-bound controllers and typed native boundaries. Small own DTO/provider/controller files isolate each workflow; TelegramCore remains the cryptographic authority. New VoIP source has an independent reviewed build lock.
**Tech Stack:** Swift6.2, SwiftUI/AppKit, TelegramCore/Postbox/TelegramApi, PostgreSQL/S3; native VoIP dependency selected by exact source/license/build audit.
**Spec:** docs/superpowers/specs/2026-10-13-telegram-block13-design.md

## Global Constraints

All invariants in the spec apply. No passcode/autolock; no personal-account QA;
permanent archive and per-chat S3 gate remain mandatory. No `.references` runtime
or copied outer UI. Missing media implementation cannot be reported as a call.

## Review Focus

- Account replacement between a result/picker/confirmation and callback must revoke old authority.
- Partial server lists, revoked rights, missing hashes and normalized ACKs must not authorize writes.
- Unknown/malformed peers, media and protocol versions must fail closed without dropping retained data.
- Secret TTL/deletion must preserve observed immutable archive versions and S3 policy.
- Call cancellation/device revocation must release capture and reject late transport callbacks.

### Task 1: Remote discovery and context-safe activation

**Files:** Create Sources/MakoshTelegram/TelegramRemotePeerSearch.swift and TelegramEngineRemotePeerSearch.swift; modify TelegramSearchModel.swift, TelegramModel.swift, Sources/MakoshApp/TelegramGlobalSearchResultsView.swift; test TelegramRemotePeerSearchTests.swift and TelegramRemotePeerSearchControllerTests.swift. Add a preparation-recipe helper only if required for native cache accumulation.
**Interfaces:** Consumes existing Account/Postbox, TelegramChat, TelegramSearchScope/Tracker. Produces remote peer result DTOs, independent cancellable search controller and context-validated activation for later member/secret workflows.
- [x] Test query admission, local/remote deduplication, malformed/min peer rejection, independent namespace identity, stale callback/activation, error/empty distinction and reconnect.
- [x] Run focused remote tests and observe RED; classify compilation/setup failures separately.
- [x] Implement typed contacts.search with native peer accumulation, explicit errors/deadline and the reference local-first result groups; preserve local suggestions and message search.
- [x] Run focused search/native Postbox tests: PASS. Inspect actual synthetic search/open/retry/rebind UI.
- [x] Commit this complete slice; record actual checks in the execution ledger.

### Task 2: Editable avatars and fallback photo

**Files:** Create TelegramAvatarEditing.swift, TelegramEngineAvatarEditing.swift, Sources/MakoshApp/TelegramAvatarEditingView.swift and corresponding Tests/MakoshTelegramTests/TelegramAvatarEditingTests.swift; modify existing profile presentation/model binding and docs/reference-interface.md.
**Interfaces:** Consumes existing photo preparation, immutable input/stage and profile identity/rights. Produces account-bound photo draft/change controller with explicit confirmation and refresh/uncertainty feedback.
- [x] Source-confirm own/fallback/group update and removal APIs/reference controls, then freeze their signatures and immutable basis in a task brief.
- [x] Test wrong account/rights/photo basis, malformed source, cancelled picker, ACK/error/timeout and account replacement; observe RED.
- [x] Implement native upload/update/removal and reference-derived UI using existing bounded preparation; never overwrite a later photo edit from stale consent.
- [x] Focused avatar/profile/native tests: PASS; synthetic native picker/draft/confirm/cancel/refresh QA; commit and ledger.

### Task 3: Invites, membership requests and admin history

**Files:** Create TelegramGroupMembership.swift, TelegramEngineGroupMembership.swift, Sources/MakoshApp/TelegramGroupMembershipView.swift and TelegramGroupMembershipTests.swift; modify existing peer-management view/model binding.
**Interfaces:** Consumes existing peer rights/snapshot/native actor identity plus task1 discovery. Produces cancellable member/link/request/event pages and fresh-confirmed membership mutations.
- [x] Verify pinned engine/native RPC signatures and reference list/navigation/confirmations in the brief.
- [x] Test pagination offsets/duplicates/incomplete responses, rights revocation, exact targets, stale context, false/empty ACK and uncertain writes; observe RED.
- [x] Implement add/invite, link create/revoke, requests approve/decline and admin-event history; explicitly show read errors and preserve current member/draft state.
- [x] Focused rights/membership/native tests: PASS; synthetic native lists/actions/cancellation/rebind QA; commit and ledger.

### Task 4: Secret-chat lifecycle, formatting, media and TTL

**Files:** Create TelegramSecretChatController.swift, TelegramEngineSecretChatProvider.swift and TelegramSecretChatLifecycleTests.swift; modify existing secret eligibility, composer/upload/history/archive boundaries and relevant profile/conversation UI. Native preparation changes go through the reviewed recipe only.
**Interfaces:** Consumes task1 peer selection, existing secret status/fingerprint, durable native outbox and permanent archive. Produces native creation/negotiation, safe formatted/reply/media admission and fresh-confirmed TTL controls.
- [x] Verify all current secret restrictions/native APIs and archive deletion observation before relaxing any gate; freeze exact resource/layer/key rules in the brief.
- [x] Test create/handshake/invalid keys/layers, stale consent, formatting/media rejection/admission, missing enqueue ACK, TTL/deletion retention and S3 OFF; observe RED.
- [x] Implement using native protocol/encryption and existing prepared resources; unsupported states remain explicit errors, not successful placeholders.
- [x] Focused secret/outbox/archive/native tests: PASS; synthetic lifecycle/TTL/composer/retention UI QA; commit and ledger.

### Task 5: Reviewed native audio/video calls

**Files:** Dependencies/TelegramVoip.lock.json, scripts/prepare-telegram-voip.py, native bridge target(s), TelegramCallController.swift, TelegramEngineCallProvider.swift, Sources/MakoshApp/TelegramCallView.swift, TelegramCallControllerTests.swift, native media boundary tests and build/notice integration.
**Interfaces:** Consumes existing Account.callSessionManager and native media permissions. Produces real native encrypted audio/video transport, safe incoming/outgoing lifecycle and reference-derived controls.
- [x] Audit exact tgcalls/WebRTC source, licenses, submodule closure, platform/build recipes and headers; record reproducible source/binary hashes. Build/test must not read reference checkouts or credentials.
- [x] Freeze exact native bridge signatures in the brief after source confirmation. Test malformed session/version/endpoint/key input, P2P policy, permission refusal, late signaling, cancellation/rebind and capture release; observe RED.
- [x] Build reviewed transport/codecs independently, wire native session/key/signaling state, explicit capture controls and one-to-one call UI. No fake connected state or signaling-only completion claim.
- [x] Focused call/native media tests: PASS; synthetic lifecycle and actual transport/media fixture proof; commit and ledger. Real Telegram calls are a separately scoped acceptance check.

### Task 6: Whole-block integration

**Files:** docs/development-status.md, docs/telegram.md, docs/reference-interface.md, THIRD_PARTY_NOTICES.md and only necessary build/CI integration files.
**Interfaces:** Consumes all five working slices and their immutable source/build/QA evidence.
- [ ] Review diff against all spec requirements and excluded block14 work. Record remaining actual runtime limitations, never silently re-scope a missing feature.
- [ ] Run scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh; all required checks exit0. Inspect changed native flows with isolated synthetic database config.
- [ ] Freeze public sources, refresh actual XERJ changed scopes and dispatch one bounded whole-branch reviewer. Resolve important findings with regression proof; record judgments.
- [ ] Publish PR, validate exact-head hosted build/tests and merge under existing user authorization. Verify actual merged state, equal tested tree and clean local main.
