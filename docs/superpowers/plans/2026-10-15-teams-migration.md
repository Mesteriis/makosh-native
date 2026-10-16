# Teams Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking. Native inline execution is recommended here; the user must review this plan and choose the method before implementation.

**Goal:** Transfer the selected teams-cli Graph/OAuth workflows and required Makosh storage/file/notification/dossier integration into the native workspace.

**Architecture:** A concrete MakoshTeams Swift service owns Microsoft Graph, OAuth, persistence, files and background synchronization. MainActor models only conduct native UI and scoped commands. Encrypted service journals/checkpoints feed the existing permanent Core archive through durable idempotent projection jobs; no shared protocol engine or additional terminal/Rust shell is introduced.

**Tech Stack:** macOS26+, Apple Silicon, Swift6, Foundation/URLSession, Network, Security, CryptoKit, SwiftUI/AppKit, existing MakoshCore/libpq/PostgreSQL and encrypted S3/local preparation.

**Execution status (2026-10-16):** All nine tasks complete with tests, one read-only review/fix pass and native synthetic UI. Real-account/OS/release acceptance remains pending. Exact outcomes and deviations are retained in the task ledger and development-status.md. Checked command steps use the recorded prepared SwiftPM equivalent during iterations; full scripts/test.sh passed at integration.

**Spec:** [approved Swift design](../specs/2026-10-15-teams-migration-design.md).

## Global Constraints

- Use teams-cli9c8a72c32369f9d9bd15b793099522a80070a063; independent product pin/notices, no build/run/test dependency on `.references/` or a prior project.
- Work/school delegated accounts, initially the global Microsoft cloud. Own/configured Entra public client; no borrowed reference client ID, desktop tokens, passwords, client secret or existing private stores.
- Preserve the current feature branch and dirty baseline. No branch switch, per-task commit, merge/push/publication, dependency update or unrelated cleanup; record raw outputs and per-task source hashes in ignored evidence instead of commit-range helpers.
- Service-owned executors handle protocol/SQL/keys/crypto/parsing/files. Constructors perform no IO. Keep actor checks, cancellation/generation fencing and asynchronous release.
- Retain every received version indefinitely; no TTL/pruning, remote-delete purge or invented deletion from an absent page. Files are encrypted S3/local payloads, never PostgreSQL bytes.
- S3 scope is service/account/conversation; one-to-one default ON, group/meeting/channel/unknown default OFF. OFF forbids all new copies, including preparation/retries; no automatic local promotion.
- Persist remote mutations before dispatch; unknown survives restart, forbids replay and rejects stale settlement. Locks are PostgreSQL session advisory ownership across processes.
- Native attachment guardrails:10 files/submission,100MiB/file. No anonymous/org-wide sharing links, invitation emails or cleanup deletion of user/provider/archive files.
- One application notification delegate; opaque Teams routes and encrypted preferences; initial history/muted events never replay as fresh notifications.
- `--teams-synthetic-preview` must require explicit configuration and qa_teams_ prefixes for BOTH application/archive schemas; fake keys/transport only, no real browser/provider/account/Keychain checks.
- Real account/TCC/OS banner acceptance stays paused. Personal Teams/calls/screen sharing/tenant administration/chat creation/outgoing edit-delete-reaction operations and release/notarization are outside this reference transfer.
- The /shares lookup requires Files.ReadWrite despite being a lookup. Explain its additional capability; absence means unavailable file, never automatic consent/elevation or `redeemSharingLink`.
- Commands below are intended future checks, not results already obtained. Expected RED must be observed before the corresponding production change; actual output/exit code goes into the task ledger.

## File Structure and Shared Contracts

New source is under `Sources/MakoshTeams/`; App views/models use `Sources/MakoshApp/Teams*.swift`; tests use `Tests/MakoshTeamsTests/`. No Telegram/WhatsApp types enter Teams. Proposed new names/signatures below are design contracts, not claims that they exist already.

- Models/Graph: TeamsModels.swift, TeamsHTTP.swift, TeamsGraphClient.swift, TeamsGraphMutations.swift; exact resource IDs, bounded HTTP and typed Graph pages/errors.
- Authorization: TeamsOAuth.swift, TeamsOIDC.swift, TeamsLoopbackAuthorization.swift, TeamsTokenVault.swift; pending grants, token validation, loopback and checked Keychain.
- Storage: TeamsPostgres.swift, TeamsRepository.swift, TeamsArchiveProjection.swift, TeamsOutbox.swift; encrypted current/append-only/page/job/attempt rows and advisory leases.
- Runtime: TeamsWorker.swift, TeamsSession.swift, TeamsSynchronization.swift; account lifetime, refresh ownership and resumable sync.
- Files: TeamsFiles.swift, TeamsGraphFiles.swift, TeamsFileSubmission.swift; preparation/download/Graph upload/sharing and exact archive resources.
- Notifications: TeamsNotifications.swift and App TeamsSystemNotifications.swift; durable local unread/events/rules and OS routing.
- UI: TeamsWorkspaceModel.swift, TeamsViews.swift, TeamsConnectionView.swift, TeamsComposeView.swift, TeamsOutboxView.swift, TeamsHistoryView.swift, TeamsChatSettingsView.swift, TeamsSettingsView.swift; conductors and views with no service IO.
- Root integration: Package.swift, scripts/test.sh, scripts/build-app.sh, WorkspaceView.swift, MakoshApp.swift, TelegramSystemNotificationRouter.swift; root alone owns these shared edits and public integration docs/Git.
- Provenance: Dependencies/Teams.lock.json, Dependencies/Teams/README.md, LICENSES/Teams-cli-MIT.txt, THIRD_PARTY_NOTICES.md, scripts/verify-teams-dependencies.py and its test.

