# Telemost Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. The user selected native inline execution with one final inherited-model reviewer; the recorded implementation and review are complete.

**Goal:** Implement the approved first-stage Telemost accounts, known-meeting catalogue, official creation/configuration, permanent history and dossier references in the existing native workspace.

**Architecture:** A concrete MakoshTelemost Swift service owns REST/OAuth, encrypted persistence and durable operations. MainActor models conduct scoped UI commands and publish immutable values. Participation uses an official HTTPS browser/client handoff; Linux signaling/media is a separate research stage.

**Tech Stack:** macOS26+, Apple Silicon, Swift6, SwiftUI/AppKit, Foundation/URLSession, AuthenticationServices, Security, CryptoKit, existing MakoshCore/libpq/PostgreSQL. No new external runtime library or backend.

**Spec:** [approved first-stage design](../specs/2026-10-16-telemost-migration-design.md).

**Status:** User approved native inline execution on2026-10-16. Tasks1–7 implementation, canonical integration and one review/fix pass are complete with recorded regression evidence. Native auth bridge moved to Task6 by a ledgered ruling. Iterations used the prepared focused equivalent; post-review full tests/build/dev-db and absent-reference build pass. Native CUA inspection remains partial after its pipe failure; real-account checks stay paused. See development-status.md for final freshness and acceptance evidence.

## Global Constraints

- Research reference: Bezooom/yandex-messenger-native MIT `f0a237c6016088a8e3816dde2e56c06e4a47c5eb`; its best-effort messenger endpoints, GTK/GStreamer runtime, credentials and private stores are excluded. Build/run/test must work without `.references/` or legacy checkout.
- Retain the current feature branch/dirty baseline and existing services. No branch switch, staging, per-task commit, merge/push/publication or unrelated dependency update. Preserve raw exits/source hashes in ignored checkpoints instead.
- Service workers own SQL/Keychain/crypto/HTTP/parsing/export; MainActor only coordinates immutable commands/results. Constructors perform no account IO; retain actor checks, context generations and asynchronous teardown.
- Permanent received versions/notes/attempts: no TTL, pruning, remote404/delete purge or disconnect reset. PostgreSQL holds encrypted records, not attachment payload bytes.
- Own public ClientID/exact registered callback. PKCE S256; no client secret/password, borrowed token, automatic refresh, hidden authorization fallback or account rebind. Expiry/401 requires explicit reauthorization.
- Scopes are exactly `telemost-api:conferences.read`, `telemost-api:conferences.create`, `telemost-api:conferences.update`, enabled by capability. No organization/admin/profile/Disk permissions.
- Catalogue means meetings created/explicitly added in Makosh. No invented all-account list, incoming calls/chat/roster/recordings or native media state.
- POST/PATCH admission precedes dispatch; active PostgreSQL session ownership spans asynchronous network work. Unknown survives restart, forbids automatic replay and rejects late settlement.
- Include regular meeting create/info/waiting-room update, cohost read paging, local title/notes/star/hide/search/history/export and explicit dossier note. No broadcasts/cohost mutations/calendar/auto-summary/public-chat creation/recording administration.
- Participation uses validated `https://telemost.yandex.ru/j/{id}`. Existing URL mode remains usable without an API account. No real-browser, provider, Keychain, microphone/camera or OS prompt QA until separately authorized; previous live checks remain paused.
- QA requires explicit configuration and `qa_telemost_` for BOTH application/archive schemas, loopback-only endpoints, fake keys/vault/auth/opener and no other service hosts.
- Commands/expected outcomes below are future verification instructions, not passing results. Observe RED for behavioral tests before implementation. Full gates run at integration; checkpoints capture exact outcomes and skips.

## File Structure and Interfaces

All new names below are proposed contracts. Existing Core/Workspace entrypoints
were inspected; do not claim these new symbols exist until implemented.

- `Sources/MakoshTelemost/TelemostModels.swift`, `TelemostMeetingURL.swift`, `TelemostHTTP.swift`, `TelemostAPI.swift`: exact identity, bounded DTOs, URL and official REST.
- `TelemostPostgres.swift`, `TelemostRepository.swift`, `TelemostHistory.swift`, `TelemostOperations.swift`: encrypted records/versions, stable paging/search/export, attempts and session leases.
- `TelemostOAuth.swift`, `TelemostTokenVault.swift`: pending PKCE grants, exact callback/manual-code flow and checked Keychain.
- `TelemostWorker.swift`, `TelemostServing.swift`: account lifetime, command admission, known-meeting refresh and immutable snapshots.
- `TelemostDossier.swift`: immutable, source-stamped references and durable Core projection jobs.
- `Sources/MakoshApp/TelemostWorkspaceModel.swift`, `TelemostViews.swift`, `TelemostConnectionView.swift`, `TelemostMeetingEditor.swift`, `TelemostHistoryView.swift`, `TelemostOperationsView.swift`, `TelemostBrowserAuthorization.swift`: UI conductors and narrow native auth/opener bridges.
- `Sources/MakoshTelemost/TelemostQAIsolation.swift`, `TelemostSynthetic.swift`; App `TelemostSyntheticLaunchPolicy.swift`, `TelemostSyntheticPreview.swift`; `scripts/run-telemost-qa.py`, `scripts/test-telemost-qa.py`: isolated QA.
- `Tests/MakoshTelemostTests/TelemostTestSupport.swift` plus task-specific tests: scripted transports, controlled suspensions, isolated PG and fake vault/opener.
- Shared edits only as needed: `Package.swift`, `scripts/test.sh`, `scripts/build-app.sh`, `Sources/MakoshApp/WorkspaceView.swift`, `MeetingsView.swift`, `MakoshApp.swift`; Core `ContactStore.swift`, `ContactWorkspaceWorker.swift` and their existing tests.
- Provenance: `Dependencies/Telemost.lock.json`, `Dependencies/Telemost/README.md`, `scripts/verify-telemost-dependencies.py`, `scripts/test-telemost-dependencies.py`, `THIRD_PARTY_NOTICES.md`. No Rust crate/toolchain is added. Retain exact license text only if reference code is actually copied.
- Integration docs: `docs/telemost-migration.md`, development-status, reference-interface, service-integration, architecture, main-thread-boundaries and README.

Task1 defines Codable/Sendable values, byte-exact equality and collision-free keys:

```swift
struct TelemostPrincipal: Codable, Sendable { let userID: String; let clientID: String; let login: String }
struct TelemostScope: Codable, Hashable, Sendable { let accountID: UUID; let conferenceID: String }
struct TelemostMeetingURL: Codable, Sendable { let url: URL; let conferenceID: String; init(_ text: String) throws }
enum TelemostWaitingRoom: String, Codable, Sendable { case publicAccess = "PUBLIC", organization = "ORGANIZATION", admins = "ADMINS" }
struct TelemostAccount: Codable, Sendable { let id: UUID; var name: String; let clientID: String; let callbackURL: URL; var principal: TelemostPrincipal?; var capabilities: Set<TelemostCapability> }
enum TelemostCapability: String, Codable, Sendable { case read, create, update }
struct TelemostCreateRequest: Codable, Sendable { let waitingRoom: TelemostWaitingRoom }
struct TelemostMeetingPatch: Codable, Sendable { let waitingRoom: TelemostWaitingRoom }
struct TelemostConference: Codable, Sendable { let scope: TelemostScope; let joinURL: TelemostMeetingURL; let waitingRoomRaw: String; let observedAt: Date; let retainedJSON: Data }
struct TelemostCohostPage: Sendable { let scope: TelemostScope; let offset: Int; let limit: Int; let emails: [String]; let complete: Bool }
struct TelemostHTTPResponse: Sendable { let status: Int; let headers: [String: String]; let body: Data }
protocol TelemostHTTPTransport: Sendable { func response(to request: URLRequest) async throws -> TelemostHTTPResponse }
```

Additional value contracts are introduced by their owning task below. Raw JSON
is bounded response metadata, encrypted at rest; no media content enters it.
Unknown server enum/fields remain retained; they never default to PUBLIC.
Task2 adds `TelemostLeaseKind` and `TelemostOperationOutcome` before their consumers.
Task3 adds `TelemostToken`; Task4 adds `TelemostWorkspaceSnapshot` and
`TelemostResolution`. Every abbreviated `configuration` below has the existing
type `ContactWorkspaceConfiguration`; no new shared configuration format is needed.

## Review Focus

1. Confusable/encoded URL delimiters, alternate hosts and redirects must never open a hostile URL or leak OAuth authorization — Task1/3 tests.
2. Login/reauthorization cancelled during user-info or a changed principal must preserve the previous session and reject stale account publication — Task3/4 tests.
3. Crash between server admission/response/local COMMIT, including two processes and late completion, must preserve an unknown create and prevent duplicate replay — Task2/4 tests.
4. Partial/reordered cohost pages and new/unknown conference fields must preserve prior observations without fabricating complete roster, broadening access or overwriting unedited fields — Task1/4 tests.
5. Dossier merge/undo, projection retry and selection/window change during awaits must neither duplicate notes nor navigate/write to the new unrelated context — Task5/6 tests.