Primitive contracts used throughout:

```swift
enum TeamsResource: Codable, Sendable {
  case chat(String)
  case channel(teamID: String, channelID: String)
  case thread(teamID: String, channelID: String, rootID: String)
}
struct TeamsScope: Codable, Sendable {
  let accountID: UUID
  let tenantID: String
  let resource: TeamsResource
}
struct TeamsPrincipal: Codable, Sendable {
  let tenantID: String; let userID: String; let displayName: String
}
struct TeamsAccountContext: Sendable {
  let accountID: UUID; let principal: TeamsPrincipal
}
struct TeamsContinuation: Codable, Sendable {
  let owner: TeamsCollection; let url: URL
}
struct TeamsPage<Item: Codable & Sendable>: Sendable {
  let values: [Item]; let next: TeamsContinuation?
}
```

Task1 defines Codable/Hashable/Equatable value models and byte-exact resource/tenant
equality, a collision-free canonical storage key and `policyScope` mapping a
thread to its owning channel. TeamsCollection identifies chats/joinedTeams/
channels/messages/replies/members and its account/tenant/path owner. These are
service contracts, not a universal plugin interface.

## Review Focus

1. A hostile/alternate nextLink, encoded ID or redirected file URL must not change the account/collection or carry a bearer credential to another origin — Task1/6 tests.
2. Grant cancellation, token rotation and a different verified tenant during a suspended refresh must preserve the old session and reject obsolete publication — Task2/4 tests.
3. Channel reply-chain reordering, discontinuous/invalid continuation and a crash between service-journal/Core-archive commits must not lose versions or fabricate completeness/deletion — Task3/4 tests.
4. A changed/partial chat roster, ambiguous upload/share response and late message completion must not broaden file access or replay a prior mutation — Task5/6 tests.
5. Preview/sound/account policy changes during OS consent/callback and a new selection during settings/dossier loading must never target or display the old context — Task7/8 tests.

---

### Task 1: Typed Graph boundary, independent provenance and test fixtures

**Files:** Create TeamsModels.swift, TeamsHTTP.swift, TeamsGraphClient.swift; Dependencies/Teams.lock.json, Dependencies/Teams/README.md, LICENSES/Teams-cli-MIT.txt, scripts/verify-teams-dependencies.py, scripts/test-teams-dependencies.py; Tests/MakoshTeamsTests/TeamsGraphTests.swift and TeamsTestSupport.swift. Modify Package.swift, THIRD_PARTY_NOTICES.md, scripts/test.sh and scripts/build-app.sh only to include this service/tests and verifier.

**Interfaces:** Produces primitive contracts above; public TeamsAccount (id/name/clientID/authority/verifiedPrincipal/readOnly), TeamsTeam/TeamsChannel (exact IDs/parent team/display name), TeamsConversation, TeamsPerson, TeamsGraphUser (id/displayName/mail; no assumed tenant claim), TeamsMessage (id/scope/body/author/source timestamps/deletion/attachments/replyTo), TeamsAttachment (metadata, no bytes), TeamsFailure; `TeamsHTTPTransport.response(to: URLRequest) async throws -> TeamsHTTPResponse`; actor `TeamsGraphClient(context: TeamsAccountContext, transport: any TeamsHTTPTransport)` with `identity(token: String) async throws -> TeamsGraphUser` and `page<Item: Codable & Sendable>(_: Item.Type, collection: TeamsCollection, continuation: TeamsContinuation?, token: String, limit: Int = 50) async throws -> TeamsPage<Item>`.

- [x] Write `testBoundedPagePreservesOverflowAndBindsContinuation`, `testRejectsCrossAccountCursorAndHostBeforeTransport`, `testOpaqueIDsCannotEscapePath`, `testStreamingJSONLimitAndRedirectRejection`, `testReadRetryHonors429`. Script synthetic pages/HTTP delegates, not a fake GraphClient implementation. Mutation no-retry proof belongs to Task5, where the mutation API is introduced.

```swift
XCTAssertEqual(page.values.map(\.id), ["m0", "m1", "m2"])
XCTAssertEqual(page.next?.owner, collection)
XCTAssertEqual(transport.requests.count, 1) // no silent overflow refetch/drop
```