---

### Task 1: Official API contract, exact URL/identity and provenance

**Files:** Create the Models/URL/HTTP/API/provenance/verifier files listed above; `Tests/MakoshTelemostTests/TelemostAPITests.swift`, `TelemostMeetingURLTests.swift`, `TelemostTestSupport.swift`. Modify Package.swift and test/build scripts to register target/tests/verifier only.

**Interfaces:** Produces the values above and `TelemostFailure` typed configuration/auth/scope/provider/storage/unknown/invalidResponse cases. Actor `TelemostAPI(transport: any TelemostHTTPTransport)` exposes `conference(scope: TelemostScope, token: String) async throws -> TelemostConference`, `cohosts(scope: TelemostScope, offset: Int, limit: Int, token: String) async throws -> TelemostCohostPage`, `create(accountID: UUID, request: TelemostCreateRequest, token: String) async throws -> TelemostConference`, `update(scope: TelemostScope, patch: TelemostMeetingPatch, token: String) async throws -> TelemostConference`.

- [x] Write URL/identity/HTTP regressions: official `/j/123` accepted; credentials/query/fragment/encoded separators/alternate host/non443 port rejected before opener/transport; canonically equivalent opaque IDs stay distinct. Assert POST body contains only `waiting_room_level`, PATCH never echoes retained unedited fields. Unknown enum stays raw, cross-scope returned ID rejects, stream over4MiB aborts, HTTPS redirects reject without forwarded headers. Mutations make exactly one transport call on429/503/timeout; GET has bounded retry/cooldown.

Test names: `testOfficialURLAndConfusableRejection`, `testByteExactScopeIdentity`, `testMutationBodiesContainOnlyEditedFields`, `testUnknownFieldsRetainedWithoutPublicDefault`, `testCrossScopeReturnedIDRejected`, `testStreamingLimitAndRedirectRejection`, `testReadCooldownAndMutationNoRetry`.

```swift
XCTAssertEqual(try TelemostMeetingURL("https://telemost.yandex.ru/j/123").conferenceID, "123")
XCTAssertThrowsError(try TelemostMeetingURL("https://telemost.yandex.ru@evil.example/j/123"))
XCTAssertEqual(decodedMutationBody.keys.sorted(), ["waiting_room_level"])
XCTAssertEqual(transport.requests.count, 1) // failed mutation never retries
```

- [x] Run `scripts/test.sh --filter 'TelemostMeetingURLTests|TelemostAPITests'`; record actual compile/test RED, not an expected outcome as PASS.
- [x] Implement exact encoded path components, fixed official API origin, ephemeral no-cookie/cache production transport with bounded streaming/timeout, safe error mapping and capability-specific requests. Implement the independent reference/official-contract manifest verifier without requiring `.references/`; any copied snippets get source hash/license/notices first.
- [x] Run the focused command and `python3 scripts/test-telemost-dependencies.py`; require zero failed tests, positive malformed-manifest rejection and valid manifest acceptance. A missing reference clone must not change results.
- [x] Record Task1 source hashes/raw exits and update the ignored task ledger; no Git commit/staging.

### Task 2: Encrypted catalogue, permanent history and operation ownership

**Files:** Create TelemostPostgres.swift, TelemostRepository.swift, TelemostHistory.swift, TelemostOperations.swift; tests `TelemostRepositoryTests.swift`, `TelemostOperationTests.swift` and PG support fixtures. Read existing TeamsPostgres/ArchiveBackup patterns; do not share a Teams-prefixed connection/schema or service key.

**Interfaces:** `TelemostLocalMeeting` contains immutable localID/account-or-local-area binding plus optional confirmed scope, validatedURL, localTitle/notes/star/hidden and observation time. `TelemostHistoryCursor` binds area/filter/sequence; `TelemostMeetingPage` contains values/next. `TelemostOperation` holds id/account/scope-or-create/payload/attempt/state/receipt; `TelemostOperationState` is prepared/dispatching/accepted/rejected/unknown/resolved. `TelemostLease` owns separate PG session lifetime. Actor repository exposes `open(configuration: ContactWorkspaceConfiguration) throws`, `saveAccount(_:) throws`, `accounts() throws -> [TelemostAccount]`, `retain(_:) throws`, `saveLocal(_:) throws`, `page(accountID: UUID?, query: String, before: TelemostHistoryCursor?, limit: Int) throws -> TelemostMeetingPage`, `history(scope: TelemostScope, before: Int64?, limit: Int) throws -> [TelemostConference]`, `prepare(_:) throws`, `begin(operationID: UUID, attemptID: UUID) throws -> TelemostOperation`, `settle(operationID: UUID, attemptID: UUID, outcome: TelemostOperationOutcome) throws`, `acquireLease(accountID: UUID, operationID: UUID, kind: TelemostLeaseKind) throws -> TelemostLease`, `close() async`. Operation outcome carries accepted value, definitive rejection or unknown; lease kinds auth/dispatch/refreshKnown.