- [x] Run `scripts/test.sh --filter TeamsGraphTests`. Expected RED: missing module/APIs first, then the overflow/URL/delegate regressions fail before their fixes.
- [x] Implement the new target and value/HTTP contracts. Use an ephemeral session, early bounded body/delegate processing,30s request timeout and4MiB JSON cap. Authenticated traffic only https://graph.microsoft.com:443/v1.0/, no userinfo/fragment or automatic redirects; encode each opaque path component. Bind continuation ownership and reject cycles; do not truncate returned items. Read retries are bounded to3 attempts and respect Retry-After; remote mutations are not retried.
- [x] Record original source/file/license hashes from the reviewed clean reference independently; record which Swift files adapt its contracts. The verifier uses repository-owned pin/notices, not a research checkout or provider configuration. Add negative verifier cases for changed source/license and accidental reference client ID/runtime path adoption. No Rust dependency graph is linked by this Swift choice.
- [x] Run the scoped Graph tests and `python3 scripts/test-teams-dependencies.py`. Expected GREEN, no network/account/keyring access. Checkpoint owned files/hashes/raw results; leave prior dirty files intact.

### Task 2: OAuth grants, identity validation and private token storage

**Files:** Create TeamsOAuth.swift, TeamsOIDC.swift, TeamsLoopbackAuthorization.swift, TeamsTokenVault.swift; Tests/MakoshTeamsTests/TeamsOAuthTests.swift, TeamsOIDCTests.swift and TeamsTokenVaultTests.swift; extend TeamsTestSupport.swift with an injected clock, fake vault and actual generated synthetic RSA/JWK fixtures.

**Interfaces:** Consumes Task1 HTTP/identity/context values. Produces TeamsOAuthConfiguration, TeamsCapability, TeamsTokenBundle, TeamsVerifiedSession, TeamsPKCEChallenge, TeamsDeviceChallenge/TeamsDevicePollResult; actor TeamsOAuthClient methods `beginPKCE(configuration: TeamsOAuthConfiguration, capabilities: Set<TeamsCapability>, callbackURL: URL) -> TeamsPKCEChallenge`, `exchange(challenge: TeamsPKCEChallenge, callback: Data) -> TeamsTokenBundle`, `beginDevice(configuration: TeamsOAuthConfiguration, capabilities: Set<TeamsCapability>) -> TeamsDeviceChallenge`, `pollDevice(challenge: TeamsDeviceChallenge, now: Date) -> TeamsDevicePollResult`, `refresh(bundle: TeamsTokenBundle, configuration: TeamsOAuthConfiguration) -> TeamsTokenBundle`, `verifyIdentity(bundle: TeamsTokenBundle, configuration: TeamsOAuthConfiguration, expected: TeamsPrincipal?) -> TeamsVerifiedSession`; actor TeamsTokenVault `load(accountID: UUID) -> TeamsTokenBundle?`, `save(_: TeamsTokenBundle, accountID: UUID)`; actor TeamsLoopbackAuthorization `start() async throws -> URL`, `callback() async throws -> Data`, `cancel() async`. All OAuth network/verification/vault methods throw and are awaited by callers; token bundle is service-private, never published to UI. Capability cases are basicChats, teams, channelHistory, sendChat, sendChannel, readFiles, resolveSharedLink, writeFiles and writeSharedFiles; TeamsAuthorizationMethod is browserPKCE or deviceCode.

- [x] Write `testFragmentedCallbackWrongStateCannotConsumeGrant`, `testDeviceSlowdownPersistsAndExpiryStops`, `testOIDCRejectsWrongSignatureAudienceIssuerNonceAndTenant`, `testOpaqueAccessTokenIsNotParsedAsIdentity`, `testRefreshWithoutReplacementPreservesOldRefreshToken`, `testVaultFailurePreservesExistingCredential`.

```swift
XCTAssertEqual(nextDelayAfterTwoSlowdowns, initialDelay + 10)
XCTAssertEqual(refreshed.refreshToken, original.refreshToken)
XCTAssertEqual(try await vault.load(accountID: account), original)
```

- [x] Run `scripts/test.sh --filter 'TeamsOAuthTests|TeamsOIDCTests|TeamsTokenVaultTests'`. Expected RED for missing APIs and the targeted validation/cancellation cases before implementation.
- [x] Implement public-client PKCE S256/state/nonce and device polling with at least the provider interval; slow_down adds5s to subsequent polls, not just one sleep. Loopback binds127.0.0.1 on an owned random port, limits headers/callback input to8192 bytes and expires after300s; unrelated/malformed requests do not finish the grant. Use a cancellable owned listener, not blocking main-thread IO.
- [x] Validate RS256 ID tokens with actual Security verification and trusted authority metadata/JWKS; reject unknown/none algorithms, mismatched issuer/audience/nonce/principal and stale times. Access tokens are opaque. Verify /me matches the validated principal. Implement checked Keychain Add/Update/Copy; no environment/reference credential import or automatic delete/reset. Hide raw provider text/token URLs in errors/logs. Capability mapping is the spec's table; additional grants are explicit.
- [x] Run the scoped tests. Expected GREEN with synthetic transport/keys; actual RSA verification and listener fragmentation/cancellation are exercised. Checkpoint results; real auth remains unrun.