Abbreviated arguments are typed: `saveAccount(_ account: TelemostAccount)`, `retain(_ conference: TelemostConference)`, `saveLocal(_ meeting: TelemostLocalMeeting)`, `prepare(_ operation: TelemostOperation)`. Repository initializer accepts an injected `@Sendable (UUID, Bool) throws -> Data` key provider; production uses the existing archive Keychain boundary, tests use isolated keys. A persistent local-area UUID lives in encrypted service metadata; nil account never aliases a later connected account. `TelemostHistoryCursor` also fixes an upper sequence/filter hash for stable export. `export(accountID: UUID?, to: URL) async throws -> Int` writes versioned JSONL from immutable rows at that upper bound; returns exported record count and excludes tokens/keys.

- [x] Write real-PG regressions for version retention/dedup, local-area/account isolation, stable paging over65 records, local hide/remote404 preserving history, unsupported schema/missing-key refusal and ciphertext absence of fixture titles/URLs. Assert reopened dispatching becomes unknown, active two-process lease rejects a second owner, stale attempt cannot settle, failed COMMIT blocks every subsequent write. Tests create unique schemas and fake archive keys; no real Keychain.

Test names: `testPermanentVersionsAndLocalAreaIsolation`, `testStablePagingAndJSONLUpperBound`, `testHideAndRemoteMissingRetainHistory`, `testMissingKeyAndUnsupportedSchemaFailClosed`, `testCiphertextContainsNoFixtureContent`, `testRestartAndLateSettlement`, `testProcessLeaseOwnership`, `testFailedCommitBlocksAllSetters`.

```swift
XCTAssertEqual(try reopened.operation(id: operationID).state, .unknown)
XCTAssertEqual(try repository.history(scope: scope, before: nil, limit: 50).count, 2)
XCTAssertEqual(secondProcessDispatchCount, 0)
XCTAssertFalse(storedCiphertext.contains("Synthetic meeting"))
```

- [x] Start `scripts/dev-db.sh up`; run `scripts/test.sh --filter 'TelemostRepositoryTests|TelemostOperationTests'` and record RED with actual exit code.
- [x] Implement additive service tables with schema lock/version, authenticated encryption and keyed indexes using independent service domains. Persist immutable attempts/versions, never infer absence as deletion; use dedicated session advisory leases across awaits. Centralize blocked-after-COMMIT behavior including direct setters. Close libpq asynchronously outside MainActor. Add test-visible `operation(id: UUID) throws -> TelemostOperation` and `operations(accountID: UUID) throws -> [TelemostOperation]` queries used in assertions/UI.
- [x] Re-run focused tests with real PostgreSQL; require zero failures, restart and separate-process ownership evidence. Keep schemas/temporary test resources isolated from application data.
- [x] Save Task2 checkpoint and actual storage/crypto/recovery behavior in docs/telemost-migration.md.

### Task 3: PKCE, principal verification and checked token lifecycle

**Files:** Create TelemostOAuth.swift, TelemostTokenVault.swift, App TelemostBrowserAuthorization.swift; tests `TelemostOAuthTests.swift`, `TelemostTokenVaultTests.swift`.

**Interfaces:** `TelemostAuthorizationRequest` contains id/accountID/authURL/expectedCallback/mode/expiry; `TelemostAuthorizationMode` is browserCallback/manualCode. `TelemostToken` stores access token/optional refresh token/expiry/granted capabilities/principal. `TelemostGrantResult` is pending confirmation with principal/token; actor OAuth exposes `begin(account: TelemostAccount, mode: TelemostAuthorizationMode) throws -> TelemostAuthorizationRequest`, `complete(id: UUID, callback: URL) async throws -> TelemostGrantResult`, `complete(id: UUID, code: String) async throws -> TelemostGrantResult`, `cancel(id: UUID)`. Sendable vault protocol exposes `load(accountID: UUID) async throws -> TelemostToken?`, `save(_:accountID:) async throws`, `remove(accountID:) async throws`. Native browser bridge only presents/cancels ASWebAuthenticationSession and returns the captured callback.

- [x] Write scripted regressions for random verifier/S256, single-use state/exact callback/path/expiry, duplicate query/code, explicit manual-code mode, no code-exchange retry, reduced scopes and fixed user-info `id`/`client_id` match. Suspend user-info then cancel/restart and assert no saved token. Inspect requests for absent client_secret/password/token query params; inject Keychain status failures and assert old token remains recoverable. Expiry must produce reauthorization and zero refresh requests.

Test names: `testPKCESingleUseExactCallbackAndExpiry`, `testManualCodeRequiresExplicitMode`, `testNoExchangeRetryOrSecretsInURL`, `testReducedScopeAndVerifiedPrincipal`, `testCancelledUserInfoCannotInstallToken`, `testVaultFailurePreservesPreviousToken`, `testExpiryRequiresLoginWithoutRefresh`.

```swift
XCTAssertFalse(formFields.keys.contains("client_secret"))
XCTAssertEqual(userInfoURL.host, "login.yandex.ru")
XCTAssertEqual(vault.saveCount, 0) // grant cancelled during user-info
XCTAssertEqual(refreshRequestCount, 0)
```

- [x] Run `scripts/test.sh --filter 'TelemostOAuthTests|TelemostTokenVaultTests'`; capture RED.
- [x] Implement official OAuth endpoints/form encoding, S256, checked callback/manual verification code and identity verification using header auth. Limit JSON4MiB and token fields128KiB; redact provider diagnostics. Keychain calls run on vault executor with status checks. No automatic refresh, imported account/session, global revocation or hidden manual fallback. Define token/principal installation as a worker command under Task2 auth lease; OAuth completion alone never installs it.
- [x] Re-run focused tests to zero failures; test exact callback/user-info/expiry/error cases without system browser or protected dialogs.
- [x] Save Task3 checkpoint and document own ClientID/registered redirect/manual flow/expiry requirements without values from private configuration.

### Task 4: Worker, known-meeting refresh and durable REST operations

**Files:** Create TelemostServing.swift, TelemostWorker.swift; extend repository/operations only for this runtime; tests `TelemostWorkerTests.swift`, `TelemostReconciliationTests.swift`.

**Interfaces:** `TelemostWorkspaceSnapshot` contains accounts/local meetings/operations/connection states, not protocol or SQL handles. Protocol serving exposes `open(configuration:) async throws`, `snapshot() async throws -> TelemostWorkspaceSnapshot`, `addAccount(_:) async throws`, `confirmGrant(_:accountID:) async throws`, `disconnect(accountID:) async`, `addLink(_:accountID: UUID?) async throws -> UUID`, `refresh(scope:) async throws`, `create(accountID:request:) async throws -> UUID`, `update(scope:patch:) async throws -> UUID`, `resolve(operationID:resolution:) async throws`, `close() async`. `TelemostResolution` is attachVerifiedMeetingURL/dismissUnknownAndAllowNewAttempt; the latter never claims the previous operation did not run. Every mutation returns its durable operation ID, not invented delivery/call success.

Exact parameter types are `addAccount(_ account: TelemostAccount)`, `confirmGrant(_ grant: TelemostGrantResult, accountID: UUID)`, `disconnect(accountID: UUID)`, `addLink(_ url: TelemostMeetingURL, accountID: UUID?)`, `refresh(scope: TelemostScope)`, `create(accountID: UUID, request: TelemostCreateRequest)`, `update(scope: TelemostScope, patch: TelemostMeetingPatch)`, `resolve(operationID: UUID, resolution: TelemostResolution)`. Resolution cases carry `(TelemostMeetingURL)` or no payload respectively. Serving also exposes Task2 `page(...)`, `history(...)` and `export(accountID:to:)` signatures asynchronously; the worker validates selected area/account before delegating. `saveLocal(_ meeting: TelemostLocalMeeting) async throws` supports title/notes/star/hide without network work. Task5 extends serving with its exact `linkDossier` signature.

- [x] Write end-to-end scripted REST+real-PG tests: successful create retains exact result; definitive400/401/403 reject without pretending acceptance; body/read/COMMIT loss leaves unknown and no replay after restart. Unknown PATCH GET shows observed state for user review without resending. Grant installation shares auth lease and rejects another principal/client for the same accountID. Add link without account makes no network request; refresh partial cohost pages retains old pages and incomplete state. Controlled disconnect/cancel invalidates publication but still retains admitted late receipts for the exact attempt.