### Task 3: Encrypted account journal, archive projection and cross-process leases

**Files:** Create TeamsPostgres.swift, TeamsRepository.swift, TeamsArchiveProjection.swift; Tests/MakoshTeamsTests/TeamsRepositoryTests.swift and TeamsArchiveTests.swift. Modify Sources/MakoshCore/MessageArchiveStore.swift and Tests/MakoshCoreTests/MessageArchiveStoreTests.swift only for rich-payload-aware append deduplication if the new regression reproduces it.

**Interfaces:** Produces TeamsRetainedCursor, TeamsRetainedPage (values:[TeamsMessage], next:TeamsRetainedCursor?), TeamsRetainedVersion (sequence/observation/message), TeamsCheckpoint, TeamsIngestResult and TeamsArchiveJob; actor TeamsRepository `open(configuration: ContactWorkspaceConfiguration)`, `accounts() -> [TeamsAccount]`, `saveAccount(_: TeamsAccount)`, `bindPrincipal(accountID: UUID, principal: TeamsPrincipal)`, `commit(page: TeamsPage<TeamsMessage>, collection: TeamsCollection, baseline: Bool) -> TeamsIngestResult`, `checkpoint(collection: TeamsCollection) -> TeamsCheckpoint?`, `messages(scope: TeamsScope, before: TeamsRetainedCursor?, limit: Int) -> TeamsRetainedPage`, `versions(scope: TeamsScope, messageID: String, before: Int64?, limit: Int) -> [TeamsRetainedVersion]`, `search(scope: TeamsScope, query: String, before: TeamsRetainedCursor?, limit: Int) -> TeamsRetainedPage`, `pendingProjection(limit: Int) -> [TeamsArchiveJob]`, `acknowledgeProjection(id: UUID)`; `acquireLease(kind: TeamsLeaseKind, accountID: UUID, operationID: UUID) -> TeamsLease` and `releaseLease(_: TeamsLease)`. Repository actor methods throw; callers outside the actor await them. TeamsLeaseKind includes refresh/sync/dispatch; limits default50/max100.

- [x] Write real-PG `testPageAndVersionCheckpointRollbackTogether`, `testDeletionReopenRetainsOriginalAndRichVersions`, `testArchiveProjectionCrashReplaysExactObservation`, `testEqualSourceTimestampRetainsConflictWithoutRollback`, `testMissingKeysNeverInitializeOverExistingVault`, `testPrincipalChangeCannotRebindAccount`, `testOtherProcessCannotAcquireOrResolveLiveOwner`, plus Core `testMetadataOnlySourcePayloadChangeIsRetainedAndReplayDeduplicates`.

```swift
XCTAssertEqual(try await reopened.versions(scope: scope, messageID: "m1", before: nil, limit: 50).count, 3)
XCTAssertEqual(try await reopened.checkpoint(collection: collection), priorCheckpoint)
XCTAssertEqual(try archive.records(service: "teams", accountID: account.uuidString, conversationID: scope.storageKey).count, 2)
```

- [x] Run `scripts/dev-db.sh up`, then `scripts/test.sh --filter 'TeamsRepositoryTests|TeamsArchiveTests|MessageArchiveStoreTests'`. Expected RED for missing repository APIs and payload-only Core dedup before changes; local PostgreSQL is required, no skip-as-pass.
- [x] Implement encrypted teams_accounts/current/versions/checkpoints/archive_jobs/preferences/outbox-ready metadata using domain-separated keys and keyed scope/index tokens. Core observations and dates/UUIDs are frozen in the journal transaction. Atomically commit service append-only versions/current/checkpoint/projection jobs, then append those jobs to Core and acknowledge only after Core commit; never claim two separate DB connections form one atomic transaction. Core failures leave durable projection work, not lost observations. Exclude hosted/file bytes from all DTO/SQL payloads. Older source timestamps cannot roll back current state; equal-time contradictory observations remain retained as a visible conflict rather than invented ordering. Directory metadata has its own typed save/checkpoint records, not fake messages. Retained search continues across empty scanned pages and includes received deleted/older versions.
- [x] Implement session advisory leases with pg_try_advisory_lock, exact owner/operation tokens and independent held connections across async work. A failed COMMIT blocks further writes; do not retry it or regenerate vault keys. A thread's file policy maps to its parent channel. If reproduced, change Core's new event digest to include nonnil sourcePayload while preserving nil/legacy reads and append-only old rows; test Telegram/mail/WhatsApp compatibility, no archive rewrite.
- [x] Run the scoped tests; expected GREEN, independent reopened connections and real COMMIT/rollback/archive projection exercised. Checkpoint schema/version decisions and raw evidence.

### Task 4: Account/session lifetime and complete resumable Graph synchronization

**Files:** Create TeamsWorker.swift, TeamsSession.swift, TeamsSynchronization.swift; Tests/MakoshTeamsTests/TeamsWorkerTests.swift and TeamsSynchronizationTests.swift.

**Interfaces:** Consumes Tasks1–3. Produces TeamsAuthorizationPresentation (pending/browser/device/ready/cancelled/safe failure; no tokens) and TeamsWorkspaceSnapshot (accountID/principal/connection state/chats/teams/channels/sync progress/safe errors); actor TeamsWorker with `load(configuration: ContactWorkspaceConfiguration) -> [TeamsAccount]`, `addAccount(name: String, configuration: TeamsOAuthConfiguration, readOnly: Bool) -> TeamsAccount`, `beginAuthorization(accountID: UUID, method: TeamsAuthorizationMethod, capabilities: Set<TeamsCapability>) -> TeamsAuthorizationPresentation`, `authorizationStatus(accountID: UUID) -> TeamsAuthorizationPresentation`, `cancelAuthorization(accountID: UUID)`, `connect(accountID: UUID)`, `disconnect(accountID: UUID)`, `snapshot(accountID: UUID) -> TeamsWorkspaceSnapshot`, `messages(scope: TeamsScope, before: TeamsRetainedCursor?) -> TeamsRetainedPage`, `search(scope: TeamsScope, query: String, before: TeamsRetainedCursor?) -> TeamsRetainedPage`, `archivePage(scope: TeamsScope, before: Int64?) -> [MessageArchiveRecord]`, `shutdown()`. Methods async throws except async shutdown. Connect uses the already authorized vault session or reports explicit sign-in required; snapshot does not own a global selected conversation.

- [x] Write `testCancelGrantAndSwitchAccountRejectLateIdentity`, `testRefreshIsSingleOwnerAcrossRepositories`, `testChannelRootsAndAllReplyPagesSurviveReordering`, `testInvalidCursorRestartsScanWithoutMutingNewHistory`, `testDisconnectedArchiveRemainsAvailable`, `testShutdownDoesNotPublishOrReadOtherAccounts`.

```swift
XCTAssertEqual(snapshot.accountID, selectedAccount)
XCTAssertTrue(page.values.allSatisfy { $0.scope.accountID == selectedAccount })
XCTAssertEqual(Set(retainedReplyIDs), Set(["reply-old", "reply-new", "reply-last-page"]))
XCTAssertEqual(oauth.refreshRequests.count, 1)
```

- [x] Run `scripts/test.sh --filter 'TeamsWorkerTests|TeamsSynchronizationTests'`. Expected RED before worker/lifetime/sync implementation.
- [x] Implement explicit pending-grant/session generations and repository-backed refresh ownership. Browser URL presentation crosses to MainActor only; the service handles callbacks/polling. No token/SQL/Keychain IO in initializer. Cancelled incremental consent keeps the old session; wrong principal never replaces it. Disconnect/shutdown revoke jobs before asynchronous teardown, preserving vault/archive.
- [x] Implement per-account complete catalogue/chat/channel/root/reply scans with saved nextLink and durable page commits, at most5 pages per cooperative drain before yielding; no lifetime truncation or false complete flag. Poll connected accounts independently of UI selection,15s nominal interval subject to safe-read cooldowns. Invalid/expired continuation restarts that collection's scan, preserves previous versions and notification baseline, and reports the restart. Do not stop a channel scan based only on a root message timestamp when reply-chain order can differ.
- [x] Run scoped tests; expected GREEN. Checkpoint exact coverage and known Graph snapshot/never-received-content limits; no real provider acceptance claim.

### Task 5: Durable text/reply outbox with no uncertain replay

**Files:** Create TeamsOutbox.swift and TeamsGraphMutations.swift; extend TeamsWorker.swift and repository files; Tests/MakoshTeamsTests/TeamsOutboxTests.swift and TeamsSendingTests.swift.

**Interfaces:** Produces TeamsDraft (text/fileIDs), TeamsOutgoing (id/attemptID/scope/state/content/receipts), TeamsOutgoingCursor/Page, TeamsAttemptOutcome; repository `prepareOutgoing(scope:content:)`, `claimOutgoing(id:accountID:)`, `settleOutgoing(id:accountID:attemptID:outcome:)`, `resolveOutgoing(id:accountID:sent:)`, `outgoingPage(accountID:before:limit:)`. Worker `send(scope:content:)`, `resumeOutgoing(accountID:id:)`, `copyOutgoing(accountID:id:)`, `resolveOutgoing(accountID:id:sent:)`, `outgoingPage(accountID:before:)`. All actor methods async throws to callers. Graph extension `postMessage(scope:content:token:) async throws -> TeamsMessage` sends exactly one chat/channel/reply POST.

- [x] Write `testLost201BodyPersistsUnknownAndReconnectNeverReplays`, `testLiveOwnerAndLateAttemptCannotBeResolvedOrOverwriteReceipt`, `testChannelReplyUsesCapturedRootAndChatSendUsesChatScope`, `testReadOnlyAndMissingSendConsentBlockBeforeAdmission`, `testMutation429NeverRetries`, `testOutboxPagesDoNotDecodeLifetimeHistory`.