Test names: `testCreateReceiptAndDefinitiveRejection`, `testUnknownCreateSurvivesRestartWithoutReplay`, `testUnknownPatchRequiresReadReview`, `testGrantInstallLeaseAndPrincipalFence`, `testLocalLinkDoesNotConnect`, `testPartialAndReorderedCohostPagesPreserveObservations`, `testDisconnectFencesPublicationButRetainsReceipt`, `testBusyDoesNotSpin`.

```swift
XCTAssertEqual(transport.postCount, 1) // includes reopen/reconnect
XCTAssertEqual(try repository.operation(id: id).state, .unknown)
XCTAssertEqual(partialSnapshot.cohostsComplete, false)
XCTAssertEqual(try await worker.addLink(url, accountID: nil), savedLocalID)
XCTAssertEqual(transport.requests.count, 0) // local-link mode
```

- [x] Run `scripts/test.sh --filter 'TelemostWorkerTests|TelemostReconciliationTests'`; record RED.
- [x] Implement service-owned state/generation fencing, explicit principal confirmation under held auth lease, capability/expiry checks before dispatch and storage admission before every POST/PATCH. Refresh only known selected/explicitly requested scopes, never enumerate other meetings/accounts. Complete cohost pages use validated offset/limit progression with duplicate/order detection; reaching a safety budget reports incomplete and preserves a resumable offset. Unknown enum cannot become editable PUBLIC by default. Lock contention returns retryable busy to scheduled/manual work without a spin loop.
- [x] Re-run focused tests to zero failures including restart, late receipt, partial cohosts and auth/dispatch contention. Require requested capability denial before network dispatch.
- [x] Save Task4 checkpoint; document exact partial/unknown/expired/busy labels and accepted receipt semantics.

### Task 5: Idempotent source-stamped dossier references

**Files:** Create TelemostDossier.swift and `TelemostDossierTests.swift`; modify Core ContactStore.swift, ContactWorkspaceWorker.swift and tests `Tests/MakoshCoreTests/ContactStoreTests.swift`, `ContactWorkspaceWorkerTests.swift` where the existing test files actually own note/merge behavior. Add a focused `SourceNoteTests.swift` if separation is clearer; no aggregate schema rewrite.

**Interfaces:** New Core `ContactWorkspaceCommand.addSourceNote(contactID: UUID, note: ContactNote)` and persistence `addSourceNote(contactID: UUID, note: ContactNote) throws -> UUID` return the actual owning contact ID, including an exact existing-note retry after a later merge. Worker result adds `.sourceNoted(UUID)` while existing addNote/manual source remains unchanged. `TelemostDossierReference` contains stable noteID/account-or-local-area/meeting/source time/text, with `note: ContactNote`. Repository exposes `prepareDossierReference(meetingID: UUID, contactID: UUID) throws -> TelemostDossierJob`, `pendingDossierReferences() throws -> [TelemostDossierJob]`, `acknowledgeDossierReference(id: UUID) throws`; job freezes target/note across retries. Worker `linkDossier(meetingID: UUID, contactID: UUID) async throws -> UUID` performs Core command then durable acknowledgement.

- [x] Write real-PG Core+service regressions for append/retry, exact same note ID/content/source after lost acknowledgement, conflict on same note ID/different content/source, note retention during merge/undo and stale undo refusal after a later new note. Retry after merge finds only the identical note; missing/edited evidence fails closed. Assert contact service identities remain unchanged (meeting ID/email does not become a person identity). Freeze target before suspension; switching meeting/account cannot write another target or navigate the new selection.

Test names: `testSourceNoteRetryIsSemanticNoOp`, `testConflictingNoteIDFailsClosed`, `testLostProjectionAcknowledgementDoesNotDuplicate`, `testSourceNoteSurvivesMergeAndUndo`, `testLaterNoteBlocksStaleUndo`, `testProjectionRetryAfterMergeReturnsOwner`, `testMeetingReferenceNeverCreatesPersonIdentity`.

```swift
XCTAssertEqual(contact.notes.filter { $0.id == reference.note.id }.count, 1)
XCTAssertEqual(contact.identities, identitiesBefore)
XCTAssertEqual(contact.notes.last?.source.identity.service, "telemost")
XCTAssertEqual(retryOwnerID, mergedSurvivorID)
```

- [x] Run `scripts/test.sh --filter 'TelemostDossierTests|SourceNoteTests|ContactWorkspaceWorkerTests'`; capture behavioral RED.
- [x] Implement atomically through existing Core mutation/row lock, preserving exact source bytes, note IDs and timestamps. Same exact note retry is a semantic no-op without new event/revision; conflicting ID fails. Forbid UUID reuse by a distinct operation. Durable job ack follows known Core commit; uncertain Core COMMIT preserves job and blocks writes until existing recovery. Return owner ID for navigation; no automatic importing of cohosts or name/email matching.
- [x] Re-run focused tests plus existing Core merge/undo suite; require zero failures and unchanged legacy manual-note behavior.
- [x] Save Task5 checkpoint and source-note/provenance invariants in architecture/telemost docs.

### Task 6: Common workspace accounts, catalogue and meeting workflows

**Files:** Create the App Telemost model/views/editors/history/operations files; modify WorkspaceView.swift, MeetingsView.swift and MakoshApp.swift narrowly. Tests `TelemostWorkspaceModelTests.swift`, `TelemostDossierNavigationTests.swift`.

**Interfaces:** MainActor `TelemostWorkspaceModel(service: any TelemostServing)` owns `snapshot`, `selectedAccountID`, `selectedMeetingID`, `error` and scoped drafts. Methods `start(configuration:) async`, `selectAccount(_:)`, `selectMeeting(_:)`, `create(request:) async`, `update(patch:) async`, `addLink(_:) async`, `refreshSelected() async`, `exportHistory(to:) async`, `openDossier(contactID:) async`. URL opener is injected `@MainActor @Sendable (URL) -> Bool`; export uses worker/history executor and a user-selected native file URL, not MainActor serialization. Workspace callback receives actual contactID plus a current-generation predicate; callbacks never navigate on stale scope.

- [x] Write suspended fake-service tests for account/meeting switch during login/refresh/create/PATCH/search/export/dossier, old callback after close and selected owning window change. Assert draft only clears on accepted matching revision, unknown keeps draft/status, account1 action never alters account2 selection. Two note-navigation tests cover suspension before Core write and before final contact snapshot/publication; duplicate action does not create another note. Opener capture receives only validated HTTPS and never sets a call-connected state.

Test names: `testAccountAndSelectionFenceSuspendedWork`, `testAcceptedReceiptClearsOnlyMatchingDraftRevision`, `testUnknownPreservesDraftAndStatus`, `testDossierLinkRejectsChangedSelection`, `testDossierSnapshotRejectsChangedWindow`, `testDuplicateLinkDoesNotAddNote`, `testOpenerSuccessDoesNotClaimCallConnection`.

```swift
XCTAssertEqual(model.selectedAccountID, secondAccountID)
XCTAssertEqual(model.draft, editedWhileSending)
XCTAssertEqual(navigationTargets, []) // old selection/window revoked
XCTAssertEqual(capturedOpenedURL, validatedMeetingURL.url)
```

- [x] Run `scripts/test.sh --filter 'TelemostWorkspaceModelTests|TelemostDossierNavigationTests'`; record RED.
- [x] Implement existing middle-column account/search/list and detail card with explicit local/API state; sheets for own client config, browser login/manual code, create and waiting-room edit. Add local title/notes/star/hide, known-info/cohost incomplete labels, history paging/JSONL export and unknown resolution review. Keep outer backdrop/sidebar and existing service ownership. Add note source/open URL presentation in existing dossier without a second shell; no timer/camera/microphone/connected participant fiction. Exact service errors are localized and sanitized.
- [x] Re-run focused tests to zero failures. Prepare synthetic fixture coverage for at least two accounts,65 meetings, history versions, unknown/rejected attempts and incomplete cohosts; defer actual native UI proof to Task7.
- [x] Save Task6 checkpoint; update reference-interface.md with verified source-derived workflow mappings and explicit remaining native-media differences.

### Task 7: Isolated native QA, reproducible bundle and final review

**Files:** Create QA isolation/synthetic/launch files, `scripts/run-telemost-qa.py`, `scripts/test-telemost-qa.py` and `TelemostQAIsolationTests.swift`; integrate debug launch only in MakoshApp/Workspace. Update test/build scripts and all named integration docs/README/spec/plan/task ledger with actual final outcomes.

**Interfaces:** `TelemostQAIsolation.validate(configuration: ContactWorkspaceConfiguration, arguments: [String]) throws` requires explicit config, both `qa_telemost_` schemas and pinned loopback DSN/endpoint controls before opening any store/service. `--telemost-synthetic-preview` and a separate marked QA bundle fail closed if required args are absent; other service hosts never start. Runner `python3 scripts/run-telemost-qa.py --launch` creates a fresh run directory/bundle/config/fixtures/export root and uses fake auth/vault/opener.