```swift
XCTAssertEqual(restored.state, .unknown)
XCTAssertEqual(transport.messagePOSTCount, 1)
XCTAssertEqual(settled.attemptID, currentAttemptID)
XCTAssertEqual(page.values.count, 50)
```

- [x] Run `scripts/test.sh --filter 'TeamsOutboxTests|TeamsSendingTests'`. Expected RED before outbox/dispatch fixes.
- [x] Implement prepared→dispatching→accepted/notSent/unknown with unique attempts and leases. A201 with verified resource/message body is provider acceptance only; an invalid/lost successful response, network/timeout/5xx or cancellation after dispatch is unknown. Definitive input/scope rejection stays visible as known notSent; there is no automatic mutation retry after401/403/429. Copy retry is explicit and cannot resolve/replay a live or unknown attempt. Receipt completion reads only its indexed exact row.
- [x] Run scoped tests. Expected GREEN against real PostgreSQL and scripted transport; check one POST after restart/repeated refresh and preserved content/destination.
- [x] Checkpoint the exact outbox/dispatch source hashes and RED/GREEN outputs; record the unknown-state/no-replay boundary in the task ledger.

### Task 6: Multiple file preparation, scoped Graph sharing and encrypted archive

**Files:** Create TeamsFiles.swift, TeamsGraphFiles.swift, TeamsFileSubmission.swift; extend repository/outbox/worker files; Tests/MakoshTeamsTests/TeamsFilesTests.swift, TeamsFileSubmissionTests.swift and TeamsFileDownloadTests.swift.

**Interfaces:** Produces TeamsPreparedFile (id/scope/name/size/hash/archiveReceipt), TeamsFileLease (owned private URL/release), TeamsRemoteFile (drive/item/version/eTag/content reference; no persisted preauthenticated URL), TeamsFileDestination (selected own-drive folder or selected channel), TeamsFileAccessPlan (destination/captured recipients/membership digest). Worker `prepareFiles(scope: TeamsScope, files: [URL]) -> [TeamsPreparedFile]`, `fileAccessPlan(scope: TeamsScope, fileIDs: [UUID], destination: TeamsFileDestination) -> TeamsFileAccessPlan`, `sendFiles(scope: TeamsScope, content: TeamsDraft, accessPlan: TeamsFileAccessPlan) -> TeamsOutgoing`, `download(scope: TeamsScope, messageID: String, attachmentID: String, version: String?) -> TeamsFileLease`, `exportArchive(scope: TeamsScope) -> TeamsFileLease`, `savingFiles(scope: TeamsScope) -> Bool`, `setSavingFiles(scope: TeamsScope, enabled: Bool)`. File/dispatch methods async throws; S3 policy methods also await service ownership. Use existing Core ArchiveFileCapture/ArchiveFileRepository/ArchiveFileRecord APIs rather than copying their envelope implementation.

- [x] Write `testTenFilesSurviveReopenAndEleventhIsRejectedBeforeIO`, `testOversizeAndSymlinkAreRejected`, `testS3OffUsesLocalAndNeverPromotesAfterEnable`, `testChangedOrIncompleteRosterStopsBeforeGrant`, `testPartialGrantAndUnknownUploadNeverPublishOrReplay`, `testHistoricalResourceDoesNotDownloadReplacement`, `testExportRefusesUnprojectedVersionsAndKeepsExactPayload`, `testDownloadRedirectNeverCarriesBearerOrCookies`, `testSharingURLLookupRequiresExplicitWriteScopeAndNeverRedeems`.

```swift
XCTAssertEqual(restored.fileIDs, prepared.map(\.id))
XCTAssertEqual(s3.PUTCount, 0)
XCTAssertEqual(transport.messagePOSTCount, 0) // partial/unknown sharing
XCTAssertEqual(invite.roles, ["read"])
XCTAssertFalse(invite.sendInvitation)
XCTAssertTrue(invite.requireSignIn)
```

- [x] Run `scripts/test.sh --filter 'TeamsFilesTests|TeamsFileSubmissionTests|TeamsFileDownloadTests'`. Expected RED before file pipeline/sharing implementation; real local PG/S3, no real OneDrive.
- [x] Implement bounded private file capture/leases and10-file/100MiB guards. Preserve original inode/hash and every recipient/file through recovery. Persist upload/grant/message stages independently before remote IO; bind them to one immutable attempt/access plan. Use selected OneDrive folder or verified channel filesFolder; create a unique non-overwriting upload target. Fully paginate current chat members; unresolved/cross-tenant guest mapping or changed digest blocks granting. Show named recipients for confirmation in UI; grants are read-only/sign-in-required with sendInvitation=false, never anonymous/org-wide links. Partial/error/unknown stages block publication and replay; do not auto-delete uploads or revoke user permissions as cleanup.
- [x] Implement incoming exact-resource jobs and archive reservations before capture, native Quick Look/Save leases, existing-object reads while S3 OFF and no new PUT/promotion on retry/recovery. Direct Graph hosted/drive resources use permitted read scopes. Sharing-link-only lookup through /shares requires explicit Files.ReadWrite, omits both link-redemption Prefer headers and fails visibly without consent. Redirect downloads use a separate credential/cookie-free HTTPS transport bound to the service-issued target, rejecting local/private destinations and unbounded bodies. Record capture time/verified version metadata; do not claim historical bytes that were never received. JSONL export uses an owned private lease without S3 admission and must drain/verify all selected-scope Core projection jobs or report incomplete export explicitly, never silently omit durable versions.
- [x] Run scoped tests; expected GREEN with real local encrypted storage and synthetic Graph stages. Checkpoint all bounds, partial/unknown behavior and any provider/file-version limits.