- [x] Write isolation/runner regressions: reject missing args/config, either unprefixed schema, hostname-to-nonloopback/extra DSN host, nonloopback REST endpoint, real vault/opener and synthetic bundle normal launch. Assert malformed config exits before PG/Keychain/provider initialization; normal product launch cannot silently enter QA. Add Python checks for provenance resource bundling and exact QA marker.

Test names: `testBothSchemaPrefixesAndExplicitArgumentsRequired`, `testPinnedLoopbackAndNoRealBoundaries`, `testMarkedBundleFailsClosedBeforeIO`; Python `test_fresh_run_and_required_marker`, `test_bundle_contains_provenance_without_private_inputs`.

- [x] Run `scripts/test.sh --filter TelemostQAIsolationTests` and `python3 scripts/test-telemost-qa.py`; record actual RED.
- [x] Implement the isolation guards, fake service constructors, debug launch and fresh-run runner with owner-only config/fixture paths; fail before any IO when validation fails.
- [x] Re-run both focused commands to zero failures, retaining raw exits and explicit fake-boundary assertions.
- [x] Run `scripts/dev-db.sh up`, full `scripts/test.sh`, ordinary `scripts/build-app.sh`, provenance verifier and `git diff --check`. Build with `.references/` temporarily unavailable using a unique backup name and guaranteed restoration in finally; never remove the clone. Capture SHA/signature/ARM64/linked-library inventory and ensure new resources contain no private configuration/keys. A separate source-only build may use the existing explicit unconfigured-Telegram flag; it does not replace ordinary build proof.
- [x] Attempt inspection of the actual fresh synthetic bundle with native CUA: both accounts; add/copy/open-capture URL; local vs API status; create/update/unknown resolution; cohost partial paging; history/search65/export; note/dossier navigation; restart retention;1200×800 and enlarged text. Use fake opener and provider; never make a real browser/account/meeting call. If a native tool pipe closes, preserve data/process evidence and report the unverified screen instead of bypassing the boundary.
- [x] Refresh project XERJ (and reference if changed), check fingerprint/actual queries, freeze owned files plus baseline and request one final independent read-only review. Native method uses one inherited-model reviewer (no multimodel/quorum/model override); reviewer does not mutate/Git. Fix concrete findings with regression RED/GREEN and re-run affected/full gates proportionately. Update docs/plan only with actual PASS/FAIL/skips and explicitly pending real OAuth eligibility/provider/ordinary-Keychain/client/minimumOS/distribution acceptance. Leave live QA paused.


Actual UI exception: initial AX succeeded; CUA pipe closed on local selection while the owned process stayed alive. Remaining named visual scenarios are UNVERIFIED, not PASS. The split-width correction is included in the final post-review build. QA001 was then stopped with data preserved; fresh QA003 is launched. One reviewer found0Critical/6Important/0Minor; all six were reproduced/fixed in one pass. Final canonical tests pass: Swift2776 (Telemost74; one existing Telegram skip), Python150, Rust35. No second reviewer, deferred Minor, real-account access or Git publication.

## Execution and Rollback

Before implementation, read the approved spec and this plan, record the current
dirty baseline and all new owned paths. Native inline is recommended because the
seven tasks share storage/operation/auth interfaces and shared Core/App edits.
Subagent-driven execution is an available explicit choice; if selected, preserve
the user model and at most two same-model subagents with disjoint file ownership,
root-only manifests/integration docs/Git, following that author's workflow.

Each completed task records exact raw checks and source hashes, then proceeds
without intermediate permission requests within the approved plan. Publication,
real accounts and native-media research are separate actions, not final checklist
items to run implicitly. No task may call a synthetic receipt real creation.

Rollback stops Telemost workers and removes only its new integration UI/code
slice; preserve additive tables/versions/attempts/Keychain entries and other
services. Do not reset the checkout, delete schemas/volumes or rewrite history.

## Plan Self-Review

Coverage: API/URL/provenance→Task1; permanent catalogue/ownership→Task2;
PKCE/principal/vault→Task3; capability/expiry/unknown/cohosts→Task4;
idempotent dossier/merge/undo→Task5; all native first-stage flows/export→Task6;
isolation/build/native UI/final review/docs→Task7. All five Review Focus classes
have owning tests. Primitive interfaces are introduced before consumers;
new DTOs remain service-specific. No real access, refresh secret, all-account
list, chat/media/files API or provider acceptance is assumed. No step is checked
off before implementation and evidence.