### Task 7: Local unread, durable notification policy and single-router integration

**Files:** Create TeamsNotifications.swift, App TeamsSystemNotifications.swift and TeamsNotificationPreferencesModel.swift; modify TelegramSystemNotificationRouter.swift only to add the Teams registry/namespace; Tests/MakoshTeamsTests/TeamsNotificationTests.swift and TeamsSystemNotificationTests.swift.

**Interfaces:** Produces TeamsNotificationRule, TeamsNotificationEvent, TeamsNotificationScope (global/account/conversation), TeamsNotificationRegistry; worker `savedNotificationRule(scope:)`, `setNotificationRule(_:scope:)`, `notificationRule(conversation:)`, `claimNotifications(accountID:)`, `notificationIsCurrent(_:)`, `activateNotification(token:)`, `markLocallyRead(scope:)`. App registry `canPresent(_:) async -> Bool`, `activate(_:) async`; namespace makosh.teams. with opaque tokens. No second UN delegate or provider read/delivery receipts.

- [x] Write `testInitialHistoryAndMutedEventsNeverReplay`, `testReplyCreatesOneLocalUnreadEventWithoutRootReorderDuplicate`, `testCallbackRechecksPreviewSoundAccountAndWindowAfterConsent`, `testLateAddCompletionWithdrawsOldPrivateContent`, `testOneApplicationDelegatePreservesAllServiceRoutes`.

```swift
XCTAssertTrue(initialEvents.isEmpty)
XCTAssertEqual(newReplyEvents.count, 1)
XCTAssertFalse(await registry.canPresent(oldToken))
XCTAssertTrue(center.removedIdentifiers.contains(oldIdentifier))
```

- [x] Run `scripts/test.sh --filter 'TeamsNotificationTests|TeamsSystemNotificationTests'`. Expected RED before event admission/policy callback integration.
- [x] Implement atomic event/checkpoint consumption in the service journal, encrypted rules, first-sync baseline and local-read state (UI labels must not imply Microsoft read receipts). Effective global/account/conversation rules restrict each other. Add Teams routes to the existing delegate and shared one-time consent owner; callback/add-completion checks compare full fresh rule/content, account/session, lock privacy and owning key/visible/nonminimized window. Revalidate and withdraw old previews; denial/error never prompts on every event. QA uses injected notification center; no real OS permission request.
- [x] Run scoped tests and affected existing notification tests. Expected GREEN; actual system-banner display remains unrun.
- [x] Checkpoint the notification/router source hashes and raw checks, keeping OS presentation separate from synthetic callback evidence.

### Task 8: Native workspace, settings, archive/outbox, files and dossier

**Files:** Create App TeamsWorkspaceModel.swift, TeamsViews.swift, TeamsConnectionView.swift, TeamsComposeView.swift, TeamsOutboxView.swift, TeamsHistoryView.swift, TeamsChatSettingsView.swift, TeamsSettingsView.swift and TeamsSyntheticPreview.swift. Modify WorkspaceView.swift and MakoshApp.swift, and add Tests/MakoshTeamsTests/TeamsWorkspaceModelTests.swift, TeamsSettingsModelTests.swift, TeamsDossierTests.swift and TeamsSyntheticIsolationTests.swift.

**Interfaces:** Define public `TeamsServing: Sendable` as exactly the worker entrypoints from Tasks4–7 and conform TeamsWorker; injected tests implement their real scripted behavior rather than success no-ops. MainActor TeamsWorkspaceModel `load(configuration:)`, `selectAccount(_:)`, `selectConversation(_:)`, `openThread(_:)`, `connect()`, `disconnect()`, `shutdown()`; published typed snapshots/busy/error only. TeamsSettingsRegistry holds weak workspace references. WorkspaceModel `linkTeamsPerson(_:accountID:) async -> UUID?` calls existing ContactWorkspaceWorker.apply(.link(...)) and returns the linked ID.

- [x] Write `testLateHistoryAndComposerCannotFollowNewSelection`, `testSettingsSaveWaitsForRulesAndFilePolicy`, `testCancelIncrementalConsentKeepsCurrentAccount`, `testDossierRetainsTenantProvenanceAndManualOverrides`, `testSyntheticPreviewRequiresBothQASchemasAndNeverTouchesOtherServices`.

```swift
XCTAssertEqual(model.selectedAccountID, secondAccount)
XCTAssertTrue(model.messages.isEmpty) // old delayed result was rejected
XCTAssertFalse(settings.canSave) // either scope-bound load is incomplete
XCTAssertEqual(personIdentity.service, "teams")
XCTAssertEqual(privateBoundaryCalls, 0)
```

- [x] Run `scripts/test.sh --filter 'TeamsWorkspaceModelTests|TeamsSettingsModelTests|TeamsDossierTests|TeamsSyntheticIsolationTests'`. Expected RED before models/selection/privacy UI binding.
- [x] Implement shared sidebar account/chats/team/channel/thread navigation, safe native history, explicit sign-in/reconnect/cancel states, text/reply/multiple-file composer, captured file-access review, paged outbox/unknown resolution, archive/search/JSONL export, profile/dossier and notification/S3 settings. No fake connected status, discarded fields, inert action or hidden account IO; initial grant/browser launches occur only from explicit user commands. Use explicit accessible native Menu styles/labels. Decode/HTML text projection on service/background executors; no network-capable HTML importer or remote resource execution. Save waits for all preferences for its exact context.
- [x] Add --teams-synthetic-preview before ordinary workspace startup. Require explicit database config and qa_teams_ application/archive schemas, fake vault/Graph/notification boundaries and synthetic other-service models without starting them. A QA-tagged bundle without these arguments fails closed. Settings reuses existing workers rather than creating duplicate sessions. Dossier links people only, preserving exact guest tenant/user provenance and generation checks after every suspension.
- [x] Run scoped tests; expected GREEN. Build and inspect actual isolated native UI for both synthetic accounts, chat/channel/thread/history/search beyond50, text/file preparation (no provider dispatch), outbox, all settings, dossier and compact/zoomed windows. Capture screenshots from the final matching executable. If CUA repeats its existing dossier pipe failure, keep the specific visual gap visible; never infer PASS from model tests or bypass the tool.

### Task 9: Integration, reproducibility and one final review

**Files:** Update docs/teams-migration.md (new current behavior/commands/permissions/recovery), docs/development-status.md, docs/reference-interface.md, docs/service-integration.md, docs/architecture.md, docs/main-thread-boundaries.md, docs/migration-plan.md and README.md. Update pin/source inventory and own tests only as required by prior tasks. AGENTS.md changes require the writing-for-agents workflow if a new persistent owner rule is actually needed; existing general service rules already cover Teams.

**Interfaces:** Consumes the complete Teams implementation and its task ledger; produces verified source/bundle/UI evidence and explicit remaining live/tenant/release gaps. No Git publication or real account session.

- [x] Verify every task's targeted RED→GREEN and spec coverage before final integration. Read the entire current task diff against the captured baseline; no prior Telegram/mail/WhatsApp changes are silently included as new Teams work. Refresh/check XERJ after source/docs changes; actual failures remain recorded and no source field is excluded to hide a frozen-index failure.
- [x] Run `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` and `git diff --check`. Expected exit0, real local PostgreSQL/S3 tests and all affected existing suites green; report exact counts/skips, not this plan's anticipated numbers. If the public-source build lacks a Telegram API pair, use the existing explicit source-build option and disclose it rather than reading credentials or treating the ordinary product build as passed.
- [x] Verify teams pin/notices without any research clone, complete runtime closure/ARM64/strict signatures and matching final ordinary/QA executable text. Stage a fresh isolated org.makosh.teams.qa bundle with MakoshRequiresSyntheticConfiguration=true; preserve old QA data/evidence instead of overwriting read-only artifacts. Prove offline archived data and synthetic worker traffic do not access Microsoft/personal keys/other accounts. Inspect final native UI after the last production change; a prior screenshot is not final artifact proof.
- [x] Create an immutable manual review snapshot/hash manifest for only current task files, the spec/plan, initial-baseline hashes and rulings ledger. Dispatch one fresh read-only reviewer on the inherited model (multimodel off), with the Review Focus above and exact implementation evidence. Do not dispatch an implementer/reviewer per task unless the user selected the subagent-driven method. Regrade findings by user impact; one Important/Critical RED→GREEN fix pass plus required gates, defer Minor explicitly, no second reviewer. Reconcile post-review changes by hashes.
- [x] Record real outcomes, open questions and deferred findings; explicitly leave Entra registration/tenant consent and actual account delivery/files/banners unverified. Preserve the working branch, initial changes and ignored raw evidence. No commit/push/merge, destructive cleanup, live account or device test is implied by completion.

## Rollback and continuation

Before implementation the app is unchanged. Task checkpoints preserve exact
owned source hashes and prior files. If a local slice fails, correct or revert
only its new changes against the pre-task snapshot, never reset the whole dirty
tree. New service tables are additive; do not drop old/new account/history data
to hide a failure. Missing credentials/keys/scope leave a visible disconnected or
restricted state, with prior archive intact. Once a remote stage has been admitted,
rollback is not a reason to replay/delete it: retain its receipt/unknown state.

After any compaction read the task ledger and current source before continuing.
Implementation-method selection and user live pause persist. Source/test success,
synthetic queue admission, Graph acceptance, real delivery, OS banner and release
acceptance remain separate evidence layers.
