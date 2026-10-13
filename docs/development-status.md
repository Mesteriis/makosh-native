# Development status — 2026-10-13

## Product scope decision — 2026-10-13

The user explicitly excludes a local Makosh passcode and automatic app locking.
They are not migration backlog items; the earlier passcode proposal is withdrawn.

## Current stage: Telegram communication capabilities (block 13, in progress)

Approved scope: remote user/chat discovery; editable avatars and public fallback
photo; invitations/membership requests/admin history; complete native secret-chat
workflows; real native one-to-one audio/video calls. Block14 remains separate.
The spec and sequential inline plan are in docs/superpowers/specs and plans.
No passcode/autolock, personal-account QA or archive/S3-policy relaxation.

Task1 remote discovery source and UI are implemented. Account/context-bound
cancellable contacts.search distinguishes failure from empty success, deduplicates
local/remote native identities and re-reads the cached peer before activation.
Root ordinary queries/usernames admit discovery; archive/media/scope filters and
#/$ queries exclude it. No contact import, join or send occurs on opening.
Recipe22 keeps the exact engine pin/cryptography and adds one own MIT native
cache helper. Canonical-helper validation refuses a changed/missing generated
helper even with a consistent replacement marker: ordinary Python RED3 cases/2
failures, then3 pass. Old recipe21 is preserved privately. New controller/native/
Postbox/navigation tests include stale accounts, malformed/min peers, partial
cache refusal and origin draft preservation. Initial interface compilation REDs
and a repaired native fixture compilation error are recorded separately. The
first Postbox run has signal5 from a MainActor-inferred test transaction; a
nonisolated test helper repairs it and targeted2 pass. Combined focused38 pass.
Both signed builds exit0; final separate QA bundle has equal unsigned payload.
Actual native synthetic QA observes the common sidebar, username result/open,
error/retry, successful zero, and media-filter suppression/restoration. The final
error uses a distinct retry control and accurate text. Owned QA is stopped before
full tests. Task1 commits b8b62ac/c26cb46; full repaired suite exits0:1968 XCTest
(1889 Telegram +79 core),one microphone-precondition skip,zero failures;92 Python
across20 suites pass. Its first full attempt fails on an old warm-cache fixture
missing the newly mandatory helper; the fixture now includes the canonical file.
Tasks2–5 remain in progress.
No live search/server/account acceptance is claimed.

Task2 avatar source/native UI is implemented, with current own/group/channel
photo and own fallback workflows, immutable640px JPEG preparation, fresh full
photo/rights admission, typed write ACKs and post-write reread. Canonical recipe23
adds own MIT upload/photo bridges; prior preparation retained. Native/controller/
profile/cover focused52 pass, Python preparation22 pass, signed build exits0.
Min-channel ACK ordinary RED1/1 repairs via nonzero personal-hash admission.
Initial native QA observes native picker cancellation and circular crop/rotate/
flip, but Done exposes a reference fitted-canvas rounding error (401x400).
New ordinary RED1/1 reproduces it; integer-square snapping repairs avatar10 tests.
Final rebuilt QA (strict signature/equal unsigned executable) verifies native
picker cancellation, circular crop/rotation/flip, cancel confirmation preserving
visible draft, own save/reopen, delete cancel/discard and confirmed removal,
independent fallback delete/upload from photo privacy, and group/channel edit
entry plus photo upload (group removal also checked). Transient CUA AX failures
at sheet transitions are followed by fresh full-state/rebinding observations;
actual outcomes are confirmed, not inferred from clicks. Screenshots inspected,
owned QA stopped and isolated data retained. A final cancellation audit adds an explicit pre-commit Cancel Upload action: an
ordinary RED1/3 verifies preserved draft, idle phase and revoked late commit.
Commit-phase cancellation is refused. Final focused55 pass (18 new cases).
The delayed synthetic provider verifies actual0.5 progress/cancel, idle retained
draft, no late save, and new explicit confirmation. Final cancellation QA is
observed; full Task2 suite remains pending. Earlier UI compilation errors (computed synthetic identity assignment,
compound @State) are recorded separately; they are repaired, not passing builds.

Native-call research only: exact reference tgcalls/tg_owt source pins are fetched
into independent bare caches. Native wrapper needs a reviewed WebRTC dependency
closure/build; no signaling-only/fake-connected completion is claimed.

## Completed stage: extended Telegram privacy (block 12)

The authorized continuation extends the existing common native privacy flow in
source-confirmed TelegramSwift order: voice/video-message rules, gift autosave,
Premium/bot allow exceptions, read-time hiding, incoming Everybody/Contacts-and-
Premium/Stars policies, paid exemptions and allowed gift types. Whole wire flags,
unknown fields and existing fees survive unrelated edits. Frozen contexts,
explicit confirmation, a fresh server basis and fresh encrypted-Postbox account/
configuration capabilities gate writes. Global and selective operations share the
existing account uncertainty barrier. No schema, dependency, engine recipe, S3
policy or permanent-retention change; no personal account access is used.

Ordinary assertion REDs cover selective3 cases/5 failures, special builder4/1,
global model5/4, repaired controller5/9, repaired native boundary5/10 and final
composition5/4. A former fixed category-count assertion is removed after adding
three categories. Initial controller RED traps after an unexpected admission;
the harness now stops that branch. Initial native harness compilation and an
incorrect ordinary-JSON AppConfiguration fixture are classified separately and
repaired only in tests. Fresh real encrypted Postbox tests cover missing/revoked
Premium and valid/malformed fee limits; RPC tests cover exact constructor, wire
preservation, changed basis, missing/altered ACKs and shared uncertainty/context.
Final focused **52 XCTest pass**,0 failures after all source changes.

Independent read-only review verifies22 public hashes. Its one Minor finding is
reproduced natively: saved25 Stars plus invalid1.5 text left exemptions enabled
and no Discard action. Three UI guard changes include invalid input in exemption
navigation, its notice and Discard. Final review verifies all22 hashes and the
three-path source/documentation delta, reporting no remaining Critical/Important/
Minor findings. It runs no tests, build, native operations or private-state checks.

Required PostgreSQL startup exits0. Final `scripts/build-app.sh` exits0 with strict
signing; the separately identified QA bundle has an equal unsigned executable.
Native CUA runs use only the explicitly isolated synthetic PostgreSQL schema and
in-memory privacy provider. Common service sidebar and reference privacy order
are observed. Confirmation/cancellation/ACK/reopen,25 Stars,0/-1/1.5/10001 refusal,
invalid input blocking exemptions, Discard/Refresh restoring25, parent-draft child
navigation barriers, read-time hiding, Premium/bot exceptions, gift filters and
voice audience changes pass. Unrelated global/selective changes retain25 Stars.
The preceding artifact also verifies native fee-exemption membership staging/
confirmation. A separate non-Premium fixture confirms readonly voice rules and
exceptions, four readonly gift filters, unavailable incoming restrictions and
available read-time toggle/discard. Screenshots are inspected; full pixel parity
is not claimed. Owned QA stops before the complete test suite; isolated data is
retained. No live privacy mutation, Stars charging or server-normalization proof.

Final project XERJ refresh exits0:764 indexed files,713/713 classified code. Own,
reference and recipe21 engine freshness checks pass; actual final retrieval finds
telegramPerformGlobalPrivacyChange and is confirmed against current source.
The complete768-file public snapshot is frozen, excluding this mutable ledger.
Required `scripts/test.sh` under per-process caffeinate exits0: **1954 XCTest
(1875 Telegram +79 core),1 microphone-precondition skip,0 failures;89 Python
tests across19 suites**. All22 new cases pass. Final focused52 pass, build exits0,
and all768 frozen public file hashes/file set plus22 reviewed hashes still match.
Existing upstream framework/SQLite diagnostics remain in private raw logs and are
not XCTest failures or live-account acceptance. Exact-head hosted/publication
evidence is tracked on [PR12](https://github.com/Mesteriis/makosh-native/pull/12);
local results do not substitute for hosted CI.
Reference differences and remaining flows are in docs/reference-interface.md and
docs/telegram.md.

## Completed stage: Telegram data and connection (block 11)

The authorized item adds data/cache/proxy controls to the existing common native
workspace, following source-confirmed TelegramSwift ordering. Account-local bounded
auto-download rules drive visible incoming history with native Postbox admission,
three-transfer concurrency, current-policy/window checks and independent manual
ownership. Existing per-chat S3 admission and permanent retention remain unchanged.
Cache selection is the verified cloud-media subset, fresh-confirmed and removed
through force:false MediaBox; no broad disk/S3/PostgreSQL/session/original clear.
One shared proxy coordinator validates SOCKS5/MTProto, conditionally stores its
revision in Keychain and applies an in-memory dynamic source across network/auth
replacement. False/unknown application stops owned connections; explicit reread/
reapply is required. Actual proxy reachability is not inferred from local ACKs.

Valid ordinary assertion REDs cover auto policy/queue/admission, cache selection/
controller, config/vault/MTContext and dynamic source behavior. Harness compilation
errors and a MainActor transaction SIGTRAP were classified separately; nonisolated
signal construction repairs the test harness. The coordinator's valid RED has5
ordinary failures; repaired native integration initially exposes a fixture with
unknown sizes and reset media descriptors, fixed only in explicit synthetic data
fixtures. Initial focused51 tests pass. Independent readonly review verifies46
public hashes and finds an opening-timeout late-network race plus IP NUL parsing;
root's new REDs have1 and3 ordinary failures respectively. Disconnect/generation
invalidation plus late-registration rejection, and pre-C-parser control rejection
repair them. Cache AX category labels/zero-byte-only button state are also repaired.
The reviewer independently verifies all46 repaired hashes/seven changed paths and
reports no remaining Critical/Important/Minor source finding; it runs no tests or
native operations. Root's final focused52 XCTest pass. Python proxy adaptation3
tests pass. Required PostgreSQL/S3 startup exits0; both containers healthy.

Initial native synthetic QA confirms common settings order, master/category save,
actual1MiB limit selection, clear cancellation preserving10MiB, photo-only clear
leaving9MiB, invalid proxy URL refusal, secure password/secret, SOCKS5/MTProto
add/select/edit and explicit active-profile removal disabling without selecting
another. The first QA bundle is strictly signed and its unsigned executable equals
the built payload. Native scroll/coordinate CUA calls fail with noWindowsAvailable;
AX interactions still work. Owned LLDB diagnosis confirms a real WindowServer
occlusion flag, not a gate defect; two initial debugger expressions fail from
missing Objective-C receiver casts, then the typed diagnostic exits0. Ordinary
bundle activation makes the gate active. Native scroll then reveals incoming
fixture129: auto progress appears without pressing Download, followed by File
Downloaded/Save and actual screenshot. The final repaired bundle passes build/
strict signing and unsigned-payload equality. Restart preserves masterON, the
private-file rule/1MiB limit and selected SOCKS5/edited1081 port/secure field.
Final cache AX descriptions include category names; photo-only clear leaves9MiB
and a zero-byte-only selection disables Clear. One QA assertion initially expects
the category in AX label position; the actual Description is present and the
corrected native assertion passes. Owned QA is stopped; isolated data retained.
Initial `scripts/test.sh` under per-process caffeinate exits0: **1929 XCTest
(1850 Telegram +79 core),1 microphone precondition skip,0 failures;89 Python
tests across19 suites**. All44 new block cases execute and pass. Existing macOS
framework diagnostics remain in private raw logs; they are not XCTest failures
or communication-account acceptance. The complete757-file frozen snapshot and
file set match, excluding this mutable ledger. All three XERJ scopes are fresh;
final retrieval confirms own proxy composition and generated dynamic-source
helpers against current source. Exact-head hosted/publication evidence is recorded on
[PR11](https://github.com/Mesteriis/makosh-native/pull/11); local results do not
substitute for hosted CI.
No personal account, Telegram transport or real Keychain acceptance is claimed.
Conservative reference differences and remaining broad settings flows are explicit
in docs/reference-interface.md and docs/telegram.md.

### Pre-merge automatic archive handoff repair

Both exact-c42c033 hosted runs pass, but no merge occurs: a subsequent bounded
source audit plus independent review confirms P1 archive overflow. Three-transfer
concurrency alone can outpace eight retained captures; the ninth old completion
can have no FD/receipt. New reservations count in-flight automatic admissions and
FD-backed pending work together (three slots), separate from the unchanged eight
manual slots, total11. A granted completion captures its FD synchronously despite
later archive error/manual pressure; cancellation frees only an unused slot.
Capacity refusal leaves the candidate retryable; archive-state changes wake the
queue. Native identity/policy/window eligibility and S3 admission remain unchanged.
Manual completion ordering is preserved. Invalid FD capture cannot publish Ready.

The first new harness run has an actor-isolation compile error, corrected by
annotating its fake budget MainActor. Valid RED:3 cases/6 ordinary failures.
Repaired21 focused cases pass, including real PostgreSQL/S3 recovery of11 exact
files after source unlink under held configuration failure/manual pressure.
The final focused59 cases pass and additionally check explicit S3 OFF: no new
record or encrypted spool remains, old records retained. Final independent source
review verifies48/48 hashes and exactly the declared two-file cleanup: duplicate
Combine removal and immediate post-capture token validation. No source findings
remain; the reviewer performs no runtime checks. Root confirms all758 public frozen
files and file set, excluding this mutable ledger. Final signed build exits0;
the separately signed QA bundle has the same unsigned payload. Native synthetic
QA again shows incoming fixture129 progressing automatically to File Downloaded,
without Download, and restarted masterON/files1MiB/selected SOCKS5 port1081/secure
password field in the common workspace. Owned QA is stopped, isolated data retained.
Final full `scripts/test.sh` exits0: **1932 XCTest (1853 Telegram +79 core),
1 microphone precondition skip,0 failures;89 Python tests across19 suites**.
All47 new block cases execute and pass; final focused59 pass. Fresh own/reference/
engine XERJ fingerprints and actual own reservation retrieval are source confirmed.
Exact-final-head hosted gates and integration evidence are recorded on
[PR11](https://github.com/Mesteriis/makosh-native/pull/11); earlier c42 hosted success
does not establish the repaired head. No live account/transport/Keychain acceptance
is claimed.

## Completed stage: Telegram notifications on this Mac (block 10)

Own SwiftUI settings in the common workspace now cover account-local notification
enablement, previews, system/silent sound, Dock attention, active-app suppression,
timed snooze, personal/group/channel policies, per-chat exceptions and unread badge
options. The profile opens the same per-chat editor. Frozen contexts reject stale
editors; corrupt/oversized stored settings disable notifications until explicit
reset. Changes propagate to other windows sharing that account/preferences store.
No server notification setting is written.

New arrivals come only from the native notificationMessages stream and fresh
encrypted-Postbox messagesForNotification resolution. Read/mute/topic/privacy/silent
constraints remain authoritative. An own bounded pump avoids an unbounded upstream
queue; excess arrivals produce a visible warning without deleting messages/archive.
Albums use their first nonempty caption, while unrelated forwards retain their own
text. Native identities remain in memory; system payloads contain opaque single-use
tokens. One app-owned router preserves owning-window activation and deduplicates
cross-window arrivals. Spoilers/login codes are masked; protected/secret content is
generic. Screen-lock cleanup is best effort. Current click routes/submissions and
process-local deduplication caches are bounded.

Regression REDs exposed ordinary assertion failures in policy, native resolution,
system payload, cleanup races, duplicate album bounds, queue pressure, caption
selection and cross-window routing/preferences. Repairs pass the focused23 XCTest.
The final app build and strict signing exit0. Independent read-only review verifies
all23 frozen source/test/reference-document hashes and reports no remaining
Critical/Important/Minor finding; it runs no tests/build/native QA. Root verifies
the complete727-file public snapshot, excluding this mutable ledger.

Final native QA uses a separately signed synthetic bundle and isolated PostgreSQL
schema. The user grants its macOS notification permission. After restarting the
final build, permission, disabled previews/active-app suppression and the chat's
silent exception persist. A fresh synthetic incoming event produces the generic
body; querying this bundle's current opaque token confirms an actual delivered
macOS card with that exact body. In-app activation closes settings and opens the
chat/history in the common services workspace, visually inspected. This does not
claim a physical system-banner click. The owned QA process is stopped before the
full suite; isolated data is retained. No private accounts or Telegram network are
used. Transient CUA observation failures remain failures, followed by fresh reads.

Required DB/S3 startup exits0. Final `scripts/test.sh` under per-process
`caffeinate -i` exits0: **1885 XCTest (1806 Telegram +79 core),1 microphone
precondition skip,0 failures;86 Python tests across18 suites**. All23 notification
tests execute. Exact-head hosted and publication evidence is recorded in
[PR10](https://github.com/Mesteriis/makosh-native/pull/10). Final XERJ project
refresh exits0:723 files,672/672 classified code files.
Project, TelegramSwift and engine fingerprint checks are fresh; actual registry,
reference-preferences and native-stream queries are confirmed against current
source. Engine recipe20/pin, dependency locks, schemas, permanent retention and
per-chat S3 prohibitions are unchanged.

This slice requires a running, explicitly connected app. Live-account acceptance,
physical locked-screen/banner/multiwindow presentation, terminated-app push,
server-synchronized notification editing/reset, cloud/bundled tones, joined-contact
controls, reactions/stories/scheduled reminders and banner reply/read actions are
not established or implemented here. Reference differences are recorded in
reference-interface.md; operational limits are in telegram.md.

## CI repairs for the preceding integration

Both hosted runs for block2 head8cbf794 failed before compilation because
Gitiles regenerated libvpx tar/PAX timestamps. Two fresh downloads and the
original capture have identical1,258 path/content pairs, including all126
compiled inputs. The VPX pin now authenticates that complete canonical inventory;
compressed12MiB and expanded64MiB limits run before tar metadata parsing. The
original capture digest remains provenance. Prepared135-file fingerprint is
unchanged; no decoder source, license or build configuration changes.

The original focused regression exits1 (two assertion failures); the repaired
8 Python tests exit0, including full-inventory tampering, bounded expansion and
cold HTTP/offline reuse. A real uncached HTTP preparation produces the exact
reviewed135-file output. `scripts/dev-db.sh up` and `scripts/build-app.sh` exit0.
A full local suite exits0:1,714 XCTest (1,635 Telegram +79 core),1 microphone
precondition skip,0 failures;77 Python tests. A read-only worker review finds
no material VPX boundary defect; it does not establish hosted CI success.
The merge gate requires hosted success on the exact repaired PR commit.
The repaired hosted builds pass preparation/compilation, then fail on timing
assumptions in three test classes (13 and5 assertions respectively). Positive
deadline tests now wait for the actual state with a5s bound; the upload fixture
emits its approval handshake synchronously, as the real provider does. Real
timeouts, negative human-wait checks and late-ACK/receipt assertions remain.
The focused27 XCTest pass locally on the working search branch; this does not
establish an isolated block2 or hosted result. Hosted CI must pass the exact
new PR1 commit before merging. The next hosted attempts stop on Gitiles HTTP503
before compilation. VPX preparation now retries transient HTTP408/429/5xx and
network timeouts at most3 times, with250/500ms backoff. Permanent HTTP errors,
size/content/parser failures still fail closed. The valid regression RED has
13 tests/11 ordinary failures; the final13 Python tests and an actual uncached
HTTP preparation pass. The prepared135-file fingerprint remains unchanged.
Both subsequent hosted builds pass preparation and compilation but fail on
another fixed-sleep ordering assumption (1 and6 assertions): recorder hold
start and forwarding/Saved forwarding post-consent deadlines. Positive checks
now wait for the actual transition with a5s bound. Real350ms/40ms timers,
negative no-start/human-wait checks and late-ACK/lease assertions remain. The
focused24 XCTest pass; commit a9ee000 is published for hosted verification in
[PR1](https://github.com/Mesteriis/makosh-native/pull/1). Extended search is a
separate change; its hosted results and publication are tracked on its PR.

## Current follow-up: automatic 2FA reset availability

The reference's1s recurring entries refresh is source-confirmed via fresh XERJ
searches. A native TimelineView now reevaluates the reset completion button every
second while a reset date is present. It preserves unsubmitted fields/context and
performs no read/write RPC. Explicit consent, fresh server snapshot, current clock
eligibility and uncertainty guards still control the actual reset.

Native assertion RED: after a20s synthetic deadline passes, the original button
remains disabled without Refresh. After the patch, the same actual UI assertion
passes: completion enabled, password still enabled, unsubmitted secure field
preserved. Confirmation cancellation preserves the password; only explicit second
confirmation completes the synthetic reset. Strict signing/unsigned executable
payload equality and required DB startup/build pass. Owned QA stopped; isolated
PostgreSQL data retained. No real accounts, credential changes or Telegram network
were used. The DEBUG-only short-reset flag affects only an explicit synthetic
preview; native providers, engine recipe/pin, schemas, retention and S3 are unchanged.
Focused28 block tests pass before the final test timing-margin adjustment. The
final `scripts/test.sh` under per-process `caffeinate -i` exits0: **1862 XCTest
(1783 Telegram +79 core),1 microphone precondition skip,0 failures;86 Python
tests across18 suites**. All28 block tests execute. All713 frozen fingerprints
and the complete file set match, excluding this mutable ledger. Independent
read-only review finds no Critical/Important/Minor issue; it runs no tests and
does not replace root's native QA. Exact-head hosted/integration evidence will
be recorded on the attached follow-up PR. No live-account acceptance is claimed.

## Completed stage: Telegram two-step verification (block 9)

Own native SwiftUI in the existing privacy workspace now covers locked/current
password, management, setup/reentry/hint/email, pending-email confirmation/resend/
cancel, recovery-code and scheduled-reset/cancel states. Password change preserves
confirmed recovery email. Every write has frozen explicit consent, same-account
fresh snapshot/basis,30s deadline and retained uncertainty on unknown/false/empty
ACK or close during write. Exact UTF8 comparisons prevent canonical-equivalent
password substitution. Verified current password is memory-only, expires after
5minutes and cannot be borrowed by a stale confirmation after re-unlock.

Recipe20 keeps the engine pin/native cryptography and adds exact-source/hash
ACK, pending-email, protected-secret consistency and unsupported next-secure-algo
guards. Previous generated preparations are retained under ignored backup names;
only the tracked recipe is edited. The GPLv3 adaptation and own MIT helper/UI
boundary are recorded in THIRD_PARTY_NOTICES. No schema, permanent archive or
per-chat S3 policy changes; no reference checkout build/run/test dependency.

The first25 focused XCTest pass. DB startup and app builds exit0. Native isolated
synthetic QA covers wrong password/clear, unlock, disable cancellation/Passport
warning, password change preserving email, wrong/correct email code, resend,
waiting/cancellation of reset, recovery, setup with email/cancel, setup without
email/skip warning, close/reopen revocation and disable. The shared services
sidebar remains. Strict signing and unsigned executable payload equality pass;
owned QA process stopped, isolated PostgreSQL data retained. CUA capture failures
are observation failures, followed by fresh state reads; synthetic input uses
native paste after typeText failed to insert the full text. No real credentials,
account access, email delivery or Telegram network mutations were tested.

Independent read-only review identifies a native EMAIL_INVALID/UNCONFIRMED
numeric-code bypass. A real generated-helper regression has1test/7 ordinary
assertion failures before repair. The adapted engine now requires numeric400,
strict pending descriptions and fresh nonempty patterns; unexpected500 remains
uncertain. Re-review confirms the repair with no remaining Critical/Important
finding. Initial block9 requires manual Refresh after a reset date passes; the
follow-up above removes that reference difference. Prior valid REDs include12tests/22 ordinary failures,17/14, secure
values1/3, consent/error2/10. Draft/lifetime5tests have26 assertion failures,
including2 secondary XCTUnwrap errors; these are not compiler/crash REDs.

The first full `scripts/test.sh` under per-process `caffeinate -i` exits0 with
1860 XCTest (1781 Telegram +79 core),1 microphone precondition skip,0 failures;
86 Python tests across18 suites. It includes all26 new block tests and the native
error repair, before the final UI focus correction. Native keyboard QA then
finds a replacement field did not receive focus: paste without clicking made
no change. A stage-bound cancellable task assigns focus after mounting; final
app build exits0 and actual native QA verifies Enter unlock, automatic focus on
repeat/hint, paste into hint without mouse, Enter review and cancellation.
Strict signing and unsigned final executable payload equality pass. The final
owned QA process is stopped and isolated data retained. Source review of this
focus delta finds no issue. Final `scripts/test.sh` after the focus correction
also exits0: **1860 XCTest (1781 Telegram +79 core),1 microphone precondition
skip,0 failures;86 Python tests across18 suites**. All713 frozen file fingerprints
and the complete file set match, excluding this mutable ledger. Project, locked
reference and recipe20 engine XERJ checks are fresh. Hosted verification and
integration are recorded on the attached PR after its exact-head checks; this
source-freeze ledger does not claim live-account or hosted acceptance.

## Previous stage: Telegram blocked users (block 8)

The existing privacy workspace opens blocked cloud users; user/bot profiles supply
Block/Unblock in the reference's location. Both actions require confirmation.
The list retains unresolved names and reads every raw server page before display;
raw offsets, duplicate/progress/consistent-total validation, a10000-record bound
and30s deadline prevent silent truncation. Unsupported non-user blocked peers
fail the complete read. Separate accessible buttons replace SwiftUI's initial
combined list rows. Avatar/profile opening and Edit-mode parity remain open.

Each write repeats the full server read and checks expected target membership,
account and captured controller/profile contexts. Unblock uses the fresh server's
non-min personal identity, without requiring a cached peer. New Block requires a
fresh personal CloudUser identity in native Postbox. Self checks account for native
encoded IDs above32bits. Only BoolTrue admits the cache update and list reload;
false/empty/ambiguous ACKs retain uncertainty. Closing during a write also retains
the process-local account barrier until an explicit successful refresh. No automatic
application retry is introduced. Telegram's read/write race without CAS remains.

Valid assertion REDs: initial8 tests/25 failures; server/workspace10/3; profile1/1;
identity2/4; actual encrypted Postbox1/1. Compilation errors are not RED evidence.
A test composition initially executes a MainActor closure on the Postbox queue
(SIGTRAP, confirmed by crash report); explicit main delivery repairs that fixture.
The final focused44 XCTest pass, including real encrypted Postbox identity reads
and cache updates preserving other fields. Required DB startup and final app build
exit0. Native final synthetic QA verifies navigation, unresolved-name row, distinct
AX actions, confirmation cancellation, acknowledged unblock/profile block, and
shared profile/settings state. All50 visible synthetic history IDs remain identical
after blocking. Strict signing and unsigned executable payload equality pass.
The owned QA process is stopped and isolated PostgreSQL data retained.

The first full suite passes1834 XCTest (1755 Telegram +79 core),1 microphone
precondition skip,0 failures;85 Python tests across18 suites. It precedes the final
list accessibility repair. The final `scripts/test.sh` under a per-process
`caffeinate -i` exits0 with the same **1834 XCTest (1755 Telegram +79 core),1
microphone precondition skip,0 failures;85 Python tests across18 suites**.
An intervening full run has1 unexpected S3-unavailable error in the existing
premium-caption restoration test and two unusually long test durations (557/957s).
The cause of those delays is not established. A subsequent real S3 probe, the
same focused restoration test (0.45s) and this final full run pass without S3 code,
fixture expectations or timeout changes. All701 frozen file fingerprints and the
complete file set match after validation, excluding this mutable ledger. Project,
locked reference and recipe19 engine XERJ checks are fresh.
Existing upstream teardown/macOS Contacts-service diagnostics are not assertion
failures or proof of private contact retrieval. No schema, dependency, engine pin,
preparation recipe, permanent retention or S3-policy change. Real-account access,
network mutation and Telegram delivery are not tested. Hosted verification and
integration will be recorded on the attached PR after exact-head checks.

2FA is recorded in the current stage above. Global peer search, special/Premium/voice-message/global
privacy, account removal and the preceding parity gaps remain open.

## Previous stage: Telegram privacy exception membership (block 7)

Privacy now edits user/group allow and deny memberships in the existing settings
workspace. Reference list/add/remove/multiselect flows are implemented in own
SwiftUI; selection moves a peer out of the opposite list. Audience and membership
share one immutable confirmed draft. Untouched special rules and native identity
are preserved; duplicate/nonpositive/oversized or ambiguous additions fail closed.
Cached Telegram contacts appear initially; queries search cached contacts/chats,
with200 results and an explicit refine-query notice. Global remote search and
special-category editing remain open. No system Contacts or other account is read.

Each write retains the fresh exact server basis guard. Preserved/moved users need
hashes from that response; only newly added users may use fresh personal native
hashes. Every new group remains eligible in a fresh Postbox transaction. Missing/
min/ambiguous identities refuse the whole write. Empty/different ACKs remain
uncertain; the existing account-wide reconciliation barrier and lack of Telegram
CAS remain unchanged. Editor basis captures account/context before interaction;
callbacks after refresh/rebinding cannot borrow the new context, even with identical
rule values. Drafts from another context are never composed into a new draft.

Valid assertion REDs: rules4 tests/3 failures; directory3/2; native peers with
directory6/4; actual encrypted Postbox1/4; stale editor basis2/2. The final focused
30 XCTest pass. Required DB startup and final app build exit0 with0 compiler
warnings. Native synthetic QA verifies list navigation, contact/group selection
across queries, opposite-list movement, cancellation/discard, combined audience+
membership ACK, removal without audience change and preserved Premium rules.
Review restores read-only counters for nonstandard bases; native QA confirms
visible user/group counts and disabled writes. The final rebuilt bundle also
verifies contact addition and ACK through the captured editor basis. Strict signing
and unsigned executable payload equality pass. The owned QA process is stopped;
its isolated PostgreSQL data is retained. No real Telegram mutation is tested.

Earlier full runs pass1,819 XCTest before the final editor-context repair. The
final mandatory `scripts/test.sh` exits0: **1,821 XCTest (1,742 Telegram +79 core),
1 microphone precondition skip,0 failures;85 Python tests across18 suites**.
Existing upstream teardown/macOS Contacts-service diagnostics are not assertion
failures or proof of private contact retrieval. All694 frozen tracked/new file
fingerprints match after validation, excluding this mutable ledger. Project,
locked reference and recipe19 engine XERJ checks are fresh; queries are confirmed
against source. No dependency, engine pin, preparation recipe, schema, permanent
message retention or S3-policy change. Hosted verification/integration is recorded
on the attached PR; merge requires both hosted runs on its exact head.

Blocked users,2FA, global peer search, special/Premium/voice-message/global privacy,
account removal and the preceding settings/parity gaps remain open. Local synthetic
acceptance does not establish real-account behavior or Telegram delivery.

## Previous stage: Telegram privacy audiences (block 6)

The existing settings sheet now opens the reference privacy list
and separate audience editors for phone visibility/discovery, presence, profile
photos, bio, birthday, group invitations, forwarding attribution, calls and P2P.
All native user/chat/close-friend/Premium/bot/deny-contact exceptions retain their
exact order; audience changes replace only the recognized base/fallback rules.
Exception lists are currently read-only. Nonstandard bases remain read-only,
malformed/bounded-list violations fail closed, and phone discovery refuses Nobody.
Each confirmed write re-reads that key, checks the account and exact captured
basis, resolves every user from that fresh response and performs one typed RPC.
Min/missing/duplicate user identities are not silently dropped or substituted.
ACKs must preserve the confirmed audience/exceptions; empty or different ACKs
remain uncertain.30s deadlines and account/context guards require explicit
refresh after uncertain writes, including closing/reopening. No automatic
application retry or archive/S3/engine-pin/schema/dependency change is introduced.

Valid assertion REDs: rules6 tests/13 failures; controller/native8/10;
workspace/native-user integration10/2; category-feedback1/2; unsupported-discovery1/1.
The final focused17 XCTest pass.
Required DB startup and final app build exit0 with no compiler warnings. Actual
native synthetic QA verifies the reference category list, cancellation/ACK with
exceptions preserved, two-option discovery and independent P2P. It exposes status
from a different category and a lost parent draft after child ACK; the repairs
pass category regression and actual final UI. Parent drafts now block child
navigation until save or explicit discard. Final P2P ACK leaves calls unchanged,
with confirmation feedback confined to P2P. Strict signing and unsigned executable
payload equality pass. The owned QA process is stopped and isolated data retained.
The final mandatory `scripts/test.sh` exits0: **1,808 XCTest (1,729 Telegram +79
core),1 microphone precondition skip,0 failures;85 Python tests across18 suites**.
Existing upstream Postbox teardown/macOS Contacts-service diagnostics are not
assertion failures or evidence of private contact retrieval. All684 source/test/
script/dependency fingerprints match after validation. Project, locked reference
and recipe19 engine XERJ checks are fresh; scoped searches are source-confirmed.
This ledger records local validation. Hosted build/test and integration results
are recorded on the attached PR; merging requires success on its exact head.
All test/QA actions use synthetic data;
real accounts, private contents and real privacy mutations are not authorized.

Exception membership editing, voice-message/Premium/global privacy controls,
2FA, blocked users, account removal and notifications/storage/proxy/downloads
remain open. The local permanent-message archive policy is unchanged.

## Previous stage: Telegram settings, devices and local themes (block 5)

Telegram settings now open General, Appearance and Devices inside the existing
common workspace. Local system/classic/day/night palettes and four accents
persist in app preferences. Selected-account devices use current/pending/other
groups, application/IP/location details, calls/secret-chat acceptance, single/
all-other termination and reference7/31/93/186day TTL choices. Current-device
termination is refused. Every server mutation captures account/context/basis,
re-reads authorizations and checks the confirmed identity/set before a typed
pinned RPC.30s deadlines and a retained uncertain-account barrier prevent another
application write before explicit reconciliation. Empty responses and Bool false
are not ACKs.406 is a fresh-login rejection only for termination, not TTL or
acceptance settings. Message retention and S3 policies are unchanged. No engine
pin/preparation/dependency/schema change or third-party UI code is used.

Valid assertion REDs: session/controller9 tests/16 failures; native RPC3/3;
workspace integration1/1; empty ACK1/2; appearance2/6; mutation-error1/3.
The final17 focused XCTest pass. An intermediate app build fails on a missing
MainActor annotation in the extracted status helper; the corrected build passes.
Required `scripts/dev-db.sh up` and final `scripts/build-app.sh` exit0, with no
compiler warnings. The final mandatory `scripts/test.sh` exits0: **1,791 XCTest
(1,712 Telegram +79 core),1 microphone precondition skip,0 failures;85 Python
tests across18 suites**. Earlier whole runs (1,788 and1,790 XCTest) preceded the
final appearance/error fixes and do not replace this final result. Existing
upstream Postbox teardown and macOS Contacts-service diagnostics remain in test
output; they are not assertion failures or evidence of private contact retrieval.

Actual native UI in a separately signed synthetic bundle/explicit isolated
PostgreSQL schema verifies classic/night themes, persisted purple accent after
restart, existing send-key/photo-size controls, current/pending/other devices,
cancel/confirmed calls, single termination, TTL cancel/confirmed93days and
terminate-all leaving only the current device. Review finds a picker alert that
macOS never presents; a distinct Apply button plus confirmation resolves it.
It also finds preferredColorScheme(nil) retaining light mode after leaving
Telegram while the system is dark. The AppKit observer/resolver repair passes
native initial/change regressions. Actual UI verifies Telegram classic light →
Contacts system dark → Telegram classic light, preserving the accent and common
service sidebar. The final rebuilt bundle passes strict deep signing and unsigned
executable payload equality; its settings/device groups are verified again.
The owned QA process is stopped and its isolated data retained. No personal
account, real device mutation, private conversation, system Contacts contents,
Telegram delivery or payment is tested.

All677 frozen source/test/script/dependency fingerprints match after validation.
Project, locked TelegramSwift reference and recipe19 engine XERJ checks are fresh;
actual scoped searches are source-confirmed. This ledger records local validation.
Hosted build/test and integration results are recorded on the attached PR; merging
requires hosted success on its exact head commit.

Cloud/custom themes, wallpapers, scheduled night mode, exact reference palettes,
font size/bubble mode, privacy/2FA/notifications/proxy/storage/download settings,
QR linking, web sessions and real-account acceptance remain open; see the
reference-interface and Telegram ledgers. Block4 parity gaps below also remain.

## Previous stage: Telegram profiles/admin/shared media (block 4)

The existing common service/sidebar workspace now contains profile title/about
editing, member/admin directories, member restrictions/removal, group default
permissions and a separate shared-media search/gallery. Native role/membership
and cached-data checks determine available controls.64-member channel pages
retain raw offsets; basic groups use cached participants and boolean admin
rights. Exact actor/participant/basis checks run before bounded RPCs; confirmed
basic-admin updates preserve unrelated cached participants and their provenance.
Self/owner edits and implicit administrator demotion through bans are refused.
Finite restrictions use60seconds…365days, with a separate explicit forever
choice. Uncertain writes require explicit refresh and are never auto-resent.

Shared media keeps independent search/resources and opens the exact source
thread/index in the existing conversation. It reuses file borrowing, bounded
image decoding, playback, spoiler reveal and Save panel. The current per-chat
S3 prohibition and permanent PostgreSQL/S3 archive are unchanged. Engine
recipe19 exposes only the existing addUpdates wrapper; its body and native
state implementation are unchanged. Pins/license provenance remain reviewed;
build/test do not depend on research references.

Valid assertion REDs cover permissions/controller/native member admission,
gallery activation, basic groups, uncertain RPCs, wire flags, ACK cache CAS,
default permissions and finite bans/invalid member IDs. The final focused run
passes18 XCTest/0 failures. Earlier compiler errors are retained separately
and are not assertion REDs. One native Postbox fixture produced SIGTRAP on an
inherited MainActor transaction closure; moving fixture transactions into
nonisolated helpers resolves that harness failure. The production backend
already uses off-actor transactions.2 adaptation regressions pass. Required
`scripts/dev-db.sh up` and the final `scripts/build-app.sh` exit0. The mandatory
whole suite exits0:1,774 XCTest (1,695 Telegram +79 core),1 microphone
precondition skip,0 failures;85 Python tests across18 suites. Final review
then preserves scam/fake description suppression after an info ACK and routes
GIFs through the existing file row instead of an unsupported visual spinner.
After those display-only changes, the final build and native QA pass. The final
mandatory whole run also exits0: **1,774 XCTest (1,695 Telegram +79 core),1
microphone precondition skip,0 failures;85 Python tests across18 suites**.
All623 frozen source/test/script/dependency fingerprints match afterward. The
final incremental app build emits no compiler warnings. Existing upstream
Postbox teardown and macOS Contacts-service diagnostics remain in test output;
they are not assertion failures or evidence of private contact retrieval.

An explicit isolated synthetic PostgreSQL QA bundle confirms the common shell,
group profile, member search, immutable admin confirmation, updated rank,
default permission confirmation and title editing. Shared media shows50pt tabs
and3-column tiles; a decoded synthetic photo advances to video, and «В переписке»
opens visible message127 in the original chat. The final rebuilt bundle passes
strict deep signing and unsigned executable payload equality; its name edit
appears in the profile overview. CUA reports AXError/noWindowsAvailable when
rebinding or scrolling some modal sheets; rebinding plus AX controls permits
the checks above. Actual native member-list page2 scrolling is not established;
controller pagination has automated regression coverage.

Final display review also confirms a scam warning with description hidden after
saving a nonempty synthetic about value. The final rebuilt gallery decodes the
photo again; files and voice/round-video categories show their existing rows.
The synthetic GIF category is empty, so no animated-GIF renderer acceptance is
claimed. The owned QA process is stopped and its isolated data retained. Native
recording/playback devices and real account administration remain untested.

Project XERJ refresh exits0:665 files,614/614 classified code. The locked
TelegramSwift reference and recipe19 engine checks pass. A check after docs
changed returned STALE/exit1; a completed refresh supersedes it. Actual current
controller/reference-permission/native-title searches are source-confirmed.

No real account, private contact, Telegram network mutation or payment is used.
Real delivery/reconnect/admin acceptance remains block6. Invitation/member-add,
join-request/admin-log/ownership/statistics/avatar-edit/stories flows and full
borderless/zoom/thumbstrip/media-calendar gallery parity remain open; see
`reference-interface.md`. This slice does not establish full Telegram parity.

## Previous stage: Telegram extended search (block 3)

Reference-led search stays in the existing common service/sidebar workspace.
Global media tabs and all/private/group/channel scopes can search without text;
an optional selected chat restricts message results. Conversation search adds
native sender suggestions, older/newer navigation across50-message pages,
return to the result list and local-calendar timestamp jumps. Opening a result
keeps the query and separate destination/topic drafts. Request/context tokens
reject stale account/chat/topic/filter callbacks and UI activation.

Engine recipe18 validates exact sender/sub-peer resolution and positive ordinary
Int32 topic IDs. Raw packed peers are bounded before legacy PeerId assertions.
Local Secret results are excluded from group/channel searches and filtered by
native tags before merging/counting. Empty Secret media FTS and sender-filtered
Secret searches remain explicitly unsupported. Global navigation distinguishes
real forum flags from ordinary channel thread1 and Saved/monoforum packed peer
threads; the latter open supported all-messages history, without inventing a
forum topic. Full Saved sub-peer navigation is outside this slice.

Valid REDs retain the original criteria/model/native boundary failures. The
first combined42-test candidate exits1 with107 ordinary assertions, then42/0
passes. Calendar/sender coverage initially fails on a test fixture's unobserved
forum list; observing that fixture repairs4/0, including23/25-hour DST days.
An additional packed high-bit fixture produces native SIGTRAP/exit1, not an
ordinary assertion-only run; the preconstruction guard repairs it within the
46/0 focused run. Read-only review then finds two navigation races and ordinary
native channel/Saved thread handling: the former reproduces2 tests/5 ordinary
failures, followed by2/0; native destination fixtures reproduce6 tests/21
ordinary failures, followed by6/0. A final migrated-group regression reproduces2
assertions: a chat-restricted global result must retain the modern conversation
and its exact old native MessageIndex. The repaired regression passes1/0.
The first whole candidate passes1,755 XCTest (1,676 Telegram +79 core),1
microphone precondition skip,0 failures;83 Python tests across17 suites. After
the migration repair, the whole suite passes1,756 XCTest (1,677 Telegram +79
core),1 microphone precondition skip,0 failures and83 Python tests across17
suites. All609 frozen source/test/dependency fingerprints match afterward.
The final mandatory whole suite after the CI-only fixture repair also exits0:
**1,756 XCTest (1,677 Telegram +79 core),1 microphone precondition skip,0
failures;83 Python tests across17 suites**. All609 frozen source/test/dependency
fingerprints match after this run. The final incremental app build emits no
compiler warnings. Upstream Postbox teardown and macOS Contacts service
diagnostics remain in test output; they are not assertion failures or evidence
of personal-contact access.

Final XERJ project refresh exits0:651 files,600/600 classified code. Engine
recipe18 and the locked TelegramSwift reference are fresh. All three content
checks and actual source-confirmed search/navigation queries pass. The earlier
check during an unfinished refresh returned STALE/exit1 and is retained as a
failed attempt; it is superseded by the completed refresh and final checks.

An isolated native QA bundle with explicit synthetic PostgreSQL/Postbox confirms
the common shell,44pt search header,130 results→history with retained query,
older navigation, sender selection65/50, calendar15.11.2023, global6 photos→1
channel→2 groups, exact forum topic opening and an optional chat restriction.
The final reviewed `scripts/build-app.sh` exits0. Strict deep QA signing and
unsigned executable payload equality pass. Rechecking the rebuilt bundle
confirms query→history, the separate visible draft and repeated Cmd-F refocus
without clearing the query. No real account, Telegram network delivery,
private contacts or payments are used. Reference renderer/calendar details,
full participant directories and Secret media parity remain listed in
`reference-interface.md` and `telegram.md`.

## Previous stage: Telegram extended messages (block 2, locally verified)

The authorized sequence remains: (1) media polish; (2) selected reply quotes,
server drafts, custom emoji, code highlighting, forum topics and special
secret/paid scenarios; (3) extended search; (4) profiles/admin/gallery;
(5) settings/sessions/themes; (6) real-account delivery/reconnect acceptance.
Block 1 was published at e29a731; its physical/account acceptance limits below
remain. Block 2 implementation and local validation cover the contracts below;
the listed special-conversation and actual-account acceptance limits remain.

Implemented contracts cover selected Unicode/UTF16 reply quotes with observed
account limits; server draft observation/reconciliation with explicit choices
and atomic native/basis/local CAS; custom emoji catalogs, insertion and bounded
WebP/TGS/WebM playback; independently pinned Prisma/Boost syntax highlighting;
forum topic lists and isolated history/search/read/draft/upload/forward scopes.
Caption wire22 freezes explicit custom-emoji policy over resource schema19;
old wires retain their original policy and reject injected markers. Shared
native queue admission rechecks complete media registries, account tier,
destination/topic permissions and the caller's own durable receipt. Forwarding
never inherits the source message's old Stars charge (engine recipe12).

Secret sending is restricted to verified active plain text. Secret media,
rich text/replies/forwarding, key agreement and TTL workflows remain unsupported.
Paid sending confirms immutable destination/count/unit/total, with native atomic
consent/queue admission; balance and paid-media purchase/fetch are unsupported.
Personal-account delivery/reconnect acceptance remains block6. These boundaries
do not establish full Telegram or special-conversation parity.

The first mandatory full candidate exits1: 1,706 XCTest (1,627 Telegram +79
core),1 microphone-authorization precondition skip,17 assertions in recorder
final-admission tests;70 Python regressions pass. Root fixes the conversation
token passed as an account token. The focused compiled follow-up exits0:
44 recorder/server-draft/special-composer tests,0 failures. Earlier valid REDs
and repairs for native forwarding/fees, scoped paging, Undo/Redo, captions,
descriptor publication and approval cancellation remain in separate raw logs.
No failed attempt is relabelled PASS. Successful final validation below
supersedes these candidates.

A later isolated full attempt exits1 on native Postbox SIGTRAP while reading a
malformed forum topic; the Telegram target aborts before completing. The native
seed renderer consumes topic data before the UI adapter, so an adapter-only
structural check is insufficient (targeted exit1 retained). Recipe13 moves the
guard into native rendering/forum operations and43 focused tests pass. Separate
compiled REDs then prove invalid notification variants, overflowing bundled
sound IDs and noncanonical author bits. Recipe14 adds bounded semantic checks;
46 focused XCTest and73 Python pass, including exact native fixtures and every
truncated topic prefix. No crash is reported as an assertion-only test failure
or a successful complete run.

The next full attempt completes1,714 XCTest but exits1 on one existing Ogg
mutation test. The encoder's random serial low byte can already equal9, making
the intended corruption a no-op. An all-page serial9 baseline with independent
CRC repair reproduces that failure deterministically. The test now changes the
one-page serial to10 and asserts every mutation changes a byte; all11 invalid
semantic cases remain. The focused7 XCTest and73 Python follow-up exits0.

Final isolated `scripts/test.sh` exits0: **1,714 XCTest (1,635 Telegram +79
core),1 microphone-authorization precondition skip,0 failures;73 Python tests
across17 suites**. Root verifies all622 frozen source/dependency/test fingerprints
after the run; the only change since final native UI/build is the Ogg test.
Two scoped read-only worker reviews cover topic decoding and native admission/
durable receipts, with an additional Ogg test review. Root verifies the18-file
boundary manifest and current reviewed hashes. These are source reviews, not
external runtime approval or actual-account delivery evidence.

`scripts/dev-db.sh up` and `scripts/build-app.sh` exit0; the app build has no
compiler warnings. Strict deep QA signing and unsigned executable payload
equality pass. Native CUA checks use a separate DEBUG bundle, explicit isolated
PostgreSQL schema and encrypted synthetic Postbox: common service sidebar,
selected quote accessory, two custom-emoji insertions/Undo/Redo, independent
topic drafts, caption insertion/Undo/Redo and exact three-emoji caption after
restart in its original topic. Both server-draft choices replace/retain the
visible input correctly. Secret verification shows the reference-sized image
and four public QA fingerprint lines; unsupported controls are disabled. The
synthetic paid prompt shows3×3=9 Stars, Return cannot confirm and Cancel closes.
No real account, payment or server delivery is used or inferred.
The final successful suite retains upstream Postbox teardown and macOS Contacts
service diagnostics; they are not assertion failures or evidence of successful
personal-contact access. Full dependency rebuilding also emits inherited
upstream compiler warnings; the final incremental app build emits none.

Native UI exposed a reading-view scroll reset. Two compiled hosting-window
regressions reproduced5 assertions; independent text measurement repairs it.
The related45 XCTest and70 Python checks pass. A rebuilt signed QA bundle
retains its position after scrolling and shows message118 after search →
history, with code highlighting and the adjacent spoiler still concealed.
Upload preview currently names the chat without the topic title;
the frozen/native destination still includes and validates the selected topic.

XERJ v8 refused VPX lock fields (actual exit1). Final separate v9 refresh covers
639 files,588/588 classified code, exit0; final recipe14 engine refresh covers
721 files,686/686 code, exit0. Project/reference/engine fingerprint checks and
source-confirmed queries pass after the last source changes.
Indexes/configurations and raw diagnostics remain ignored locally.
The plain staged whitespace check exits2 on preserved RLottie license spacing;
five public compiled-closure notice payloads match their pinned upstream bytes.
All six notices, including unused STB provenance, remain exact in prepared
source. The staged check excluding that one public notice file exits0.

## Previous stage: Telegram media block

The first media block is implemented against the locked TelegramSwift reference
inside the common Makosh window. New preparations use schema19; schemas1–18
retain their original policies and bytes. No new third-party source/dependency
or research-checkout build dependency is introduced.

- Selected JPEG/image MIME with actual WebP bytes follows ordinary photo staging,
  including the first animation frame, retains the exact File original and can
  group. Typed image/webp remains a document. New PSD/DCR/BM/ICNS aliases match the
  reference; exact old aliases stay recoverable. Real native queue/recovery
  covers both S3 choices.
- Account tier/config supplies the caption limit (default1024/2048), frozen with
  ordered native File-caption capability. Current Markdown/cloud hashtags use
  UTF16-safe ranges. Native enqueue checks the current account limit again;
  reorder/remove, cover edits, Archive, receipts and restart preserve the policy.
- Native chat File/Media drop zones and append into the open modal use the same
  owned staging pipeline. All providers must yield local URLs, with cancellation
  and a30s deadline. Account/chat/input/preparation revisions reject stale results;
  active URL deduplication releases removed entries for re-addition.
- Append retains the old prefix, rebuilds an active ZIP and authenticates the
  complete candidate before whole-byte Postbox compare-and-swap. A lost ACK retries
  the exact immutable candidate; no recapture or automatic Send. Pending install
  freezes editor/options and blocks Send. Pre-install failure preserves the old
  restart preparation; an uninstalled append is not itself restart-recoverable.
- File graphics/PDF use70pt thumbnails, music a40pt play row and typed static
  WebP a transparent208pt aspect fit. Owned bounded decoders use generic fallback.
  Music starts only on Play from an independent private copy; cancel/deadline stop
  an in-flight preparation and discard late copies. PDF parser peak CPU/memory is
  not established beyond the input/page/pixel bounds. Full animated stickers
  remain in the later sticker block.
- Recorder controls use the floating120pt circle/80pt center, strict100pt lock
  drag,350ms stationary hold within2pt, outside-cancel confirmation and prepared
  round poster. Own gradient/shadow replaces reference assets. Duration cap still
  requires explicit Send. Both S3 policies apply to every new resource and ZIP;
  OFF forbids all new S3 copies and local records never promote after enable.

Focused validation retains compiled REDs and repaired results separately:
38 XCTest/50 Python photo/drop/recorder;36/50 MIME aliases;75/50 caption/native
policy;129/50 append persistence/native boundaries;53/50 integrated Controller,
drop-provider and document-preview cases;27/50 composer compatibility and current
batch cancellation. All listed GREEN runs exit0; counts overlap. Review fixes
cover pending-append edits, removed-URL deduplication, stale drop errors,
JPEG-selected WebP File semantics and cancelled audio preparation. Root verifies
five frozen final append-review fingerprints against current source. These are
recorded source reviews, not an external runtime approval gate.

Required `scripts/dev-db.sh up`, `scripts/test.sh` and `scripts/build-app.sh`
exit0. Final isolated full suite: **1,432 XCTest (1,353 Telegram +79 core),
1 microphone-authorization precondition skip,0 failures;50 Python tests**.
Incremental compilation and app build have no compiler warnings. Strict deep
signatures and normalized built/QA executable payload equality pass. No UI upload
work runs concurrently with the final successful attempt.
The first full attempt fails14 assertions in three legacy composer fixtures after
Model moves new single selections onto the batch path. The fixtures now directly
exercise the retained single-provider adapter; current Model batch transfer and
rich-input cancellation have real owned-file coverage. Focused27/50 passes.
The second full attempt has one global temporary-directory inventory assertion
failure while native QA creates stages concurrently (one extra directory).
No cleanup assertion is relaxed. The owned QA process is then identity-checked
and stopped with SIGTERM before the isolated final attempt. Raw failures remain.

Actual native QA uses an isolated synthetic PostgreSQL schema/Postbox and S3
configuration. In the final signed build the common service sidebar remains,
the same two-photo preparation IDs and emoji/Markdown caption restore after
restart, Archive becomes one ZIP, Cancel returns the exact original caption,
and PDF shows its graphic thumbnail/name/size. Earlier same-block UI observes
transparent static WebP, PNG File/Media transitions and explicit music Play →
Pause. Repeating music picker QA in the final build stalls in the OS open panel;
PDF completes. The external coordinate-input tool returns `noWindowsAvailable`.
No physical drag/drop/timed-hold PASS is claimed; drop and recorder state/gesture
logic have automatic coverage, and synthetic AX-start was observed. No personal
account, server send, camera/microphone capture or new permission grant occurs.
The owned synthetic runtime is stopped and its recoverable preparations retained.
Full live Account/hardware acceptance remains the later acceptance block.

Final project XERJ refresh indexes520 files,476/476 classified code, exit0;
freshness and source-confirmed append/drop queries pass. Locked TelegramSwift
freshness passes. The earlier bounded three-file integration snapshot was used
before Controller edits and is not represented as the final fresh index.
The final full run retains751 SQL-prefixed Postbox t19 teardown diagnostics
and170 system CoreData/contactsd connection-failure diagnostic lines (including
10 runtime warnings). No personal-contact read API is added or successful
account/contact access inferred from them. Earlier failed attempts remain
separate from the final exit0; new-head hosted CI is tracked separately.

## Previous stage: pinned primary Mozjpeg photo encoding

The next photo slice integrates independently pinned Mozjpeg4.1.4 portable C
from the selected Telegram-iOS tree.92 unchanged source/provenance files produce
an authenticated98-file package without upstream build scripts or research
checkouts. An own quiet C error/ownership boundary and white RGBX rasterization
use FASTEST defaults, integer DCT, optimized Huffman, quality75 and simple
progression. ImageIO.75 remains fallback; covers and frozen retained photos stay.
Source/notice review and exact grants are in THIRD_PARTY_NOTICES.md.

Compiled RED2 tests/4 failures exposes sequential ImageIO and different DQT;
white compositing already passes. Python preparation RED fails on the missing
artifact; GREEN5 tests covers exact committed bytes/notices, offline reuse,
tamper/extra/missing/symlink refusal, changed pins and unsafe source paths/modes.
First integration compilation exposes missing C standard prerequisites in the
module umbrella. The next exposes6 included C fragments omitted from the
compilation-unit list. A full literal-include closure review and RED fragment
fixture fix the selection; those fragments remain included, not compiled twice.
FileIO GREEN15 tests passes. Initial C compilation emits15 upstream decoder
precision warnings plus3 existing test warnings; these are retained as actual
diagnostics, not rewritten into a pristine build claim.

A strict pure-primary-colour staging fixture initially fails2 assumptions:
host ColorSync conversion produces extra channel components. Bounded raw-pixel
diagnostics confirm that expectation is wrong. An explicit RGBX C-boundary test
replaces it and verifies decoded channels independently of host profile; white
compositing, progressive/DQT, invalid buffer/shape/overflow/output ownership and
real native queue/recovery under both S3 policies pass in focused coverage.
Frozen source review identifies a stale jpeg_mem_dest caller pointer after a
successful growth followed by a fatal allocation error. The test-only allocator
fixture first exposes a duplicate internal vendor symbol at link time; renaming
that test symbol yields a compiled RED: allocation3 reports both double-free and
leak. An own destination manager publishes current heap ownership after every
successful realloc. GREEN3 C-boundary tests verifies success, initial allocation
failure and growth failures, cleared outputs and no leaked/double-freed buffer.
The fixture is reachable only from the test target; no allocator hook is added
to production. Original failed review and remediation evidence remain separate.
Final database startup, full tests and app build exit0: **1,362 XCTest (1,283
Telegram +79 core),1 microphone-authorization precondition skip,0 failures;
50 Python tests**. This full incremental compilation/build emits no warnings;
671 SQL-prefixed Postbox t19 teardown diagnostics remain, with no bare line.
The built app contains the primary boundary and no test allocator fixture.

Native picker QA with S3 OFF prepares a progressive quality75 JPEG1280×640
from the same synthetic3000×1500 PNG. After retaining the source elsewhere and
removing its picker path, restart restores the photo and emoji caption. Three
pre-primary preparations retain exact pointer/payload/UUID fingerprints:
2560×1280/.85,2560×1280/.75 and1280×640/.75. Baseline, post and reopened readbacks
each pass1 XCTest/50 Python tests; eight current photo/raw resources remain
local,34 encrypted records include earlier preparations, no receipt/pending/S3
objects and no promotion after enable/resume. The post readback rebuild reports
the same3 existing test warnings; baseline/reopened report none. A transient
ScreenCaptureKit-3811 error resolves on rebind; actual AX and screenshots confirm
preparation/recovery. Strict deep signatures and normalized built/QA payload
comparison pass. Owned runtime is stopped; temporary QA source removed.
No personal Account, server send, hardware or new permission grant.

Root validates116 frozen fingerprints,9 base/patch reconstructions and13
original readonly review argv/exits. Remediation validates16 frozen entries,
7 live source files and6 original commands, retaining one failed discovery
followed by corrected reads. No new findings; the original P1 report remains
failed and separate from its source-resolved addendum/root RED-GREEN. Worker
runtime gates remain skipped, route/usage unknown. This is manual recorded
consistency; no helper/route authenticity/runtime approval is inferred.
Final XERJ project refresh/freshness/query exits0:496 files,452/452 classified
code. New destination-manager and existing picker hits are source-confirmed;
locked TelegramSwift freshness passes. The Mozjpeg JSON fields cause the
previous v6 frozen dataset to refuse schema evolution (exit1); v7 succeeds,
with the original diagnostic retained. Source-index scope still excludes
reference submodules; pinned C source inspection/review is separate.
Hosted CI for preceding9c88567 succeeds in both
[PR run38207929581](https://github.com/Mesteriis/makosh-native/actions/runs/38207929581)
and [push run38207926426](https://github.com/Mesteriis/makosh-native/actions/runs/38207926426).
New-head CI remains separate.
Full migration remains active; typed WebP grouping and later workflows/services
remain open. No universal reference-build byte equivalence is claimed.

## Previous stage: reference photo size and ImageIO quality setting

New ordinary photos default to1280px; an explicit large-photo preference selects
2560px. Both use ImageIO JPEG quality.75. Probe and staging capture the same per-preparation
value. The preference is exposed in the existing Settings and Media-preview menu,
following FastSettings.swift:301–315, GeneralSettingsViewController.swift:198–201,
402 and PreviewSenderController.swift:404–411. Its menu handler changes the shared
preference without regenerating current media; Makosh likewise applies it to new
preparations and retains already prepared bytes. No hidden defaults read occurs
inside the engine. Raw File bytes, covers, schemas and dependency pins are unchanged.
Restoration still admits prior2560px photos without transcoding.

Additional XERJ/source inspection of ImageCompression.swift:53–75 establishes
that reference compressImageToJPEG tries Mozjpeg75 first, then ImageIO.75 as a
fallback. This slice retains the existing ImageIO encoder and does not establish
primary encoder/quantization/byte parity. Reviewed Mozjpeg dependency/pin/license/
build integration is the next remaining photo task.

Compiled RED2 tests/3 expected failures reproduces the2560 default and.85 encoder.
The first focused run exposes four invalid mode-edit assertions in a fixture
without a durable recovery store. Those assertions move to the real native store
regression. The next run exposes two obsolete2560 expectations in the orientation
test; explicit1280 standard and2560 large cases replace them. Final focused41
XCTest/45 Python tests pass, including both sizes through real PostgreSQL/Postbox/
S3 capture, exact retry, mode edits, restoration after source removal and native
local queue bytes/dimensions/caption/complete receipt under both storage policies.
OFF resources never promote after enable/resume.

Native preceding-build picker QA retains a2560×1280/.85 preparation with S3 OFF;
readback passes1 XCTest/45 Python tests, records exact pointer/payload fingerprints,
and confirms28 retained encrypted local records and no S3/receipt/pending copies.
Reverting just the ImageIO quality to.85 fails the new quantization regression
twice (both sizes); source is restored byte for byte. Final database startup,
full tests and app build exit0. Full suite: **1,358 XCTest (1,279 Telegram +79
core),1 microphone-authorization precondition skip,0 failures;45 Python tests**.
Full compilation, build and all three UI readbacks have no compiler warnings.
671 SQL-prefixed t19 teardown diagnostics plus one bare line remain separate.

Actual native picker QA uses the same synthetic3000×1500 PNG with S3 OFF.
The menu-control AX predicate is RED in the preceding build and GREEN in the
final app. The menu and Settings share the preference, including persisted
ON/OFF across restarts. New large preparation is2560×1280/.75; new standard
preparation is1280×640/.75. The final app restores both and the preceding
2560×1280/.85 photo after removing the original picker path. Old and large
pointer/payload/UUID fingerprints remain exact through preference changes.
Final readback passes1 XCTest/45 Python tests: six current photo/raw resources
are encrypted local records,32 retained records include earlier preparations,
no receipt/pending/S3 objects, and no promotion after enable/resume. Strict deep
signatures and normalized built/QA Mach-O payload comparison pass. Owned runtime
is stopped and temporary QA source removed; no Account/server send or hardware.

Bounded frozen review finds no actionable issues. Root verifies15 frozen/live
source/reference hashes,11 base files,11 patch reconstructions and12 original
worker argv/exits. Manual recorded-consistency validation applies; the portable
helper is unavailable in the exposed skill tree. Five worker runtime/service/
index gates remain skipped; observed route/usage are unknown. Final XERJ project
refresh/freshness/query exit0:482 files,444/444 classified code. Photo-size enum,
staging and eligibility hits are confirmed against source. Locked-reference
freshness also exits0. Hosted CI for preceding c733ba1 succeeds in both
[PR run38206405923](https://github.com/Mesteriis/makosh-native/actions/runs/38206405923)
and [push run38206402108](https://github.com/Mesteriis/makosh-native/actions/runs/38206402108).
New-head CI remains separate. Full migration remains active; primary Mozjpeg,
typed WebP grouping and later reference workflows/services remain open.

## Previous stage: versioned source-only Media preparation

New ordinary picker preparations use schema17; a cached ZIP uses schema18.
Media follows ordered logical-source options even when every canonical payload
is a document (for example32px PNG at36DPI, logical64px). Payload kinds, names,
bytes and native attributes remain frozen. The new allowance does not enable
visual-only controls or a photo mosaic for document rows. A misleading .jpg WebP
may retain Media while sending its original document; typed WebP grouping stays
disabled and is a remaining reference difference.

Schemas1–16 retain the visual-payload requirement. Retry and caption/mode/member/
cover edits preserve the original policy; restoration never reclassifies or
upgrades old resources. Guarded Archive capture/install reconstructs the candidate
under its predecessor's policy:15→16 or17→18. Cross-family transitions refuse.
New cached18 can return to source-selected Media; changed members invalidate the
ZIP descriptor back to17 and retain all old encrypted records. Storage policy,
byte recipe, dependency pins and native message attributes are unchanged.

Compiled RED5 tests/3 expected failures reproduces the missing schema17 codec
and low-DPI File normalization. GREEN18 tests passes. Native test development
exposes one async-XCTest-autoclosure compilation error and a fixture SIGTRAP:
its transaction closure inherited MainActor. A nonisolated fixture helper fixes
the actor boundary; the three native regressions then pass. Initial full suite
runs1,350 XCTest with79 failures (3 unexpected): old15/16 expectations, seven
Archive admission fixtures missing the predecessor policy, and the old misleading-
.jpg WebP mode expectation. These are corrected without weakening the old-schema
regressions; focused156 XCTest/45 Python tests passes. The new source-policy
mutation fails one native regression with4 expected failures under both storage
policies; production source is restored byte for byte.

New regression coverage includes schema17/18 strict fields/source completeness,
old all-document Media refusal, immutable retry, mode changes, Archive cache/
member removal, cross-family capture/install rejection, old15 File restoration,
and actual local native queue original bytes, grouping, caption and complete
receipt under S3 ON/OFF. OFF resources never promote after enable/resume.

Final database startup, full tests and app build exit0. Full suite:
**1,352 XCTest (1,273 Telegram +79 core),1 microphone-authorization precondition
skip,0 failures;45 Python tests**. Full compilation, build and UI readback have
no compiler warnings.663 SQL-prefixed t19 teardown diagnostics plus one bare
line remain separate from compiler warnings.

Actual native picker QA with S3 OFF reproduces File in the preceding app and
Media in the final build for two32px PNG at36DPI. The same AX predicate is
RED→GREEN. Both remain document rows with exact original bytes. Media→Archive→
Media retains two stable IDs and the emoji caption. Exact owned-process restart
without the original picker paths restores cached18 Media. Reopened readback
passes1 XCTest/45 Python tests: two files plus ZIP are encrypted local resources,
26 retained records include earlier/cancelled preparations, no receipt/pending
or S3 objects, and no promotion after enable/resume. Strict deep signatures and
normalized built/QA Mach-O payload comparison pass. The runtime is stopped and
temporary QA source removed; no personal Account, Telegram server send or hardware.

Bounded frozen review finds no actionable issues. Root verifies26 frozen/live
source/reference hashes,20 base files,20 patch reconstructions and20 original
worker argv/exits. This is manual recorded-consistency validation; the portable
helper is unavailable in the exposed skill tree. Worker runtime gates stay
skipped and observed route/usage unknown. Final XERJ refresh/freshness/query exit0:
482 files,444/444 classified code. The Media rules hit is confirmed against
current source. One premature freshness check reports STALE while refresh is
still running; the post-completion check exits0. Locked-reference freshness also
exits0. Indexes, runtime configuration and raw evidence remain ignored.
Hosted CI for preceding a4ae70f succeeds in both
[PR run38204982918](https://github.com/Mesteriis/makosh-native/actions/runs/38204982918)
and [push run38204979706](https://github.com/Mesteriis/makosh-native/actions/runs/38204979706).
New-head CI remains a separate gate. Full migration remains active; default1280/
optional2560 and JPEG.75, typed WebP grouping and later reference workflows/services
remain open.

## Previous stage: static-photo payload pixels separated from source options

New static-photo preparation follows SenderController's transformed-pixel
predicate: height≥40 and width/10≤height. Width<40 and reciprocal tall aspect
alone no longer force File. The owned no-follow snapshot, source decode bounds,
cancellation and GIF/WebP/multiframe exclusions remain. The probe and staging
share the existing2560 maximum; orientation and non-square DPI are checked
against actual generated JPEG dimensions. Source logical facts/options and
frozen preparation kinds/bytes remain independent; schemas/pins are unchanged.
The all-File Media allowance needs a separate version gate to preserve existing
schema14–16 validity. Reference default1280/optional2560 and JPEG.75 versus the
current2560/.85 are also explicit next gaps; this slice does not claim full parity.

Compiled initial RED25 tests/18 failures (one unexpected nil-unwrap consequence)
reproduces payload/option conflation. Two initial GREEN attempts expose wrong
non-square-DPI expectations; a bounded diagnostic records actual transformed
sizes and corrected literals. An integration fixture initially compares the
retry revision incorrectly; it is corrected to assert immutable resources/input.
Focused final GREEN53 XCTest/0 failures and45 Python tests includes new narrow
photo/raw pairs under both storage policies, exact restore after source removal,
no recapture on retry, native local queue JPEG bytes/dimensions/caption/receipt,
OFF absence from S3 and no promotion after enable. Existing frozen mixed-File
native regressions remain unchanged. Reverting just the generation predicate
makes the new integration test fail8 assertions (one unexpected nil-unwrap
consequence); GREEN source is restored byte for byte.

Actual native picker QA with S3 OFF reproduces a39×48 PNG as a File row in the
preceding app, then shows both selected PNGs as photos/mosaic in the final build.
The same screenshot/AX predicate is RED (zero green pixels/missing narrow JPEG)
and GREEN after the change and exact owned-process restart. Original picker paths
are moved before restart; both stable IDs and the exact emoji caption survive.
Reopened readback passes1 XCTest and45 Python tests: two photo/raw pairs, exact
original bytes,21 retained encrypted local records including prior/cancelled
preparations, no receipt/pending and no remote object for the four new resources,
including after enable/resume. Runtime is stopped; temporary QA source is removed.
No personal Account, Telegram server send or hardware is used.

Required database startup, full tests, app build and strict deep signatures
exit0; normalized built/QA Mach-O payload comparison also passes. Full suite:
**1,346 XCTest (1,267 Telegram +79 core),1 microphone-authorization precondition
skip,0 failures;45 Python tests**. Full compilation repeats three pre-existing
diagnostics (six warning lines); build and final UI readback have no warnings.
651 SQL-prefixed t19 teardown diagnostics plus one bare line remain separate
from compiler warnings.
Bounded frozen review finds no actionable issues. Root verifies19 frozen/live
source/reference hashes, five before hashes and24 original worker argv/exits.
Report metadata is corrected/normalized separately with immutable originals;
worker runtime gates stay skipped, observed route/usage unknown. Final XERJ
refresh/freshness/query exit0:482 files,444/444 classified code. The shared photo
maximum hit is confirmed against source; locked-reference freshness also exits0.
The initial freshness refusal after test edits is retained, then resolved by
refresh. Indexes, runtime configuration and raw evidence remain ignored.
Hosted CI for preceding f5cb727 succeeds in both
[PR run38203402066](https://github.com/Mesteriis/makosh-native/actions/runs/38203402066)
and [push run38203398907](https://github.com/Mesteriis/makosh-native/actions/runs/38203398907).
Those results do not establish CI for this new slice. Full migration remains active.

## Previous stage: single/separate upload preview and safe video looping

Single and separate ordinary photo/video previews now share the existing bounded
ChatLayoutUtils-derived size rules. This removes the separate-row200pt cap/120pt
floor and single-preview240pt cap. Loading/error states keep the same bounds;
File, recorded-round and grouped-mosaic renderers retain their separate paths.
Send projection, storage policy, schemas and dependency pins are unchanged.
OFF continues to forbid every new S3 copy, including preparation/recovery.

Actual isolated native screenshot predicates fail before production edits:
portrait separate height394px and single square478px, each expected640px.
The same predicates pass after the change:634px and638px; wide photo154px,
expected160px (12px edge tolerance). Grouped squares, separate-row scrolling,
single photo/video, item removal and exact owned-process restarts are inspected.
Reopened readback passes1 XCTest and45 Python tests: six stable item IDs across
four prepared Media sets, empty inputs,14 retained encrypted local resources,
no receipt/pending and no remote object for the11 currently referenced resources.
Removed resources remain retained locally. The owned runtime is stopped;
temporary QA sources are removed. No personal Account, Telegram send or hardware.

Preceding head f373b0 has one failed hosted
[PR run38201383378](https://github.com/Mesteriis/makosh-native/actions/runs/38201383378)
and one successful [push run38201380082](https://github.com/Mesteriis/makosh-native/actions/runs/38201380082).
The failed round-loop assertion observes hidden rate1 instead of0. Source review
finds unconditional hidden seeking and visible restart before asynchronous seek
completion; exact AVPlayer internal ordering remains an inference. A narrow
native-seek boundary and the production EOF handler permit held-completion tests
with real loaded AVPlayers. Compiled RED3 tests/7 expected failures reproduces
early restart, hidden seeking and duplicate requests. The fix pauses before seek,
waits for successful completion and rechecks visibility, generation, player and
seek identity. Stop/replacement invalidate it. The former50ms hidden-EOF wait is
replaced by synchronous handling; actual native-loop tests still verify wraps.
Focused GREEN26 XCTest/0 failures and45 Python tests covers native playback and
held-completion hide/reveal, failed seek, duplicate EOF, stop/replacement and
unchanged stage bytes. Sizing focused GREEN36 XCTest/0 failures and45 Python tests.

Required database startup, final full tests, app build and strict deep signatures
exit0. Final full suite: **1,344 XCTest (1,265 Telegram +79 core),1 microphone-
authorization precondition skip,0 failures;45 Python tests**. Cached final
compilation has no warnings;647 SQL-prefixed t19 teardown diagnostics plus one
bare line remain separate. Initial sizing/loop-test compilation repeats three
pre-existing compiler diagnostics (six warning lines). The skip uses no hardware.
The final built app is inspected again with the restored single video and then
stopped. Final bounded frozen review reports no actionable findings. Root checks
its two artifact hashes,14 frozen source/reference hashes, seven recorded worker
argv/exits and six original root evidence records (three nonzero REDs retained).
Eleven frozen/live sources match exactly; the only delta removes one blank EOF
line and is verified separately. Worker runtime checks stay skipped and observed
route/usage unknown. The preceding CI review's P2/P3 are addressed by this patch;
new-head hosted CI remains a separate gate.
XERJ project refresh/freshness/query exit0:482 files,444/444 classified code;
loop-controller hits are confirmed against source. Locked-reference freshness
and source-confirmed media-sizing/visibility queries also exit0. Index/evidence
and machine configuration stay ignored.
Next: continue verified mixed/special classification, caption and preview/gesture
gaps before later services. Full migration remains active; complete pixel parity
and live-account delivery are open.

## Previous stage: reference upload-preview mosaic

Grouped visual Media now has separate preview geometry; source aspect ratios
continue to control history. Upload preview follows the locked reference's
square ratios, distinct2/3/4-member forms,5–10 row scoring/tie order,4pt gaps
and display-scale flooring. The bounded trailing singleton is centered.
Existing chunking/actions/IDs, mixed-list rendering, send/storage behavior,
schemas and dependency pins are unchanged. Mixed/special-media/gesture and full
pixel parity remain open; this is one sequential migration slice.

Observed screenshot RED before production edits measures the two portrait tiles
at410×636 and416×639px. The same calibrated predicate passes in the final app:
410×410 and416×416px. Earlier harness failures (missing system Pillow and an
incorrect color-profile threshold) are retained and do not count as product RED.
Native AX/screenshots additionally verify3/4-member forms, scroll access and all11
IDs in a ten-member group plus a centered100×200pt singleton. Exact owned-process
restarts preserve the prepared sets. Readback passes1 XCTest and45 Python tests:
four prepared Media groups, exact20 item IDs/order, empty inputs,40 encrypted
local resources, no receipt/pending and no remote object for any resource.
A review then finds a0.25pt centering difference for9/420pt/scale2: reference
bounds are measured before component flooring. The extracted sizing boundary
compiles RED1 test/1 expected failure419.5≠420. Raw bounding dimensions now drive
centering. One intermediate GREEN compilation fails on CGFloat?→Double and is
corrected; the actual final focused/full/build gates below pass. Final native UI
rechecks the square predicate, removes only items11/10 through their own menus,
and displays all nine remaining IDs/three rows. Final reopened readback passes
1 XCTest and45 Python tests:18 remaining IDs across four prepared sets, empty
inputs,40 immutable local resources and no remote object/receipt/pending.
The owned runtime is stopped; temporary QA sources are removed. No personal
Account, Telegram server send or hardware is used.

Required database startup, full tests, app build and strict deep signatures exit0.
Focused final GREEN12 XCTest (six new preview +six history)/0 failures and45 Python
tests. Full suite: **1,337 XCTest (1,258 Telegram +79 core),1 microphone-authorization
precondition skip,0 failures;45 Python tests**. Cached compilation has no warnings;
647 SQL-prefixed t19 teardown diagnostics plus one unprefixed line remain separate.
The skip applies because the process already has permission and uses no hardware.

XERJ final refresh/freshness/query exit0:479 files,441/441 classified code;
preview layout/dimensions hits are source-confirmed. Bounded frozen review's P3
is closed in a new snapshot with no further actionable findings. Root validates
both report inventories (33 and24 artifact/hash checks) and five final frozen/live
source hashes. Worker runtime gates remain skipped; observed route/usage unknown.
The original review's focused breakdown typo is corrected by the delta report;
actual original focused run is5 preview +6 history,11 total. Private evidence
and machine state remain ignored.
Hosted CI for preceding head8c4540 succeeds in
[PR run38199811480](https://github.com/Mesteriis/makosh-native/actions/runs/38199811480)
and [push run38199808807](https://github.com/Mesteriis/makosh-native/actions/runs/38199808807).
Those results do not establish CI for this new patch. Full migration remains active.

## Previous stage: reference caption/comment placeholder

Upload text now follows locked PreviewSenderController preview-entry rules:
one caption-capable row, one Media group up to10 items or one Archive ZIP uses
Caption; multiple entries and single WebP File use Comment. The visible hint,
counter and native AX label update without replacing the editor. Send projection,
storage policy, schemas and dependency pins are unchanged. Mixed grouped Media
uses reference entry count; its existing list renderer still differs from the
reference collage. Premium/classifier/special-media/pixel parity remains open.

Actual isolated native File UI reproduces the old always-Caption label, then
shows Comment after the fix. Media grouping, separate items, regrouping, File
and Archive update the label while retaining a bold emoji and UTF16 selection.
An exact owned-process restart restores the same ZIP, text, selection and Caption
label. Reopened native readback passes1 XCTest and45 Python tests:prepared ZIP,
exact rich input/selection, five local encrypted records, no receipt/pending or
remote ZIP object. The owned runtime is stopped and temporary QA source removed.
No personal Account, Telegram server send or hardware is used.

Focused GREEN25 XCTest and45 Python tests. Initial fixture mistakes are retained
in raw logs:1 failure from a photo lacking a File resource, then11 assertions
from confusing editor context with preparation ID; corrected fixtures pass.
Required database startup, full tests, app build and strict deep signature exit0.
Full suite: **1,331 XCTest (1,252 Telegram +79 core),1 microphone-authorization
precondition skip,0 failures;45 Python tests**. Cached full/build compilation
has no warnings;647 SQL-prefixed t19 diagnostics plus one bare line remain separate.
The skip uses no hardware and applies because the process already has permission.

XERJ refresh/freshness/query exit0:477 files,439/439 classified code; new text
purpose hits are source-confirmed. Bounded frozen review reports no actionable
findings. Root checks16 recorded exits/argv,70 artifacts and six frozen/live source
hashes; five worker runtime checks are skipped, observed route/usage unknown.
Hosted CI remains a separate gate. Full migration remains active; continue the
remaining caption/classifier/visual/gesture work before later services.

## Previous stage: Archive cancellation/rebind regression coverage

Two native controller tests cover eight cancellation/rebind cases: both S3
policies, with install dispatch held before commit or success ACK held afterward.
They preserve the original cancellation/latest rich input and the other chat's
pointer, caption and staged bytes, without recapture. OFF ZIPs stay local after
enable. Production behavior, schemas, UI and dependency pins are unchanged.

Initial focused run passes2 XCTest and45 Python tests. Temporarily omitting the
cancellation/latest-input saves produces2 tests/16 expected failures; source is
restored byte for byte. Review identifies a missing byte-read assertion; the
added literal read detects wrong-current-stage cleanup with4 thrown file-read
failures (XCTest classifies these as unexpected). Production is restored again.
The first two full runs each pass **1,327 XCTest (1,248 Telegram +79 core),
1 microphone-authorization precondition skip,0 failures;45 Python tests**.
Their cached compilation has no warnings;647 SQL-prefixed t19 diagnostics plus
one bare t19 line remain separate. Initial test compilation repeats three
pre-existing compiler diagnostics (six warning lines).

Prior-head hosted CI38197667876 succeeds;38197670482 fails at ArchiveEdit's
retry/send assertions. Its global next-save ACK fault can hit the previous mode's
queued caption save. A real preceding caption save deterministically reproduces
1 test/1 expected failure. The fault now matches preparation ID and exact reordered
item IDs. Focused GREEN7 XCTest/0 failures and45 Python tests preserves durable
cache invalidation, blocked send, explicit retry and rebuilt one-ZIP acceptance.
Final integration full run also exits0:1,327 XCTest (1,248 Telegram +79 core),
1 skipped,0 failures;45 Python tests. No compiler warnings;647 SQL-prefixed t19
diagnostics plus one bare t19 line remain separate. Hosted CI for the next head
is a separate gate.

Required development database startup, app build and strict deep signature exit0.
Actual isolated native UI shows ZIP cancellation, chat switch/return and restart
without reopening the ZIP; another chat's draft survives restart. Native reopened
readback passes1 XCTest/0 failures and45 Python tests:cancelled, exact caption/ZIP
ID, five encrypted local records, no S3 receipt/pending and no remote ZIP object.
The ZIP remains authenticated/readable locally. Temporary QA source is removed;
the exact owned runtime is stopped. Held callbacks are verified separately by
native integration tests. No personal Account, Telegram server send or hardware.

XERJ refresh/freshness exit0:476 files,438/438 classified code; controller tests
and the ACK fixture query are source-confirmed. Frozen read-only review closes
its byte-read coverage finding; final ACK-delta review reports no new actionable
findings. Root validates all three recorded reports/artifact inventories and the
final seven frozen copies against live source. Worker runtime checks remain
skipped and observed execution/usage unknown. Legacy unreserved
handoff, remaining caption/classifier/visual/gesture parity and later services
remain open. Full migration remains active.

## Previous stage: reserving ZIP identities before capture

New ordinary Archive mode attempts reserve exact ZIP/storage/candidate IDs and
raw member names/size/digest in encrypted Postbox before capture. Reopened explicit
retry resolves and authenticates the same immutable object even when candidate
retention never committed. Native retention/install require the reservation for
these attempts. Changing writes invalidate it atomically; old UUID restoration
cannot revive it. OFF still forbids all new S3 copies, including preparation and
pending recovery. Local captures never promote after enable. Legacy unreserved
explicit descriptors retain their earlier handoff limitation. Pointer schemas,
UI and dependency pins are unchanged.

Compiled initial RED1 test/6 expected failures demonstrates duplicate ZIPs after
reopen under ON/OFF. Candidate-guard RED1 test/2 expected failures reproduces
original-UUID restoration; an initial fixture compilation error is retained.
Initial GREEN2 tests passes, with three pre-existing compiler diagnostics (six
warning lines). Removing only the install-side guard compiles RED1 test/2
expected failures; guard restored afterward. Expanded GREEN18 XCTest (5 Telegram
+13 core)/0 failures and45 Python tests covers reservation ACK loss, invalid
predecessors and pending/local recovery. Its first fixture compile failure is
retained. The first full suite exits0:1,324 XCTest (1,246 Telegram +78 core),
1 microphone-precondition skip,0 failures;45 Python tests. No compiler warnings;
631 upstream SQL-prefixed t19 diagnostics remain separate. A further compiled
RED1 test/1 expected failure exposes normalized attachment-ID acceptance in
local reserved lookup. Exact-byte GREEN19 XCTest (5 Telegram +14 core)/0 failures and45 Python tests
passes. Final required full suite exits0: **1,325 XCTest (1,246 Telegram +79 core),
1 skipped,0 failures;45 Python tests**. Its fresh test compilation repeats the
same three pre-existing diagnostics (six warning lines);631 SQL-prefixed t19
lines plus one bare error line remain separate. Required build and strict deep
signature exit0. Actual isolated common-window AX/screenshots verify Media→Archive,
changed caption, exact owned-process restart with the same ZIP ID, and explicit
synthetic GUI enqueue while the visible S3 flag is OFF. Reopened native readback
passes1 XCTest/0 failures and45 Python tests:one accepted ZIP, exact caption and
five local encrypted records, without S3 receipt/pending files. QA payload matches
the build except signing-related LINKEDIT virtual size. Temporary QA source is
removed. This is ordinary-path compatibility evidence; the pre-retention fault is
verified separately in the real native integration tests. No personal Account,
server send or hardware access.

Fresh reference/source research corrects the previous batch-cover gap:
PreviewSenderController:315–378 restricts the action to one Media item. This
slice adds no per-item UI. Final project refresh/freshness and locked reference
checks exit0:475 files,437/437 classified code. Intent matching and cover queries
are source-confirmed. Final source freeze passes502 checks after QA removal:
458 source files and22 frozen review copies. Bounded read-only review reports no
actionable findings; all22 copied hashes match before/after. Root consistency verification passes900 checks over the
common report and148 artifacts, including35 recorded worker checks; three worker
runtime categories and three root gates remain SKIP in the worker report.
Observed provider/model/internal execution and usage remain unknown. Root owns
runtime evidence, with no quorum or sandbox attestation. An initial UI artifact
verifier incorrectly assumes PNG while native CUA returns JPEG; extension correction
preserves identical image bytes and the corrected evidence verifier exits0.
At that stage, Archive-specific held-generation cancel/rebind evidence remained
open; the current stage above adds it. Legacy unreserved handoff, remaining
caption/classifier/visual/gesture parity and later services remain open.

## Previous stage: editing with an inactive Archive cache

Existing File/Media reorder/remove actions now work after leaving Archive. Changed
ordered members atomically drop only the ZIP descriptor back to schema15; the old
immutable archive stays retained. Selecting Archive again builds one new ZIP from
the edited durable originals, without recapturing member files. Same-member
grouping and canonical video-cover replacement retain the ZIP because its raw
bytes are unchanged. Active Archive remains one noneditable ZIP row, confirmed
against PreviewSenderController:867–872 and1590–1631. Controller authenticates the
resulting bundle and releases its old ZIP export only after durable confirmation.
Lost pointer ACK blocks send until an idempotent retry confirms the new state.

Initial session RED compiles3 tests/4 failures,1 unexpected from a mixed-media
fixture that refuses before the changed behavior. Corrected video MIME/second
photo fixture gives compiled RED3 tests/4 expected failures,0 unexpected.
Session GREEN3 XCTest/0 failures and45 Python tests. Controller RED2 tests/2
expected failures,0 unexpected; GREEN5 XCTest/0 failures and45 Python tests.
Expanded GREEN passes155 XCTest/0 failures and45 Python tests, including lost
native pointer ACK/retry, active-Archive refusal, retained cover/grouping cache,
member invalidation/rebuild and S3 OFF/no promotion. Required full suite exits0:
**1,317 XCTest (1,241 Telegram +76 core),1 skipped,0 failures;45 Python tests**.
No compiler warnings;613 upstream SQL-prefixed t19 lines plus one bare t19
line remain separate from XCTest results. The skip is the microphone-authorization
precondition test. Required build and strict deep
signature exit0. Actual isolated common-window AX/screenshots show Media grouping
keeps the old ZIP, then File reorder/remove and changed-caption restart preserve
third.jpg/first.jpg. Selecting Archive creates a new ZIP ID. Explicit synthetic
GUI enqueue closes the modal with S3 OFF. Reopened Postbox readback passes1
XCTest/0 failures and45 Python tests:one accepted ID, exact ordered ZIP members
and caption, eight encrypted local records without S3 receipts/pending. QA payload
matches the final build except signing-related LINKEDIT virtual size. Temporary
QA source is removed. No Account/server send or hardware access.

Initial reference query uses the wrong prefix and returns no matches; the
corrected locked query retrieves SenderController:39, source-confirmed with
PreviewSenderController workflows. Final project refresh exits0:473 files,
435/435 code. One premature freshness check reports STALE/exit1 while that
refresh is running; after its terminal0 the freshness check exits0. Final
updateStoredItems query is confirmed at Session:442. The original coverage miss
and failed freshness invocation remain separate. Initial freeze passes474
checks after QA. Replacement freeze keeps the same456-file source set and9
review copies, changing only reference-interface UI evidence/remaining gaps;
its474 checks also pass. Bounded source review reports no actionable findings
and releases source ownership. Original report/inventory are preserved; a
format-only V2 supplies the common contract fields. Root consistency verification
passes3,989 checks over268 artifacts and65 recorded invocations, including33 root
commands/four nonzero outcomes before the review cutoff. Five worker checks are
unrun; wrong-prefix coverage SKIP is separate. Two later root-verifier attempts
fail on format assumptions (extra snapshot fields, root-only execution ledger);
both are retained before the corrected verifier exits0. These are verification-
script failures, not product runtime failures. Observed provider/model/usage and
internal execution remain unknown; no quorum, sandbox or approval is inferred.
Publication audit checks478 publishable files and the proposed PR body against
five selected credential fields:zero matches. Private evidence/configuration
stays ignored. No schema version, dependency or copied reference code is added.

Cover-cache retention has Session-level regression evidence. Reference source
subsequently confirmed that cover actions are restricted to one Media item;
missing batch cover controls are not a migration gap. At this stage process loss
before capture-receipt commit, Archive-specific held-generation cancel/rebind runtime evidence,
exhaustive caption/classifier/visual parity and later services remain open.
Full migration remains active.

## Previous stage: Archive picker and mode switching

The existing upload actions menu now offers Archive for two or more reference-
caption preparations, alongside Media and File, following TelegramSwift's
PreviewSenderController:281–293. Session builds one ZIP from authenticated durable
originals rather than picker paths, retains its candidate and installs it through
the existing native admission/CAS. A failed installation can reuse retained
metadata. File/Media/Archive switches keep the same ZIP cache and raw caption.
Active Archive normalizes grouping, spoiler and caption-above to false. Ordinary
submission uses the selected canonical representation even with an inactive ZIP
cache; the shared provider authenticates the whole bundle before enqueue.
No new member captures or mode-switch file records; OFF remains local-only and
does not promote after enable. Existing standalone prepare/array-only boundaries
still refuse an Archive without its authenticated complete bundle.

Initial test compilation failed on an ambiguous tuple type; corrected before
behavioral RED. Compiled RED2 tests/2 unexpected incompatibleData failures expose
the missing native mode transition. Controller RED1 test/3 expected failures,
0 unexpected exposes the refused picker action. Initial GREEN3 tests and45 Python
tests pass. Expanded native message readback initially exits with signal5 at a
direct actor-isolated test transaction; a nonisolated helper matching existing
native tests replaces it. Final focused GREEN150 XCTest/0 failures and45 Python
tests passes, including exact native ZIP/File/Image representation and restored
inactive cache. No compiler warnings;248 upstream t19 diagnostics remain separate.
Required full suite exits0: **1,312 XCTest (1,236 Telegram +76 core),1 skipped,
0 failures;45 Python tests**. No compiler warnings;602 upstream t19 diagnostics
remain separate. The skip is the microphone-authorization precondition test.
Required final build and strict deep signature exit0. Actual common-window
AX/screenshots show ordinary Media→Archive→File, edited caption, File recovery
after exact owned-process restart, then Media→Archive with the same ZIP ID.
Explicit synthetic GUI enqueue closes the modal while S3 is OFF. Reopened
native readback passes1 XCTest/0 failures and45 Python tests:one accepted ZIP ID,
two canonical items, exact caption and five encrypted local records, without
S3 receipt/pending files. QA executable matches the final build except signing-
related LINKEDIT virtual size. No Account/server send or hardware access.
An intermediate XERJ refresh refuses freshness because source changed while it
ran; original exit1 retained. The next refresh exits0 on the unchanged source.
The first setPresentation query has no match; corrected updatePresentation and
reference ArchiverSenderContainer are source-confirmed. Final project refresh/
check and locked reference check exit0:472 files,434/434 code. Final archiveCandidate
query is confirmed at Session:375. Temporary QA source is removed. The original
455-file/13-copy freeze passes481 checks after QA; a replacement freeze retains
the same source set and records only the reference-interface UI evidence update.
Final replacement verification also passes481 checks. Bounded source review
reports no actionable findings. Independent root consistency verification passes
1,388 checks over267 artifacts and65 original executions, including38 root
commands. The five nonzero root invocations above, one harmless manifest-guarded
worker filename lookup failure, seven unrun worker checks and the initial query
coverage skip remain distinct. Observed worker provider/model/usage/internal
execution remain unknown; no quorum or sandbox attestation is inferred. Source
read ownership is released. No Archive-specific held-generation cancel/rebind
runtime test was added; existing generic detached-mode/native admission coverage
and source guards do not replace that missing scenario.

Publication audit checks477 publishable files and the proposed PR body against
five selected credential fields:zero matches. Private QA, credentials, runtime
configuration, indexes and frozen evidence remain ignored.

Item reorder/removal/grouping/cover editing with a retained ZIP cache remains
disabled pending explicit cache invalidation/rebuild. Process loss before native
capture-receipt commit, exhaustive caption/classifier/visual parity and sequential
later services remain open. No personal Account/server sends or hardware access.
Full migration active.

## Previous stage: captured ZIP candidate retention

After authenticating the already captured bundle, Session retains its exact
schema16 candidate in a separate encrypted Postbox preference before installing
the active pointer. The receipt binds the predecessor UUID and SHA256 of its
exact encoded state. A fresh Session can read the retained descriptor/revision
after reopen and explicitly retry without the original caller's descriptor.
Failed native installation or lost retention ACK preserves the same candidate;
the ordinary schema15 pointer stays unchanged. Replay exports/authenticates the
immutable resources without capturing or creating S3 objects. OFF records remain
local after enable. Exact no-op writes preserve the receipt; changing writes,
including cancellation, successful install and original-UUID A→B→A, remove it.
Wrong predecessor, conflicting candidate, cancelled admission, corruption and
foreign scope fail closed. Schemas1–16 and existing UI remain unchanged.

Compiled RED1 test/2 expected failures,0 unexpected reproduces candidate loss
after encrypted reopen under both storage policies. Initial GREEN11 XCTest and
45 Python tests pass. Expanded focused suite passes; predecessor-digest mutation
then compiles RED1 test/1 expected failure,0 unexpected. Exact production guard
restored afterward. Final focused GREEN94 XCTest/0 failures and45 Python tests.
Required full suite exits0: **1,308 XCTest (1,232 Telegram +76 core),1 skipped,
0 failures;45 Python tests**. No compiler warnings;587 upstream t19 diagnostics
remain separate. The skip is the microphone-authorization precondition test.
Required build and strict deep signature exit0. Actual final-binary compatibility
QA shows one277-byte ZIP and edited caption after process restart in the existing
common window. Explicit synthetic GUI enqueue closes the modal with S3 OFF.
Reopened native readback passes1 XCTest/0 failures and45 Python tests:one accepted
ID, two canonical resources plus ZIP, three encrypted local records/no S3 receipts.
QA payload matches the build except signing-related LINKEDIT virtual size.
This is existing UI compatibility evidence; retained-capture retry is internal.

Fresh final project/reference XERJ checks exit0; corrected saveArchive/native
capture-read and ArchiverSenderContainer queries are source-confirmed. The first
storeArchive query has no matches and remains a separate coverage skip. The
454-file/11-copy freeze matches after gates and temporary QA removal:476 integrity
checks,0 mismatches. Bounded source review reports no actionable findings. Root
contract verification passes1,124 integrity checks over186 artifacts and47
recorded executions, including28 original root commands and the two compiled
RED exits retained above. Seven worker checks remain unrun; root owns the runtime
gates. The storeArchive coverage skip remains separate. The initial root verifier
expected the previous report schema and failed with KeyError; a schema-matched
verifier validates the pinned report/inventory and unchanged sources. Original
failure retained. Observed worker provider/model/usage/internal execution remain
unknown; no quorum.

Capture, receipt retention and active pointer installation are separate
transactions. This protects a committed retained receipt before pointer failure;
a process loss before receipt commit still needs the caller's descriptor and is
not claimed recovered. Immutable files are never purged on these failures.
Archive generation/picker/mode switching and that earlier handoff remain open.
No Account/server sends or hardware access. Full migration active.

## Previous stage: fresh-Session Archive install acknowledgement

Guarded installation commits an account/chat-scoped native receipt in the same
transaction as the schema16 pointer. It binds the predecessor UUID and SHA256
of the exact encoded candidate. A fresh Session authenticates the retained
bundle and confirms the unchanged committed installation after encrypted
Postbox reopen. Replay writes no pointer/file/S3 object. Wrong predecessor,
missing/corrupt/foreign receipt, later caption revision including A→B→A and
started submission refuse. Schemas1–16 stay unchanged. Older16 without receipt
still restores/sends, but this install-replay route fails closed.

Compiled behavioral RED3 tests/4 expected failures,0 unexpected; initial
focused GREEN35 XCTest/0 failures and45 Python tests. Additional receipt-guard
mutation compiles RED2 tests/5 expected failures,0 unexpected, covering missing,
corrupt/foreign receipts and later caption revisions. Exact production guard
restored afterward. Final focused GREEN37 XCTest/0 failures and45 Python tests.
Initial full suite exits0:1,303 XCTest (1,227 Telegram +76 core),1 skipped,
0 failures and45 Python tests; no compiler warnings,561 upstream t19 diagnostics.
This predates the review fix. Bounded review identifies stale receipt reuse when
ordinary writes restore the original candidate UUID after an intervening edit.
Dedicated native regression compiles RED1 test/1 expected failure,0 unexpected.
Every non-idempotent ordinary pointer write now invalidates the old receipt;
exact no-ops preserve it, and guarded install sets its new receipt atomically.
Final focused GREEN81 XCTest/0 failures and45 Python tests, including ordinary
Postbox/Session regressions. Required final full/build exit0: **1,304 XCTest
(1,228 Telegram +76 core),1 skipped,0 failures;45 Python tests**. No compiler
warnings;563 upstream t19 diagnostics remain separate. Microphone authorization
is the skip. Build was dispatched before full-test completion and waited on
SwiftPM's lock; root suspended that exact owned waiting subtree and resumed it
only after the full-test terminal PASS. Strict deep signature exits0.

Actual final-binary compatibility QA in a fresh isolated common window shows
one restored ZIP, Archive title/mode and edited caption after process restart.
Explicit synthetic enqueue closes the modal with S3 OFF visible. Reopened native
Postbox readback passes1 XCTest/0 failures and45 Python tests:one accepted ID,
two canonical resources plus ZIP, exact caption and three local encrypted records
without S3 receipts. QA executable matches the build except signing-related
LINKEDIT virtual size. No Account/server send or hardware access. This checks
existing recovery/send compatibility; install retry remains an internal operation.

Fresh final project/reference XERJ checks exit0; own install/receipt and reference
ArchiverSenderContainer queries are source-confirmed. Final replacement freeze
matches after gates and temporary QA removal:453 files/9 review copies,
471 integrity checks,0 mismatches. Bounded review's original revision-reuse
finding is reproduced/fixed above; delta source review reports no additional
actionable findings. Independent root contract verification passes:1,007
integrity checks,223 artifacts,52 original executions and3 nonzero compiled
RED runs retained above. Seven worker runtime/tool checks remain unrun; root
owns the passing runtime gates. No query coverage skips in this slice.
Observed worker provider/model/usage/internal execution remain unknown; no quorum.

Capture-receipt retention before native commit and Archive picker/mode switching
remain open. No new UI actions or Account/server sends. Full migration active.

## Previous stage: controller/model whole-bundle ZIP recovery

The model restores a whole authenticated bundle. Controller admission binds
canonical items, ordered ZIP metadata and the current recovery epoch; active
Archive presents one ZIP and explicit send passes the whole bundle. Receipt
confirmation also binds exact encoded archive bytes, presentation and caption rules.
Changed confirmation retains all stages and retries only confirmation. Started
submissions remain uncertain without automatic resend. Cleanup/cancellation,
rebinding and deinit release canonical resources and ZIP; failed ZIP cleanup
retains ownership and blocks replacement. No new file records or S3 objects.

Compiled RED:6 tests,8 expected assertion failures,0 unexpected. Focused GREEN:
33 XCTest/0 failures and45 Python tests. Receipt-corruption RED:1 test,5 expected
assertion failures,0 unexpected; focused GREEN55 XCTest/0 failures and45 Python
tests. Initial required DB up/full suite exit0: **1,298 XCTest (1,222 Telegram +76 core),
1 skipped,0 failures;45 Python tests**. Three existing test compiler warnings
and540 upstream t19 diagnostics remain separate; microphone authorization is
the single skip. Initial required build exits0; the updated build includes the
two UI label changes. These gates precede the final Unicode confirmation fix.

Root review identifies Swift canonical String equality in the new archive ACK
comparison. The first NFC/NFD regression also trips a fixture assertion because
the source name already has decomposed bytes:1 test/6 failures. Corrected toggle
fixture gives compiled RED1/5 expected controller failures,0 unexpected. Sorted
JSON bytes now bind the exact descriptor, including Unicode spellings. Focused
GREEN55 XCTest/0 failures and45 Python tests. Final required full/build gates
exit0: **1,298 XCTest (1,222 Telegram +76 core),1 skipped,0 failures;45 Python
tests**. No compiler warnings in this final run;541 upstream t19 diagnostics
remain separate from passing assertions. Microphone authorization is the skip.

Actual isolated common-window QA restores one ZIP with its caption. Native AX
RED exposed a two-item/Media label; reference PreviewSenderController:480–488
confirms a separate Archive title. Final build/AX/screenshot GREEN shows
“Отправить архив”, “Архив”, one ZIP and the retained caption. Strict deep
signatures pass; QA executable matches the built app apart from signing-related
LINKEDIT virtual size. This uses a fresh synthetic Postbox and isolated schema,
without Account/server sends or hardware access.
Edited caption and ZIP survive a process restart. Explicit isolated GUI enqueue
closes the modal; separate reopened Postbox readback confirms one accepted ID,
two canonical resources, ZIP and edited caption, with exactly three local records
and no S3 receipts. The first readback helper fails before reading Postbox because
new boolean payload metadata invalidates its string-only dictionary; corrected
private helper passes1 XCTest/0 failures and45 Python tests. Original FAIL retained.

Fresh isolated QA repeated on the final Unicode-fix binary: strict signature
and normalized executable payload checks pass, one ZIP and edited caption survive
restart, explicit GUI enqueue closes the modal with S3 OFF. Reopened native
Postbox readback passes1 XCTest/0 failures and45 Python tests with one accepted
ID, two canonical resources plus ZIP, exact edited caption and three local
records without S3 receipts. No Account/server sends or hardware access.

Final project/reference XERJ freshness checks exit0. Focused own query retrieves
the controller's retained archive field and guards, confirmed against source.
Earlier broad queries retain separate coverage skips; the focused reference
query retrieves the Archive title. The453-file/8-copy freeze matches after
final gates and temporary QA removal:469 integrity checks,0 mismatches.

Bounded read-only source review reports no additional actionable findings.
Root independently verifies report/inventory hashes, current source/copies and
all84 original executions:1,268 integrity checks,298 artifacts,6 nonzero runs,
7 worker runtime/tool skips and2 query coverage skips. The nonzero runs retain
the five root RED/helper failures above and one worker guessed-path inspection
failure. Root's initial verifier rejects extra contract keys; the adapted private
verifier checks their exact values and passes, preserving that original failure.
Worker provider/model/usage/internal execution remain unknown; no quorum.
Runtime gates belong to root. Inherited stale model cleanup still attempts all
bundle resources with `try?`; cleanup-error reporting/retention there is not
claimed solved by this slice.

Capture-receipt retention/fresh Session lost-ACK install recovery and picker
Archive generation/mode switching remain open. Full migration stays active.

## Previous stage: whole-bundle ZIP submission providers

The Account and isolated native providers accept a recovered bundle through a
dedicated overload. Shared submission authenticates canonical/original/cover
resources and the ordered descriptor-bound ZIP before copying exactly one ZIP
to MediaBox; copied bytes are digest-checked before native admission. The old
array route still refuses16. Legacy adapters fail closed for Archive. Stopping
before admission prevents insertion and leaves caller-owned stages intact.
Submission creates no file records or S3 objects under either policy.

Compiled shared-path RED:3 tests,9 expected assertion/expectation failures,
0 unexpected. Focused GREEN30 XCTest/0 failures and45 Python tests. Protocol
dispatch then compiles RED:1 test,5 expected assertion failures,0 unexpected;
explicit provider adoption passes34 focused XCTest/0 failures and45 Python
tests. Recompilation reports3 existing test warnings; upstream t19 diagnostics
remain separate. Final focused tests pass35 XCTest/0 failures and45 Python tests,
including a photo/original bundle and continued refusal of the legacy array route.
Required DB up and full test suite exit0: **1,291 XCTest (1,215 Telegram +76 core),
1 skipped,0 failures;45 Python tests**. No compile warnings;523 existing upstream
t19 diagnostics remain without test failures. The microphone-authorization skip
is separate. Required build and strict deep signature exit0; the453-file/9-copy
freeze matches after gates (471 integrity checks). Bounded source review reports
no actionable code findings. Root independently verifies its original contract,
current source/copies and raw commands:816 integrity checks,35 original recorded
invocations,2 nonzero compiled RED runs,4 unrun checks,1 query coverage skip and
148 artifacts. Requested worker route is inherited; observed provider/model/
usage/internal execution remain unknown, with no quorum. Runtime gates belong
to root. A docs-only clarification now says submission creates no file records
or S3 objects; read-only ArchiveFileCapture hashing is deliberately still used.
Docs delta review reports no findings. Root verifies its final contract/current
source/copies:569 integrity checks,9 original recorded invocations,0 nonzero,
4 unrun checks and44 artifacts. Final refresh/check/query exit0 and the final
453-file/9-copy freeze matches; production/test hashes are unchanged, so runtime
gates are retained without an unnecessary rerun.

Project v6 refresh/check exit0:470 files,432/432 classified code. Fresh own query
retrieves Submission.validateArchive and is source-confirmed. Reference freshness
check passes; corrected reference query retrieves one ArchiverSenderContainer,
confirmed against PreviewSenderController/SenderController. The initial wrong
prefix query exited0 without matches and remains a coverage skip. Source freeze
contains453 files and9 review copies.

No visible screen changes or Account/server sends. Controller/model bundle
adoption, capture-receipt retention/fresh Session lost-ACK recovery and the
existing-window Archive UI remain open. Full migration stays active.

## Previous stage: one-ZIP native enqueue receipt

Active schema16 Archive now produces one plain ZIP message with one normalized
caption and one complete native receipt. Descriptor ID/name/size/digest are
bound separately from the N retained canonical resources. Admission compares
the entire frozen pointer; native insertion and acceptedBatch acknowledgement
share a transaction. Canonical records and raw editor/selection remain retained.
Lost ACK replay refuses another insertion. No archive capture or S3 write occurs.

Compiled RED:3 tests,4 expected assertion failures,0 unexpected, after a separate
test-only compile failure (async autoclosure and wrong reference property).
Focused GREEN19 XCTest,0 failures;45 Python tests. Initial full suite passes
1,286 XCTest,1 skipped,0 failures and45 Python tests. This precedes the review fix.

Bounded review found an Archive-only gap in queued media-TTL verification. A real
native corruption regression compiles RED:1 test,1 expected failure,0 unexpected.
The Archive receipt now vetoes Autoclear/view-once attributes while allowing
ordinary chat Autoremove. Focused regression/voice/boundary/receipt GREEN:
39 XCTest,0 failures;45 Python tests.

Required `scripts/dev-db.sh up`, final `scripts/test.sh` and
`scripts/build-app.sh` exit0: **1,287 XCTest (1,211 Telegram +76 core),1 skipped,
0 failures;45 Python tests**. Final strict deep signature passes. No compile
warnings;495 existing upstream t19 diagnostics remain without test failures.
The microphone-authorization skip is separate. The453-file/7-copy final freeze
matches after full tests and build.

Final source freeze has453 source/test/dependency/script/license/reference-lock
files and7 review copies. Project v6 refresh/check exit0:470 files,432/432
classified code. A broad final query retrieved unrelated archive helpers; the
focused query retrieves the new veto and is source-confirmed. Reference
PreviewSender creates one ArchiverSenderContainer and SenderController fixes
its isOneTime=false; both are source-confirmed. Unchanged reference check passes.
Both hosted0ebd369 CI runs now pass; new-head CI remains separate.

The original bounded review's P2 is independently reproduced and fixed above.
Delta source review reports no new actionable findings. Root verifies the
original contract/copies/artifacts and all34 original invocations, including
3 nonzero executions and4 explicit skips:319 integrity checks,146 artifacts.
The first grouped summary omitted nested original attempts; the corrected
original-execution verification retains both compiled/setup RED runs separately.
The original current-source verification predates the intentional TTL fix;
root checks frozen copies and raw historical checks without claiming it as
current verification. Final delta contract verification passes637 checks:
17 original invocations,1 nonzero compiled TTL RED,4 unrun checks and75 artifact
files. The unrelated broad query retains process exit0 and a separate coverage
SKIP. The parent's initial verifier rejected that explicit distinction; the
corrected verification preserves its original failure and the coverage skip.
Requested worker route is inherited; observed provider/model/usage/internal
execution remain unknown, with no quorum. Runtime gates belong to root.

No visible screen changes or Account/server sends. Controller/model/provider
bundle adoption, capture-receipt retention/fresh Session lost-ACK recovery and
the existing-window Archive UI remain open. Full migration stays active.

## Previous stage: authenticated Archive pointer installation

The dedicated native Postbox operation binds cancellation/scope/revision to the
same synchronous compare/set admission. It preserves canonical metadata by
reconstructing from the authoritative pointer and comparing encoded JSON bytes.
Exact retained candidates can replay only while admitted. Cancellation before a
queued transaction refuses it; cancellation after admission cannot undo it.
The caller owns invalidating each generation token on context changes.

Root compiled RED:5 tests,10 assertion failures,0 unexpected. Two prior test
compile errors and an initial behavioral run with one thrown missing-feature
error remain separate. Focused native/Postbox/presentation recovery GREEN:
62 XCTest,0 failures;45 Python tests. Three existing recompiled-test warnings
and upstream t19 diagnostics are retained. A terminal-state test also uses the
exact current revision and passes in the integration rerun below.

Session tests compiled RED:8 tests,10 assertion failures,0 unexpected. Minimal
installation authenticates an already durable ZIP plus all canonical/raw files,
discards temporary exports, and changes only an exact prepared schema15 pointer
to16. It retains raw rich input/selection, original draft/reply/title and canonical
records without capture; Archive clears grouping, placement and spoiler.
Focused install/native/bundle/session/source-facts GREEN:28 XCTest,0 failures;
45 Python tests, no compile warnings. Both policies, encrypted reopen after
source deletion, forged records/members, stale CAS, suspended-read cancellation
and cancellation after committed success are covered. OFF verifies no new
objects/events, no recapture and no promotion after enable.

Final `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**1,283 XCTest (1,207 Telegram +76 core),1 skipped,0 failures;45 Python tests**.
Warm gates emit no compile warnings;483 existing upstream t19 diagnostics remain
without test failures. Strict deep signature, system libz linkage and bundled
notice equality pass. All452 source/test/dependency/script/license/reference-lock
files and11 review copies remain frozen through gates. Project v6 refresh/check
exit0:469 files,431/431 classified code. Unchanged reference579cebbf and engine
a24bbe45 checks pass; active own/reference results are source-confirmed.

Bounded final source review reports no actionable findings. Root verifies the
implementation delivery independently:
307 integrity checks,32 original worker commands plus2 close/reconcile commands,
4 nonzero and4 explicit skips,141 artifact files. An initial parent verification
used the wrong artifact-index
filename and failed; the corrected verification passes without overwriting that
failure or either original/final index. Requested route is inherited; observed
provider/model/usage/internal transfer remain unknown, with no quorum.
Final review verification passes884 integrity checks:37 original read-only worker
commands plus13 delegated original RED/GREEN/XERJ invocations,6 original nonzero,
2 explicit skips and214 artifact files. The private collector's wrong-log-path
failure remains separate from its corrected stdout/stderr collection. Runtime
gates belong to root; review does not claim a separate build/test/UI rerun.
Both hosted12198194 CI runs now pass; new-head hosted verification is separate.

A timeout is not proof of non-commit; only exact retained candidates can replay
at the native repository. There is no visible screen change in this slice;
actual Archive UI/native send validation remains deferred until connected.
Capture-receipt retention/lost ACK, controller/model adoption, native ZIP sending
and actual existing-window Archive UI remain open. Full migration stays active.

## Previous stage: Archive schema and complete recovery foundation

Strict schema16 retains ordered canonical items plus a versioned ZIP descriptor,
stable item/name bindings and an outgoing scoped record. It requires complete raw
source facts and preserves prepared photo/GIF pairs. Schemas1–15 reject Archive
fields, including null. Active Archive has one accepted-message count and forbids
grouping, caption-above and spoiler; inactive File/Media may retain its cache.

Policy-aware ZIP save and whole-bundle restore authenticate the outer digest on
the same held inode used for member inspection. S3 OFF forbids all new copies,
including preparation; encrypted local records never promote after enable.
Whole-bundle restore owns canonical/original/cover/ZIP stages and cleans exports
on failure. Array-only restoration refuses16. Generic prepare/mode/plan paths
refuse Archive before copies or state changes. Ordinary preparations remain15;
dedicated install/generation CAS, controller/model adoption, one native ZIP
resource/receipt and actual existing-window Archive UI are still open.

Compiled behavioral RED precedes each behavior change. Focused whole-bundle,
storage, digest and boundary run:31 XCTest,0 failures;45 Python tests. Real
PostgreSQL/S3 plus encrypted Postbox reopen covers both policies, deleted sources,
tampered member names, complete cleanup and no recapture/promotion. Initial test
setup had a MainActor transaction closure SIGTRAP; its original raw run is kept.
A test-only nonisolated transaction helper fixes that setup; repeated compiled
RED then reports4 expected failures,0 unexpected. Production transaction behavior
is unchanged. Prior hosted064cd13 CI exposed an ambiguous test buffer overload;
the closure now explicitly uses UnsafeMutableRawBufferPointer. New hosted CI is
not yet verified.

Root independently verifies both worker deliveries:592 integrity checks,
75 original commands,8 nonzero and6 explicitly unrun checks. Requested route is
inherited; observed provider/model/usage/internal transfer remain unknown, with
no quorum.

Final `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**1,270 XCTest (1,194 Telegram +76 core),1 skipped,0 failures;45 Python tests**.
Warm gates emit no compile warnings;451 upstream t19 diagnostics remain without
test failures. Strict deep signature, system libz linkage and bundled notice
equality pass. All449 source/test/dependency/script/license/reference-lock files
and22 review copies remain frozen through gates. Project v6 refresh/check exit0:
466 files,428/428 classified code. Unchanged reference579cebbf/engine a24bbe45
checks pass; active own/reference results are source-confirmed. An early check
while refresh still ran reported STALE; an initial wrong-prefix query returned
no match. Both originals remain separate from corrected evidence. Final bounded
source review reports no actionable findings; root also reviews the worker's
model changes. The worker's self-authored model portion is not an independent
review or quorum. Root verifies the final report's source/copy/artifact hashes,
all56 original worker commands and8 delegated XERJ commands. Launcher127, two
read-path2 errors, early STALE1 and wrong-prefix no-match0 remain classified
separately. Runtime gates belong to root. Deterministic mid-export/mid-inflate
cancellation and concurrent mutation schedules remain unrun. Full Telegram and
later services remain the active goal.

## Previous stage: internal ZIP codec

This Archive slice adds independently authored ZIP32 writer/inspection over
the SDK's system zlib module. Ordered owned raw stages become one private
`Telegram Archive.zip`; hidden/empty sources remain present. Case/NFC basename
collisions receive stable suffixes while later original names stay reserved.
Nonempty members use best raw DEFLATE, empty members Store; UTF8 names, CRC32,
patched local headers, exact central/EOCD and1980-01-01 timestamp are explicit.
The inspector compares each decoded stream's count/SHA/CRC with both the manifest
and freshly read owned raw bytes, without extracting files. Source-name binding
uses exact UTF8 spelling. Cancellation and inode snapshots bracket the operation.

Review found that the raw-byte cap did not bound central-directory/name memory.
Compiled root RED reproduces missing metadata preflight before source IO; shared
product limits now enforce2–1024 sources,1500MiB raw bytes,1024 UTF8 source-name
bytes,1040 allocated-name bytes and1MiB central metadata. A separate compiled RED
reproduces canonical-equivalent source-name substitution before the byte binding
fix. Final review also found output/source identity disagreement. A compiled
RED2/5 precedes writer preflight alignment: output ID differs from every source
item/file ID, and source file IDs are nonzero. Final focused **31 XCTest,0
failures** covers these boundaries, real1024
sources, exact64KiB output sizes, multichunk incompressible input, independent
Python zipfile readback, literal raw-DEFLATE ZIP, tampering, cancellation and
changed-source cleanup. Original failed/stub runs remain recorded separately.

`scripts/dev-db.sh up`, final `scripts/test.sh`, `scripts/build-app.sh` exit0:
**1,236 XCTest (1,160 Telegram +76 core),1 skipped,0 failures;45 Python tests**.
All444 source/test/dependency/script/license/reference-lock files and14 review
copies remain frozen through final gates. Warm gates emit no compile warnings;
437 existing upstream t19 diagnostics remain without test failures. One
microphone-authorization test is skipped. Strict built signature, system libz
linkage and exact retained notice in the app bundle pass. The zlib SDK/runtime
1.2.12 notice is retained; no implementation is vendored or engine pin changed.

Final bounded review and its identity-fix delta have no remaining actionable
findings. Root verifies268 delivery/artifact/copy checks,40 original worker
commands (38 exit0,2 nonzero),6 explicitly unrun checks and the444-file/14-copy
freeze. Earlier research verification remains separate:429 integrity checks,
66 commands,4 nonzero,5 unrun. Failed root evidence setup, missing-path inspection
and nullable-check verifier setup remain recorded; corrected verification does
not turn those failures into PASS. Requested route is inherited; observed
provider/model/usage/internal transfer remain unknown, with no quorum.
Fresh active XERJ queries are source-confirmed: project v6 refresh/check exit0,
459 files,421/421 classified code; unchanged reference579cebbf and enginea24bbe45
checks pass. Both previous85cc hosted CI runs pass; new-head CI is separate.

No visible screen changes in this slice. Archive sending still requires strict
schema16, N-originals-plus-ZIP recovery, policy-aware install/generation CAS,
one native document/receipt and actual existing-window UI verification. The codec
has no storage/account calls; S3 OFF and no-promotion remain required at that
future integration boundary. Existing preparations continue to use schema15.
Full Telegram and subsequent services remain the active sequential goal.

## Previous stage: versioned reference caption projection

New ordinary picker preparations use strict schema15: the raw rich editor input,
selection and source facts remain durable; only the send plan normalizes text.
Schemas1–14 keep their previous projection/cardinality, including after reorder,
mode or cover changes. Explicit Voice/round retain schemas11–13 and reject any
raw nonempty caption before archive capture. Older binaries refuse15; preserve
pointers, encrypted resources, receipts and keys on rollback.

Source-confirmed reference helpers always trim attributed input, replace U+2028
and U+FFFC with newline, and shift/clip UTF16 entity ranges. Length preflight uses
the distinct String.trimmed behavior without U+FFFC substitution. Own code
implements those rules with the platform whitespace set; unsupported/customEmoji
provenance remains a veto. The conservative limit stays1024 UTF16. Whitespace-only
input produces no leading message. Single File WebP, including generic native
image/webp MIME, sends nonempty normalized text first, then empty media caption.
Plans, complete receipts and accepted-pointer counts share this projection.
Composer ACK callbacks retain the raw input. No GPLv2 helper/UI code was copied.

Compiled behavioral RED precedes changes; review found raw recorded-caption
validation after normalization and missed generic WebP MIME. Separate real
local/S3 regressions fail before their fixes. Final focused15/0 passes. One
test-only queue-directory assertion was moved before resume, which legitimately
creates an empty spool; its original two failures remain recorded. The previous
hosted e82 runs completed one PASS/one FAIL: the sole failure compared a captured
pointer revision before a redundant pending write. A deterministic extra write
reproduces it; the test now compares every encoded content field, excluding only
revision, and separately proves revision changed. Production CAS is unchanged.

`scripts/dev-db.sh up`, final `scripts/test.sh`, `scripts/build-app.sh` exit0:
**1,205 XCTest (1,129 Telegram +76 core),1 skipped,0 failures;45 Python tests**.
All438 executable/source/test/dependency/script/license/reference-lock files
remain frozen through final gates/UI. Warm gates emit no compile warnings;
437 existing upstream t19 teardown diagnostics remain without test failures.
The microphone-authorization skip is separate. Strict built/owned-QA signatures
and raw unsigned executable equality pass; dependency/license pins are unchanged.

Actual owned synthetic AX/screenshots verify the existing File sheet with two
ordered text files, raw padded caption and counter12, then whitespace counter0.
Native bold input, selection, padding and the same two item UUIDs restore after
source-folder rename/restart with S3 OFF; the restored screenshot is valid.
Explicit Send reaches only synthetic queue. Closing observation and Mail→Telegram
retain chat11/OFF and uncertainty without auto-resend. Modal Quit needed verified
owned SIGTERM; the initial emoji selectText action failed, then native select-all/
bold worked. All three own fixtures are restored and hash-checked. No personal
Account, network Telegram, hardware input or OS permission grant was used.

Root verifies1,213 artifact/source integrity checks,188 original worker commands
(175 exit0,13 nonzero), and the final438-file/14-copy snapshot. Both review
findings are fixed; final bounded recheck has no new actionable findings. Earlier
setup failures, the parent's wrong-copy-directory verification attempt and
unavailable historical raw evidence stay separate. Observed provider/model/usage
and internal transfer remain unknown; no quorum. Final active XERJ own/reference
queries are source-confirmed. Project v6 refresh/check exit0:453 files,416/416
classified code; unchanged reference579cebbf/engine a24bbe45 checks pass.

Remaining caption gaps: markdown/entity detection, resolved custom emoji, premium
limit and placeholder/comment UI parity. Typed GIF/music with original WebP MIME
may conservatively get extra leading text despite a native MIME override; no text
is dropped. Archive research is complete, implementation is next: retain ordered
N originals plus one ZIP, preserve basename collisions/hidden files, obey S3 OFF,
and use one native message/receipt. No ZIP dependency is adopted until its exact
license/provenance is reviewed. Full Telegram and subsequent services remain open;
physical routes, prompts, Account/server/recipient and minimum26 remain unproved.

## Historical ordered original sources (e82d4c9)

New ordinary picker preparations use strict schema14 source facts, independently
of canonical payload kind: item UUID, raw role/name/size/SHA256, original-name
selection MIME, logical image result and grouping result. Schema1–13 retain their
payload/validation meanings; source facts present in those schemas are refused.
Explicit Voice/round preparations keep schemas11–13. Older binaries refuse14;
preserve pointers, encrypted resources, receipts and keys on rollback.

The verified reference fold makes PNG→WebP File; WebP→PNG offers Media. Small or
rejected images contribute no option. File remains available independently of
Media, including the visible menu for a single WebP/document. Grouping follows
ordered source facts and canonical safety checks. Reorder/removal atomically
clears unavailable Media/grouping and never enables either automatically.
Native ordinary File images carry source logical ImageSize before FileName with
checked positive Int32 conversion. Mixed grouped Media captions the first actual
visual in each ten-item chunk, otherwise the last file.

The owned probe borrows a validated no-follow stage; cancellable held-fd hashing
and inode snapshots bracket bounded ImageIO/NSImage and independent music probes.
Limits are20MiB,256frames,8192axes,40M canvas/256M aggregate pixels. Small own MIME
aliases cover MOV/M4V/MKV/OGG/Opus/MP3/WebP/BIN; UTType is the remaining fallback.
BIN matches the final pinned application/x-macbinary row. Opus is a separate local
alias, since the reference table has no opus entry. This is not exhaustive MIME
or decoder parity. Deterministic in-flight mutation/cancellation,4GiB hashing
and interrupting an executing native probe remain unproved.

Every source fact is freshly verified before persistence, from authenticated raw
bytes on recovery and before native resource issuance. All captures and their
digests are frozen before the first archive save. Facts/resources/order survive
caption/cover/mode edits without recapture. Retry substitution retains conflict
semantics. Complete native receipt binds exact facts, attributes and every ID.
S3 OFF forbids every new copy, including outgoing preparation; local encrypted
records never promote on enable. PostgreSQL retains metadata, never payload bytes.
Immutable message versions/files survive remote deletion and preparation cleanup.

Compiled source/controller/schema/native RED gates preceded implementation;
final focused GREEN78/0 includes actual PostgreSQL/S3/encrypted Postbox/native
queue. Initial full gate1187/26 exposed old picker schema expectations, tiny
opaque GIF Media assumptions and retry error compatibility. New picker tests
now assert14; separate actual reopen/native queue cases retain legacy schema10
opaque32×16 Media under both storage policies. A structurally consistent forged
record/fact digest still reaches authenticated recovery refusal and all-stage
cleanup. Retry RED1/1 precedes its conflict fix. An initial legacy fixture write
omitted Postbox framing and failed2 cases; corrected repository fixture writes
pass. Original setup/crash/expectation failures remain separate from valid RED.

`scripts/dev-db.sh up`, final `scripts/test.sh`, `scripts/build-app.sh` exit0:
**1,189 XCTest cases (1,113 Telegram +76 core),1 skipped,0 failures;45 Python
regressions**. All436 source/test/dependency/script/license/reference-lock files
stay frozen through final gates/UI. Warm full gates emit no compile warnings;
414 existing upstream t19 teardown diagnostics remain without test failures.
The microphone-authorization skip is separate. Strict built/owned-QA signatures
and raw unsigned executable equality pass. Engine/dependency/license pins and
preparation recipes are unchanged; no outer GPLv2 UI/assets/credentials copied.

Actual isolated common-window AX/screenshots verify single-WebP File menu,
PNG→WebP File/disabled grouping, reverse reorder exposing Media without enabling
it, explicit Media and reverse normalization to File. Mixed smallPNG/JPEG/smallPNG
restores the same three UUIDs/order/Media/grouping/caption after source-folder
rename and owned restart with S3 OFF. Modal UI Quit left the process running;
only the verified owned synthetic process received SIGTERM. Restored-sheet
screenshot capture returned tiny black pixels, so recovery is AX proof, not a
valid restored screenshot. Explicit Send reaches only the synthetic queue;
close-observation and Mail→Telegram retain chat10/OFF and conservative uncertainty
without auto-resend. All seven own fixtures are restored and hash-checked.
No personal Account, Telegram network, hardware input or OS grant was used.

Root verifies309 leaf artifact hashes,72 original leaf attempts and25 bounded
integration-review attempts against frozen source copies. One UI menu finding is
reproduced then fixed; root owns subsequent retry/test/UI deltas and final gates.
Explicit SKIP/failed inspections remain distinct. Observed provider/model/usage
and provider-internal transfer are unknown; no quorum.

Final active XERJ own/reference queries are source-confirmed. Project v6 refresh/
check exits0:451 files,414/414 classified code. Reference579cebbf and the unchanged
engine a24bbe45 checks pass; current source fingerprints include this slice.

Remaining: exhaustive MIME/Ogg/Vorbis and static payload geometry parity,
Archive/caption normalization, dedicated music preview, full reference visual/
gesture parity and subsequent services. Physical routes, system prompts, Account/
server/recipient and minimum26 runtime proof remain unexecuted. Initial reverse
picker selection was not separately exercised; reverse row-menu reorder was.
Full Telegram migration and the overall goal remain open. Both hosted runs for
preceding head2ada537 succeeded; new-slice hosted checks remain separate.

## Historical ordinary Opus music through the common-window File flow (2ada537)

Ordinary picked Ogg/Opus now derives duration and TITLE/ARTIST from bytes using
independently pinned official libogg1.3.6/libopusfile0.12 and the existing reviewed
libopus1.5.1 decoder. A real1.25s recorder-generated file reproduced the native
probe's erroneous13s duration. Opaque/misleading filenames now reach this probe;
native submission keeps original bytes, Audio(false), nil waveform, audio/ogg
and FileName. Recorder intent is never inferred. Schema9 remains unchanged;
older erroneous frozen metadata fails independent recovery equality rather than
being rewritten or sent. First matching tags of the first link retain whitespace.

The held-descriptor probe verifies full Ogg CRC/framing/packet structure and
reconciles packet durations with page granules, cropped initial offsets, pre-skip
and EOS trimming. Independently calculated link totals must equal libopusfile.
Every link gets an initial PCM fragment decode; whole-stream PCM integrity is
not established. Bounds cover bytes, sequential links, channels, packets, tags,
duration and callback reads/seeks. Explicit ARC lifetime lasts through op_free.
In-flight cancellation inside a C callback is not runtime-proved.

The separate lock and preparation recipe authenticate unchanged source/license/
manifest bytes and all17 prepared files. No upstream build tool executes.
Selected stream.c remains for unconditional core references; HTTP/opusurl/TLS
modules are excluded. Warm reuse verifies both recipe and imported helper hashes,
works without archive cache/network/reference checkouts, and refuses old markers.
The old generated directory was preserved before pinned offline re-preparation.
Both unchanged BSD3 notices are bundled; own code remains MIT, combined app GPLv3.
No outer TelegramSwift GPLv2-only code/assets/credentials are copied.

Compiled duration RED1/1 becomes focused GREEN14/0:11 probe cases, one mixed
Opus/MP3 controller case and two actual Postbox/PostgreSQL/S3 recovery cases.
Review found a forged CRC-correct EOS timestamp; real RED1/1 precedes the packet/
granule fix and final green gates. Missing completed granules, cropped initial
offsets, first-page EOS, continued70KiB tags, stereo and actual pre-cancelled probe
entry are covered. Imported-helper marker RED1/1 becomes Python GREEN7/0; the
compile manifest, fixed-width ABI header and source list have independent hashes.
Original characterization/setup/path/schema-evolution failures remain distinct.

`scripts/dev-db.sh up`, final `scripts/test.sh` and `scripts/build-app.sh` exit0:
**1,155 XCTest cases (1,079 Telegram +76 core),1 skipped,0 failures;45 Python
regressions**. All425 source/test/dependency/script/license files remain frozen
through the final full suite/build/UI. The full run emits24 unchanged upstream C
integer-conversion warnings and three pre-existing Swift test warnings;394
existing upstream t19 teardown diagnostics remain without failures. The
host-permission skip is separate. Strict built/owned-QA signatures and raw
unsigned executable equality pass.

Actual owned synthetic AX/screenshots verify Attachments→File using a12,388-byte
Opus fixture renamed `.bin`, chat7 with S3 OFF, original filename/size/caption,
ready status and explicit Send/Cancel in the existing File sheet. With that sheet
open, UI Quit left the process running; restart used verified owned SIGTERM.
The picker source was reversibly renamed. Selecting chat7 restores the same ready
preparation without that path. Explicit Send reaches only the synthetic local
queue; closing observation and Mail→Telegram retain conservative uncertainty/no
automatic resend, selected chat7 and S3 OFF. A dedicated music player/tag preview
is still open; the current sheet has a generic document card. No personal Account,
Telegram network, hardware input or permission grant used.

S3 OFF forbids every new copy, including preparation; local encrypted records
never promote after enable. Actual integration cases assert no archive events,
no S3 object, resume0 and later enable/resume0, including after source removal and
reopen. PostgreSQL stores encrypted metadata, never file bytes. Immutable message
versions and archived files survive remote deletion and preparation cleanup.

Root verifies the frozen revised8-file probe snapshot/copies and25 original raw
check exits, plus247 fold-research and95 dependency-review artifact hashes and69
audio-research command/exit records. Two bounded reviews' findings are resolved;
parent owns final runtime gates and the later helper/test delta. Provider-internal
transfer and observed provider/model/usage remain unknown; no quorum.
Final active XERJ own/reference queries are source-confirmed. Project v6 refresh/
check exits0:443 files,406/406 classified code; pinned reference/engine checks
are fresh. The new nested lock made project v5 refuse schema evolution(exit1);
v6 is a separate prefix, not a reconstructed pass.

Remaining: full ordered source classifier needs separate strict source facts
without changing schemas1–13; Archive/caption normalization, dedicated music
preview, exhaustive Vorbis/other Ogg metadata, full reference visual/gesture parity
and subsequent services remain open. Physical routes, system prompts, Account/
server/recipient and minimum26 runtime proof remain unexecuted. Full Telegram
migration and the overall goal remain open. Both hosted runs for preceding
head3460086 passed; current Opus publication/hosted checks are tracked separately
and no hosted success for this new slice is claimed.

## Historical finished round preview in the common Telegram window (3460086)

Ready and restored round preparations now keep the264pt circular aspect-fill
player inside the300pt common-window overlay. The capture ring disappears. A
separate explicit controller entry repeats strict schema13 profile/decoded facts/
digest validation before attaching the existing native player, using fixed MP4
MIME and round kind. Generic video entry refuses typed round recordings.

The player borrows the same immutable stage, loops muted only while visible in a
key window and disables external playback. Local preview preserves ordinary/once
intent, durable recovery and explicit Send/Cancel. Send, cancellation, rebinding
and release detach the decoder before submission/unlink. Generation and player
identity protect replacement; an already-cancelled entry cannot detach a newer
preview. Navigation dismisses the player and returning reloads the retained record.

Actual fresh cap-time QA exposed source cancellation reaching an in-flight async
writer append. Normal completion now drains the entered append before finishing
the real MP4; explicit cancellation still cancels writer/finish and rejects late
bytes. Compiled manual/watchdog RED2/2 becomes focused GREEN57/0. A subsequent
full run caught testAudioStallWatchdogFinalizesLastValidSamples asserting source
closure before awaiting stop completion (1 failure). Moving that assertion to the
completion boundary passes capture9/0 and the final full suite; production is
unchanged by that test correction. Original failed gates remain distinct.

Compiled behavioral root RED26/7(0 unexpected) becomes focused GREEN37/0,
including real PostgreSQL/S3/encrypted Postbox restored ordinary/once ON/OFF and
Send detachment. Leaf RED10/14 and cancelled-entry RED1/3 precede focused GREEN11/0.
Source-inspection path failures and a reviewer local-capture gap remain recorded
privately, not reconstructed as passing.

`scripts/dev-db.sh up`, final `scripts/test.sh` and `scripts/build-app.sh` exit0:
**1,141 XCTest cases (1,065 Telegram +76 core),1 skipped,0 failures;38 Python
regressions**. All11 changed source/test hashes stay frozen through the final full
suite and build. No compile warnings;390 existing upstream t19 teardown diagnostics
remain without failures. The host-permission skip is separate from deterministic checks.
Strict built/owned-QA signatures, raw unsigned payload equality and camera/
microphone purpose-key equality pass.

Actual owned synthetic AX/screenshots reproduce the missing finished-file preview
on the previous payload. The first preview payload restores that same local once
preparation in chat7 S3 OFF, showing changing encoded frames in the circle without
the capture ring, frozen once and explicit Send/Cancel. Mail→Telegram removes/
reloads the player and preserves chat/OFF. Cancel removes the preparation and
permits a new synthetic recording. The subsequent fresh ordinary cap-time failure
above remains separate from the corrected final-payload replay: a new ordinary
recording reaches the60s cap and retains its ready circle/explicit controls without
sending. Mail→Telegram removes/reloads that player and preserves chat7/OFF.
After owned-process restart, the same ordinary preparation and player restore
with explicit Send/Cancel. Explicit Send detaches the player and reaches only the
synthetic local queue. Closing observation preserves conservative uncertainty/no
automatic resend. No hardware input, permission grant, personal Account or Telegram
network used.

Root verifies139 leaf,114 integration-review and45 stop/drain-review artifact
hashes. Bounded reviews find no additional actionable issue. The final root-only
test delta moves the source-closure assertion after awaited stop. Initial
transferred snapshot and observed route/model/usage remain unknown; no quorum.
Final active XERJ queries are source-confirmed; project refresh/check exit0,
435 files,401/401 classified code, with fresh pinned reference/engine checks.
No dependency/schema/license/engine recipe change or third-party source/assets
copied.

S3 OFF forbids every new copy, including preparation and preview. Encrypted local
records never promote after enable; PostgreSQL stores metadata, not payload bytes.
Cancellation/acceptance/recipient expiration never purge immutable archived files.

Remaining: reference modal/placeholder/shadow/fade and full visual/gesture parity,
physical camera/audio routes/orientation/throughput, OS-blocked native latency,
system prompts, Account/server/recipient and minimum26 runtime proof. Physical
short-click/hold/drag and custom-action invocation remain unproved by CUA. A
held cancel-during-drain case and hardware stop latency are not executed. Next:
ordered classification, Archive/caption normalization and subsequent services.
Full Telegram migration and the overall goal remain open. Hosted CI is separate:
on preceding head504a3d5 one run passed and one failed in
TelegramSyntheticRoundVideoCaptureTests with CancellationError, consistent with
the reproduced cancellation boundary. That historical failure is not a pass;
Hosted checks for this slice are tracked separately; no current-head hosted
success is claimed.

## Historical asynchronous round capture in the common Telegram window (504a3d5)

The shared Voice/round recorder now owns asynchronous camera startup, readiness,
context cancellation, kind-specific rights and durable model handoff. Camera then
microphone authorization rechecks context around each prompt; the inert provider
only checks grants. Warmup waits for video and audio under10s; cancellation and
late completion cannot revive an old recording. Round has60s sample/wall bounds
and a2s audio-stall watchdog. The cap prepares without automatic sending.

An independent private writer produces300-square H264/mono AAC44.1 MP4 with central
crop, horizontal mirror and white circular edge. Actual encoded/decoded fixtures
verify output geometry, timing, the60s bound and cleanup. Separate native-started
state fixes a reproduced first-frame backpressure crash; PCM sample count and
duration must agree. Disconnect notifications use immutable device identities.
The final bytes still pass existing full-asset schema13 admission, preserving its
explicit duration difference from the reference capture clock.

Common composer hold/lock/cancel/once remains; short click selects Voice/round and
an accessibility custom action offers kind switching. The central300pt overlay,
264pt circle and281pt/4pt ring follow the pinned reference source. Prepared/restored
round UI uses its frozen mode and explicit Send/Cancel. Fresh kind-specific rights
before Send retain the prepared record after denial. Real PostgreSQL/S3/encrypted
Postbox model regressions cover ordinary/once ON/OFF, later explicit Send, native
bytes/TTL, accepted reopen/no resend and OFF/no promotion.

Compiled root permission RED4/8 and model/pending RED7/19 become GREEN28/0 and
27/0 in their recorded scopes. Controller leaf RED12/71 becomes GREEN28/0 with
existing voice/permission cases. Capture/writer/synthetic RED13/19 and PCM RED1/2
precede final focused GREEN18/0. Initial backpressure RED is a real native
exception/signal6, not assertion-only failure. Separate compile/setup failures,
extensionless test-fixture decode failure, stale-query procedural error and
unavailable optional metadata-validator exit2 remain private and distinct.

Final `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**1,129 XCTest cases (1,053 Telegram +76 core),1 skipped,0 failures;38 Python
regressions**. After adding an explicit DEBUG initial-round fixture, root repeats
the full suite/build on all19 frozen source/test/script files. No compile warnings
in either full run;390 existing upstream t19 teardown diagnostics remain without
failures. Deterministic permission checks use no device; one host-permission case
is skipped. Strict signatures, raw unsigned built/owned-QA payload equality and
camera/microphone purpose-key equality pass.

Actual owned synthetic AX/screenshots verify the common sidebar, chat7 S3 OFF,
round preview, advancing timer/ring, locked once ON, cancel confirmation and
Continue recording. At60s it retains a ready once preparation without sending.
After owned-process restart, chat7 restores once mode and explicit Send/Cancel;
explicit Send reaches only the synthetic local queue. Closing observation keeps
conservative uncertainty/no automatic resend. A new active round recording is
cancelled by Mail→Telegram, preserving selected chat7 and S3 OFF. The fixture
selects round through an explicit DEBUG argument;
CUA coordinate clicks fail with noWindowsAvailable, so physical short-click/hold/
drag and accessibility custom-action invocation are not established. No hardware
input, permission grant, personal Account or Telegram network is used.

Root independently checks six frozen leaf source/test hashes, five model-review
hashes, four capture-review hashes, six worker output/report hashes and96 original
capture artifact hashes. Bounded final read-only reviews find no further actionable
issue. Initial transfer snapshot and observed route/model/usage remain unknown;
no quorum or passing route attestation. Final active XERJ queries/source reads and
project/reference/engine checks pass; project434 files,400/400 classified code.

S3 OFF forbids every new copy, including recording preparation. Local records
never promote after enable; PostgreSQL stores metadata, not payload bytes.
Cancellation/acceptance/recipient expiration never purge immutable archived files.
No dependency/license/engine recipe change or third-party source/assets copied.

Remaining: reference modal/end-file player and full visual/gesture parity, physical
camera/audio routes/orientation/throughput, native blocked start/stop/finish latency,
system prompts, Account/server/recipient and minimum26 runtime proof. Next complete
round preview/playback, then ordered classification, Archive/caption normalization
and subsequent services. Full Telegram migration and the overall goal remain open.

## Historical round-video controller recovery and atomic native rights (586eda1)

The explicit authored-MP4 entry now connects to TelegramUploadController, strict
schema13 restoration and explicit Send. Preparation requires a complete durable
batch record even without a configured recovery store. Cancellation/rebinding
cannot publish an old probe result. Round preparations reject caption, grouping,
spoiler, above-media text, cover, File conversion, item editing and generic video
preview. Prepared recovery waits for Send; accepted/uncertain state never resumes
sending. Ordinary and once mode survive the controller and encrypted reopen.

TelegramRecordingKind defaults to Voice for compatibility. Round uses native
banSendInstantVideos independently of voice/ordinary-video bans, sharing verified
privacy/cache/access/membership/boost/fee/slow-mode gates. Once keeps its strict
other-human/no-paid-context rule. Final round admission reads the current native
snapshot before insertion in the same Postbox transaction as the receipt.
Production time includes account.network.globalTimeDifference and invalid clocks
fail closed. ACK validates frozen data without rescanning pending slow-mode
messages: this transaction's own new message cannot block its acknowledgement.

Compiled root RED6 cases/5 failures, then combined controller/recovery RED10/9;
after connecting preparation,4 real ON/OFF recovery cases specifically refuse
schema13 restore. Controller GREEN10/0 follows both allowlist corrections.
Native-admission RED1/10 becomes integrated Voice/round/eligibility GREEN97/0;
the final full run also covers an unusable-clock variant. Eligibility leaf
RED23/14(0 unexpected) becomes GREEN23/0. Original logs/exits and separate
discovery/setup failures remain private, including a stale check made while the
project refresh was still running. No failure is relabelled as a pass.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**1,088 XCTest cases (1,012 Telegram +76 core),1 skipped,0 failures;38 Python
regressions**. No compile warnings in the full run; focused rebuilds retain3
existing unrelated warnings.382 existing upstream t19 teardown diagnostics remain
without test failures. One permission-dependent capture test is skipped;
deterministic permission gates use no hardware. Strict signatures and raw unsigned
built/owned-QA payload equality pass. Actual isolated common-window AX/screenshot
smoke verifies chat7 S3 OFF and Mail→Telegram preserving selection/OFF. No screen
changed in this slice and no round-recorder/prepared-round UI proof is claimed.

Root verifies all10 frozen source/test hashes and4 leaf output hashes. A bounded
read-only review finds no additional actionable issues; research and original raw
checks remain private. Initial transferred snapshot, observed provider/model/usage
remain unknown; no quorum. Historical raw-output gaps are recorded privately
rather than reconstructed. Final current project/reference/
engine fingerprint checks and active XERJ queries are source-confirmed; project
coverage is423 files,389/389 classified code. Hosted CI remains separate.

S3 OFF still forbids every new copy, including preparation; local records never
promote after re-enable. PostgreSQL keeps metadata, not payload bytes. Immutable
retention survives Telegram removal/recipient expiration/cancellation. No new
dependency, engine recipe, third-party code/assets or private account access.

Next: implement asynchronous camera+audio capture/readiness, independent central
square/mirror/white circular mask and capture-time bounds; then connect the common
recorder/model, permission/context cancellation, short-click kind switch and
round preview/retained UI. Reference capture timing differs from the existing
full-asset schema13 policy and must not silently redefine it. Actual hardware,
Account/server/recipient and minimum26 runtime remain unproved. Playback, ordered
classifier, Archive/caption normalization and subsequent services remain open.
Full Telegram migration and the overall goal remain open.

## Historical explicit encoded round-video foundation (445c420)

Explicit authored MP4 now has a separate round-video entry and strict schema13.
It preserves exact input bytes and rederives container/codec/decoded sample,
physical geometry, duration and SHA256 facts before durable capture and restore.
One H264 square track and mono AAC44.1kHz are required under documented own bounds
(side<=1024,128MiB,0.5...60s and bounded complete decoding). Native integer ceil is
computed from raw full-asset duration before Float32 freezing. The reference uses
audio-end capture timing; finished-file timing is an explicit local policy.

One round item has Media presentation, empty caption and no grouping/spoiler/
above-media text/cover/original pair. Schema1–12 refuse round metadata. The native
file has only Video(integer duration,200x200,instantRoundVideo), size:nil and
video/mp4. Mapper preview is optional; durable MediaBox currently requires its
ordinary transformed320px JPEG probe, stricter than the reference's optional
preview. Frozen once mode survives local/S3 recovery and canonical native receipt;
exact media TTL stays separate from chat-wide Autoremove. Native flag/lifetime
tampering cannot confirm acceptance; accepted state cannot resend after reopen.
OFF forbids all new S3 copies and local preparation never promotes after enable.
PostgreSQL stores metadata, not attachment payload bytes. No new dependency,
engine recipe or outer GPLv2 UI/helper/shader/assets introduced.

Compiled behavioral RED: corrected schema4 cases/2 failures; native/schema8/19;
real pending7/7(6 unexpected); cover edit1/2. Focused final pending7/0 and cover1/0
precede full GREEN. Leaf compiled RED8/7(6 unexpected), initial GREEN8/0 and final
GREEN10/0 are retained. Separate setup failures include missing try/type helpers,
test-only MainActor inference on a Postbox transaction (SIGTRAP), lazy fixture
schema initialization and a synthetic AVAssetWriter timescale regression. These
are not represented as production behavioral RED. The final cover regression
checks both typed and caller-stripped metadata: no new archive events/copies
before refusal. Both supplied and stored round guards close the review finding.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**1,069 XCTest cases (993 Telegram +76 core),1 skipped,0 failures;38 Python
regressions**. No compile warnings.356 existing upstream t19 teardown diagnostics
remain without test failures. The permission-dependent capture test skips on this
already-authorized host; deterministic status gates run without a device.
Strict signatures and raw unsigned built/owned-QA payload equality pass.

Actual isolated common-window AX/screenshot smoke verifies chat7 S3 OFF and
Mail→Telegram preserving the selected chat/OFF state. No screen changed in this
encoded slice; this is not round-recorder UI evidence. Real encrypted Postbox,
PostgreSQL and S3 tests cover ordinary/once ON/OFF prepare, restore, native
MediaBox bytes/attributes, uncertain receipt, accepted reopen/no-resend and
OFF/no-promotion. No personal Account, Telegram network, microphone, camera or
permission grant used. In-flight native-pull cancellation, deterministic mutation
race injection and exact decode work-counter boundaries remain unproved.

Two bounded inherited-model workers authored the two-file I/O leaf and researched/
reviewed the source contract read-only. Original reports/raw failures stay private;
observed provider/model/usage and initial transferred snapshot hashes are unknown.
No quorum is claimed. Root owns integration, docs, final gates and publication.
Root independently verifies all16 final source/test hashes, both leaf hashes and
12 original leaf check/exit pairs. Final frozen review has no additional actionable
findings. An intermediate review freshness check correctly returned STALE/exit1
and was not queried. Final project XERJ refresh, all three scope checks and active
queries exit0:422 files,388/388 classified code; recorded-round entry/metadata,
desktop sender container and native round flag hits are source-confirmed.
Both hosted jobs for549013c succeed; the new head's checks are separate.

Next: connect schema13 to common-window recording/controller restoration, fresh
banSendInstantVideos and once eligibility, short-click voice/video, camera+audio
permission/cancellation and reference crop/mirror/preview/timing. Exact overlay/
gesture UI, waveform/playback, ordered classifier, Archive/caption normalization
and subsequent services remain open. This foundation does not establish round
capture UI, ordinary round-chat ACL, hardware/server/recipient acceptance or
minimum26 runtime. Full Telegram migration and the overall goal remain open.

## Historical one-time recorded voice in the common Telegram window (549013c)

Locked recording now exposes an optional36-point one-time control. Its false
initial value can change only while locked and eligible; it freezes before async
stop and resets on cancellation/replacement. The visible retained/restored
preparation reads its own frozen mode. Same-account native CloudUser/cache gates
exclude self, bots and any paid-message context, including explicit zero as in
the pinned iOS presentation path. Ordinary voice retains its existing group/
channel rules. Optional once capability precedes the final fresh ordinary check
before capture; final Send and native queue admission check once eligibility again.

Normal Voice keeps the exact three-field metadata and schema11. Literal true
adds one field and strict schema12: one voice, no caption/group/spoiler/cover/
original pair. Explicit false/null/unknown fields or schema/mode mismatch refuse.
The frozen flag survives PCM staging, encrypted local/S3 preparation, restore,
MediaBox and canonical native receipt. Enqueue normalizes the outgoing maximum
Autoremove TTL to one Autoclear(max,nil); acknowledgement rejects missing,
changed/duplicate TTL or a started countdown. Ordinary Voice rejects Autoclear;
chat-wide Autoremove remains independent. Prepared restore needs explicit Send;
submissionStarted stays uncertain, accepted state cannot resend after reopen.
S3 OFF forbids every new copy; local records never promote after enable. Archive
retention remains immutable despite Telegram recipient expiration/cancellation.
No dependency, license or engine recipe changes; no outer GPLv2 source/assets.

Compiled behavioral RED: native builder2 cases/11 failures; state+eligibility12/11;
real ON/OFF controller+reopen4/8; native lifetime callback tampering1/15; fresh
ordinary permission after capability wait1/3. Metadata worker retains its separate
corrected RED7/9(5 unexpected) then compatibility GREEN56/0. Root focused52/0
precedes two additional real one-time Model ON/OFF final-permission regressions;
all final cases pass the full suite. Setup failures (fixture Set typing and UI
module access to an internal metadata helper) remain distinct from behavioral RED.
Two concrete review findings—hidden retained mode and stale capture-time ordinary
permission—are corrected with visible UI and the compiled freshness regression.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0. Full:
**1,043 XCTest cases (967 Telegram +76 core),1 skipped,0 failures;38 Python
regressions**. No compile warnings.330 existing upstream t19 teardown diagnostics
remain without test failures. The permission-dependent capture test skips on this
already-authorized host; deterministic status gates still run without a device.
Strict signatures and raw unsigned built/owned-QA payload equality pass.

Actual isolated common-window AX/screenshots verify keyboard lock, once OFF→ON→OFF,
confirmed cancellation and fresh-session OFF reset, once send to native synthetic
queue with chat7 S3 OFF, visible frozen once label under lost upload acknowledgement,
and label/OFF preservation across Mail→Telegram. Initial loss QA used the forward
flag and therefore did not exercise upload loss; corrected existing pending-upload
flag then produces the expected uncertain UI. Restart with the already-persisted
accepted receipt restores the ordinary composer without a sendable old preparation.
Prepared/uncertain restoration is exercised by real controller/Postbox tests;
its unaccepted restart UI was not separately rendered. No personal Account,
Telegram network, microphone device or permission grant used.

Two bounded inherited-model workers authored the metadata/draft leaf and researched/
reviewed the reference contract read-only. Original reports/hashes/raw exits stay
private; observed provider/model/usage are unknown and no quorum is claimed.
Root independently rechecks all20 reviewed source/test hashes and the metadata
worker's11 raw log/exit pairs. Final frozen review finds no additional actionable
defects; R1/R2 remain closed. Initial transfer hashes are unknown; private
normalization does not attest runtime identity. Root owns integration, docs and
publication. Final frozen XERJ project refresh,
three scope checks and queries exit0:416 files,382/382 classified code; own once
eligibility, desktop SingleTimeControl and native Autoclear definitions are source-
confirmed. Both hosted jobs for7aab0c7 succeed; this new head's checks are separate.

Remaining: exact floating recorder overlay/animations and actual upward/outside
release gestures, short-click voice/video and round-video, live waveform/playback,
then ordered classifier, Archive/caption normalization and sequential services.
Incoming once playback, real recipient/server acceptance, microphone routes,
in-flight native I/O cancellation and minimum26 runtime remain unproved. Full
Telegram migration and the overall goal remain open.

## Historical native voice capture and common-window recording controls (7aab0c7)

The empty Telegram composer now exposes a native recorder in the existing
common window. Hold300ms starts capture, release inside sends, release outside
cancels, and upward movement >100 points locks recording. Locked cancellation
requires confirmation; accessible/keyboard activation locks explicitly. Chat,
account, surface removal and app deactivation cancel the current intent. Frozen
input/session/preparation IDs prevent delayed holds, permission results and old
cancelled handoffs from affecting a replacement recording. A600s cap stops into
visible durable preparation and requires an explicit send, rather than sending
automatically. One-time voice and round-video recording remain open.

The native AVAudioRecorder leaf requests no access at construction/start: the
model owns the microphone prompt after an explicit recording action. It checks
same-account native peer/cache, voice privacy, membership/media bans, slow mode
and fee eligibility before permission, after permission and immediately before
queue admission. Missing required cache or paid context refuses; there is no
implicit payment authorization. Postbox snapshot freshness is not server proof;
slow-mode pending lookup currently scans only that channel's local history.
Saved Messages without required user cache, secret chats and monoforum are
conservatively unavailable in this ordinary-chat path.

Capture uses private0700/0600 temporary CAF,48kHz mono signed16-bit PCM, held
no-follow descriptors, bounded finite CAF extents and native AVAudioFile reads
on a utility worker. Positive short reads continue to exact validated EOF;
oversize input is refused without truncation. Stop/cancel/error/deinit remove
owned temporary capture. Exact600s synthetic CAF readback passes. The existing
codec/waveform/schema11/durable native queue remains the only handoff. Voice
requires durable state, has no generic caption/file preview, and final eligibility
failure retains explicit preparation. S3 OFF forbids every new copy, including
voice preparation; encrypted local records never promote after re-enable.
No schema, dependency, license or engine recipe changes are introduced.

Compiled behavioral REDs are retained for recorder state7/29, model+preview10/8,
native snapshot1/1, async request5/3, authorization lock1/2, final eligibility2/4,
cancellation/context ordering3/9 and replacement ownership1/2. Capture and peer
leaf RED/GREEN reports are retained separately. Compilation fixture failures,
the invalid native PeerId sentinel trap and the NSView inputContext name collision
are setup failures, not behavioral RED. Native CAF edit-count and short-read
assumptions failed and were corrected against actual AVAudioFile output; the
cleanup-mode regression also failed before correction.

Focused integration:71 cases,1 skipped,0 failures. Full `scripts/test.sh`:
**1,019 XCTest cases (943 Telegram +76 core),1 skipped,0 failures;38 Python
regressions**. The direct unauthorized-start test skips because this host test
process already has authorization; deterministic status-gate tests still cover
all statuses without opening a device. `scripts/dev-db.sh up` and
`scripts/build-app.sh` exit0; strict built/owned-QA signatures and raw unsigned
payload equality pass. Final logs contain no compile warnings; existing upstream
t19 teardown diagnostics remain without failed tests. Host27.0.1 does not
establish minimum26 runtime.

Actual synthetic common-window QA initially failed to start: NSViewRepresentable
retained the restoring-draft availability because only the model reference and
phase were inputs. Explicit availability/context values and SwiftUI disabled
state fix this. Retested hold/release reaches synthetic local queue with S3 OFF,
without a caption sheet. A button/keyboard sequence locks recording; timer,
confirmation, Continue and confirmed cancellation restore the editor. Leaving
an active recording for Mail and returning to Telegram stops capture and retains
chat7/off. Restart does not resurrect the accepted preparation. Tool drag twice
failed with noWindowsAvailable; upward/outside-release gestures are controller
regressions, not claimed as rendered UI proof. Temporary diagnostics were removed.
No personal Account, Telegram network, real microphone or permission grant was
used. Hardware capture/route, in-flight native-I/O cancellation,600s hardware
recording/playback and live server acceptance remain unproved.

Two bounded inherited-model workers authored disjoint capture/eligibility leaves;
the eligibility worker additionally reviewed root source read-only. Root resolved
four ownership/order findings and verified integration. Worker hashes/raw exits
are normalized locally; observed model/provider/usage are unknown and no quorum
is claimed. The subsequent UI snapshot fix is root-reviewed separately. A project
index attempt during diagnostic edits failed with source-changed exit1; it is
not reused as fresh evidence. Final frozen project refresh/check/query and
reference/engine checks exit0:414 indexed files,380/380 classified code. Current
controller/handoff and desktop overlay hits are source-confirmed.
Both hosted runs for54c28dc succeed; this new head's hosted checks are separate.

Next: remaining reference recorder parity (including one-time/round video and
verified gesture UI), then the ordered classifier, Archive/caption normalization
and remaining sequential Telegram/service migration. See reference-interface.md
for exact visual/workflow differences.

## Historical PCM controller admission (54c28dc)

The internal voice entry now connects original PCM to the existing owned codec,
schema11 recovery and native batch queue. It requires same-account batch
capability, valid reply target and no active preparation. One Voice has empty
caption, no grouping and File transport presentation. Durable whole-batch state
is mandatory before send, including when ordinary single-file recovery is
optional. OFF still forbids every new S3 copy and uses encrypted local storage.
No microphone capture, recorder control, schema, dependency, license or engine
recipe change is introduced.

The new-recording threshold follows the complete source trace: desktop
ChatRecordingAudioState requires duration >0.5s; AudioRecorder submits only full
960-sample packets, and the pinned iOS writer computes total_samples/coding_rate.
More than25 packets are required (first accepted count24,960). Initial raw-PCM
24,001 acceptance was too permissive and is corrected. Codec/restore retain
their prior exact partial-PCM/short-record compatibility. A source-confirmed
XERJ class hit informs the trace; encodedDuration itself returns no match in
the desktop scope and is separately verified against the pinned iOS source/hash.

Compiled stub RED6 tests/19 failures(1 unexpected), early-caption RED1/2,
cancel-restriction RED1/1 and complete-packet minimum RED1/7 precede final
focused GREEN13/0 (8 controller +5 pending). Rich/legacy caption edits refuse
also before item publication; cancellation releases the restriction. Reentrant
composer cancellation/account replacement cannot launch a stale worker.
Two new real controller tests exercise encrypted Postbox/PostgreSQL/S3 ON/OFF,
complete native receipt, exact MediaBox bytes/Voice attributes, stage cleanup,
stale-context send refusal and accepted-pointer reopen/no-resend. OFF remains
absent from S3 after later enable. No personal account/server was used.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0 after the
packet correction: **979 XCTest (903 Telegram +76 core), zero failures;38 Python
regressions**. The earlier full979/0 run predates that correction and is retained
separately. Final full/build logs have zero compile warnings. Earlier targeted
compilation reports two unchanged weak-variable warnings in existing batch
tests.294 existing upstream t19 teardown diagnostics remain without failures;
historical cold C warnings are retained below.

Owned synthetic bundle update passes strict signatures and raw unsigned built–QA
payload equality. Actual screenshots/AX inspected: chat7 S3 OFF, Mail selects its
existing disconnected surface, then Telegram returns to chat7/off in the common
window. This is shell smoke, not microphone/recorder UI or live Account/server
proof. No personal account, Telegram network or microphone was used. Host27.0.1
does not prove minimum26 runtime.

Root reviews the focused source/diff, packet threshold, callback/cancellation
ownership, caption guards, legacy compatibility and real native ON/OFF recovery.
No new worker/quorum is claimed. Current frozen XERJ refresh/check/query and
reference/engine checks exit0:401 files,367/367 classified code; controller and
reference class hits are source-confirmed. The encodedDuration no-match limitation
is recorded above. Both hosted runs for f842bc8 now succeed; validation of this
new publication is separate.

Next: explicit microphone capability, peer/slow-mode eligibility and reference
hold/lock/cancel controls in the common window. A separate desktop preview is
not established by the inspected reference controls; confirm it before adding.
One-time/round-video, full ordered classifier, Archive/caption normalization,
live Account/server, other channels and the sequential migration remain open.

## Historical original-PCM waveform (f842bc8)

New explicit voice preparations now retain100 five-bit waveform values in63
bytes from original PCM. Source-confirmed AudioRecorder:594–745 and
AudioWaveform:67–85 inform complete960-sample packet preview, continuous100-sample
peak windows, signed-minimum saturation, virtual zero/peak bin positions, running
maximum normalization ×1.8/100 with floor2500, and LSB packing/zero padding.
The independent implementation uses fixed100-bin storage and safe byte packing;
no reference helper/UI code was copied. Utility workers check cancellation
between peak windows. The codec's existing exact partial-PCM audio preservation
remains distinct from waveform's ignored incomplete packet/window tails.

Waveform stays frozen through schema11, authenticated local/S3 preparation,
restore, native Voice admission and complete receipts. Real ON/OFF encrypted
Postbox/PostgreSQL/S3 reopen tests now assert a nonzero literal waveform and exact
native bytes. A native pulse has original first value12 and decoded15; re-probe
retains original PCM waveform instead of recomputing it from lossy Opus. Existing
explicit null-waveform preparations retain null. S3 OFF forbids all new copies;
local records never promote on re-enable. No schema, dependency, license, engine
recipe, microphone action or recorder UI change is introduced.

Actual compiled stub RED13 tests/17 failures(11 unexpected), plus separate
lossy/bounds RED2/3(2 unexpected). First implementation passes waveform8/0 but
combined28/1: the initial3000-amplitude fixture incorrectly assumes lossy output
changes its coarse waveform. A temporary native five-candidate probe identifies
the sensitive1000-amplitude fixture; that diagnostic is removed after retaining
its raw output. Literal first byte0x0c independently defines the corrected
expectation. Focused GREEN28/0; full gates additionally cover old null restoration.
Tests verify exact bit positions/padding, running normalization, short/constant/
signed-extreme PCM, packet/window boundaries,600s waveform calculation,
oversized refusal and pre-cancellation. In-flight cancellation and600s audio
playback remain unproved.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**969 XCTest (893 Telegram +76 core), zero failures;38 Python regressions**.
Current full/build logs have zero compile warnings. Existing upstream t19
teardown diagnostics remain without failures; prior cold C warnings are retained
below. Both hosted runs for f7828e3 succeed, confirming its prior test-expression
compiler fix. Hosted CI for this new publication is separate.

Owned synthetic app update passes strict signatures and raw unsigned built–QA
payload equality. Actual screenshots/AX inspected: chat7 S3 OFF, Mail selects its
existing disconnected surface, then Telegram returns to chat7/off. No personal
account, Telegram network or microphone was used. This is common-window smoke,
not recorder/live waveform/playback UI proof. Host27.0.1 does not prove minimum26.

Root reviews waveform math/bounds/packing/cancellation, original-PCM provenance,
legacy null behavior, native ON/OFF recovery and focused diff. No independent
new worker/quorum is claimed. Frozen XERJ refresh/check/query and reference/engine
freshness checks exit0:400 files,366/366 classified code. Own waveform and pinned
reference recorder/packing hits are source-confirmed. The corrected source line
range was followed by a new frozen refresh; no stale index is reused.

Next: reference recorder interaction, explicit microphone capability, recording/
locked/preview controls and playback within the existing common window. Full
ordered classifier, Archive/caption normalization, live Account/server validation,
remaining channels and the sequential migration goal remain open.

## Historical explicit durable Voice path (f7828e3)

Explicit recorded PCM now creates an owned Ogg/Opus stage with schema11 voice
provenance: exact sampleCount, plaintext SHA256 and explicit nullable waveform.
Schema1–10 reject voice while retaining their existing meanings. One voice item
has no caption/group/spoiler/above/source pair/cover. Internal File presentation
is a transport choice; no recorder UI is exposed. Picked files never acquire
voice provenance from name/MIME/container. Metadata enforces600s/20MiB, and the
optional100-value5-bit waveform layout is frozen but currently null.

Capture, restore and MediaBox independently decode the owned bytes to verify
actual PCM count/hash through held no-follow snapshots. Invalid captions/facts
refuse before archive capture. ON uses authenticated encrypted S3; OFF prohibits
all new copies, including preparation, and uses authenticated encrypted local
storage. Local records never promote on re-enable; PostgreSQL stores no payload
bytes. Retry retains the same record. Native attributes match pinned
SenderController:295–312: audio/ogg, only Audio(isVoice:true, integral duration,
nil title/performer, frozen waveform), nil media size and no FileName/preview/
thumbnail/cover. Actual resource byte size remains available.

Corrected behavioral stub RED9 tests/8 unexpected failures precedes focused
schema/IO GREEN9/0. Earlier test compilation and exception-autoclosure fixture
errors are retained separately. Real encrypted Postbox/PostgreSQL/S3 tests cover
ON/OFF reopen, exact native MediaBox bytes/Voice attributes, complete acceptance,
stale resend refusal and accepted-pointer reopen. Invalid envelopes/facts create
no archive record. First integration attempt traps because a test's MainActor
closure runs on Postbox's queue; moving only transaction fixture bodies outside
MainActor resolves it. This is a test setup failure, not production RED. Final
voice GREEN19/0; broader pending/batch/typed compatibility GREEN104/0.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**959 XCTest (883 Telegram +76 core), zero failures;38 Python regressions**.
Current incremental full/build logs have zero compile warnings. Existing upstream
t19 teardown diagnostics remain without failures; prior cold C warnings remain
as documented below. Both hosted runs for ecca7af failed test compilation at the
same complex tone expression. Explicit typed intermediate steps now compile and
pass locally; hosted validation of the next publication is separate.

Owned synthetic app update passes strict signatures and raw unsigned built–QA
payload equality. Actual screenshots/AX inspected: chat7 S3 OFF, Mail opens its
existing disconnected surface, then Telegram returns to chat7/off. No personal
account, Telegram network or microphone was used. This is common-window smoke,
not recorder interaction proof. Host27.0.1 does not establish minimum26 runtime.

Root reviews the focused diff, byte ownership/cancellation, schema compatibility,
pre-capture failure paths, policy handling, native receipts and regression scope.
No new dependency, license, engine recipe or interface change; no independent new
worker/quorum is claimed. Frozen XERJ v5 refresh/check/query and reference/engine
freshness checks exit0:398 files,364/364 classified code. Actual voice stage/
metadata and reference VoiceSenderContainer hits are source-confirmed. An initial
query used the wrong reference prefix and returned no hits; the corrected locked
prefix succeeds. No stale/empty search is substituted as current evidence.

Next: independently verified waveform, then reference recorder interaction.
Full ordered classifier, Archive/caption normalization, live Account/server
validation, remaining channels and the sequential migration goal remain open.

## Historical internal offline voice codec (ecca7af)

An independently authored internal codec now encodes explicit48kHz mono Int16
PCM into Ogg/Opus and decodes its bounded recording format. Reference writer
settings are20ms/960 samples,30×1024bit/s, APPLICATION_AUDIO and16-bit depth;
dynamic encoder lookahead and EOS trim preserve exact PCM count, including a
single sample. Utility workers own/destroy native pointers, check cancellation
between frames and enforce600s/20MiB bounds. Strict parsing verifies headers,
mono/rate/gain/map, lacing/CRC, sequence/stream,20ms packet lengths and EOS/count.
One packet per page, Makosh-only vendor/no comment padding and the bounds are
independent implementation choices. CRC is not authentication; later durable
integration must retain plaintext digest and explicit recorded provenance.
No microphone, picker classification, waveform, storage behavior or native
Voice outgoing path is enabled by this internal leaf.

Opus1.5.1 is independently pinned to the selected iOS tree/archive, whose SHA256
matches the official release. The reviewed recipe prepares137 portable C files,
103 headers and exact notices/manifests without upstream installers or research
checkouts. The tracked aggregate binds all245 prepared files; warm reuse needs
neither Git cache nor network and rejects changed/missing/extra/link output.
Own C control/Ogg code replaces no existing interface and copies no reference
recorder, OpusBinding or libogg helper. COPYING and68 selected source attribution
blocks are bundled; THIRD_PARTY_NOTICES.md records scope and license review.

Actual preparation stub RED6 tests/16 failures; GREEN6/0. Codec's first attempt
fails test compilation for an optional output pointer (not behavioral RED).
Compiled stub RED7 tests/8 failures(6 unexpected); real implementation GREEN7/0.
Independent page/CRC reader and native libopus decoder verify format, audio
correlation, exact trim, partial/silent frames, bitrate bounds, damaged/truncated/
trailing data, rechecksummed semantic forgeries and pre-cancellation. In-flight
cancellation, full600-second playback and general Ogg import are not claimed.
Cold portable C builds report two upstream narrowing warnings and an upstream
debug-without-optimization warning; an earlier missing-lrint fallback warning
was resolved in the reviewed recipe, never by editing generated sources.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**947 XCTest (871 Telegram +76 core), zero failures;38 Python regressions**.
Current incremental full test/build logs have no compile warnings; the cold C
warnings above and existing upstream t19 teardown diagnostics remain disclosed.
A separate real PostgreSQL/Postbox/S3 policy recheck passes38/0: OFF prohibits
all new copies including preparation, default groups/channels stay local,
restart restores bytes, and enabling later never promotes local preparations.

Owned synthetic bundle update passes strict signatures and raw unsigned built–QA
payload equality. Actual common-window screenshots/AX were inspected: chat7
retains S3 OFF, Mail opens its existing disconnected surface, and Telegram
returns to the same chat/off choice. A click consumed while closing the policy
menu was corrected and actual Mail selection verified; no product defect was
inferred. No personal account, Telegram network or microphone was used.
No recorder UI or complete voice-send/recovery claim is made. Host27.0.1 does
not prove minimum26 runtime.

Root reviews the focused source/diff, dependency boundary, bounded/native failure
paths, backwards compatibility, tests and bundled notices; no independent new
worker review or quorum is claimed. XERJ v4 actually refused new Opus lock fields
(exit1); the recorded diagnostic requires the new v5 prefix. Frozen refresh/check/
query and reference/engine freshness checks pass0:393 files,359/359 classified
code, source-confirmed codec/recorder hits. Both hosted runs for prior919d57f
succeeded; hosted CI for the next publication is separate.

Next: explicit recorded provenance, authenticated durable ON/OFF preparation and
native Voice attributes, then waveform and reference recorder interaction.
Full ordered classifier, Archive/caption normalization, live Account/server
validation, remaining channels and the sequential migration goal remain open.

## Historical durable GIF pair (919d57f)

GIF classification now binds owned raw bytes to the converted H.264 MP4 using
strict schema10 source SHA256, canvas and Float delays. The two payloads have
separate encrypted records. File selects the original, Media selects the MP4;
mode edits and retry reuse the same records. Both resources are frozen before
the first save and re-probed after all-or-cleanup restoration. Unsafe recognizable
GIF remains an unchanged generic file; old generic drafts are not reclassified.
Schema1–9 meanings and existing audio/WebP behavior remain supported.

Native GIF Media has reference wire duration0 with exact Video/FileName and
Animated only outside collage; measured positive duration stays in recovery.
File uses image/gif/ImageSize/original filename independently of suffix. A
separate optional original-frame0 JPEG (max320/no upscale, quality0.7, cap1MiB)
is regenerated in MediaBox only. Exact payload/preview readback, distinct IDs,
complete representation flags and native attributes bind admission and ACK.
GIF cover editing is disabled: the reference exposes that menu through isVideo
but its GIF sender ignores customPreview. This difference is recorded in
reference-interface.md. No dependency, engine recipe or license changed.

S3 OFF forbids every new S3 copy, including outgoing raw/MP4 preparation.
Both records stay in authenticated encrypted local storage; re-enable never
promotes them. No payload bytes are stored in PostgreSQL. Four real
Postbox/PostgreSQL/S3 regressions cover both presentations with ON/OFF, restart,
exact native bytes and no resend. Literal schema bounds regressions close the
independent review's raw-zero/canonical-over128MiB admission finding.

Actual behavioral REDs are retained separately from compilation/setup failures:
schema4/4 unexpected, controller4/9, local pair1/1, preview6/11, native mapper2/8,
shared-resource admission1/2 and pair-bounds2 failures. One restart test initially
called explicit cancellation through clear(); its corrected process-release
fixture then failed only for the missing preview. Focused final GREEN47/0.
`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**940 XCTest (864 Telegram +76 core), zero failures;32 Python regressions**.
Current full test/build logs have no compile warning. Existing upstream t19
teardown diagnostics remain without test failures.

Owned synthetic common-window QA picks a1247-byte GIF under .bin with S3 OFF,
switches File→Media→File, retains its15-UTF16 caption after removal of the chosen
source path and process restart, and accepts one native queue ID. File/Media
screenshots were inspected. Strict bundle signatures and raw unsigned built–QA
payload equality pass. Separate stopped-app Postbox/PostgreSQL/S3 readbacks
before/after native acceptance each pass1/0: same preparation and two local IDs,
exact raw/MP4 bytes/hashes/facts/caption, absent local/conventional S3 objects,
empty file archive metadata and separate32×16 native JPEG/default flags.
The second process restart does not resurrect a preparation or queue it again;
Mail→Telegram retains chat7 and S3 OFF. Temporary private readback tests were
removed. No personal account, Telegram
network or microphone was used. Host27.0.1 does not prove minimum26 runtime.

Independent final source review reports no new actionable defect; the prior
bounds finding is closed. Root verifies20 before/end/current patch hashes and
30 raw command/exit pointers; preview author contract has2 current file hashes,
4 unchanged read dependencies and10 raw pointers. Worker runtime is SKIP;
parent gates/UI are separate, observed provider/model/usage unknown, no quorum.
The mid-edit XERJ refresh failed because source changed during indexing; its
failure is retained. Final frozen XERJ refresh/check/query and reference/engine
freshness checks exit0:383 files,352/352 classified code. Root source-confirms
GIF pair/preview hits; no stale mid-edit index is reused.
Hosted CI for published standalone codec500facc succeeded in both runs.

Next: recorded voice/codec, ordered source options, Archive and caption
normalization. Full Telegram parity, live Account/server validation, remaining
channels and the sequential migration goal remain open.

## Historical standalone GIF codec (500facc)

An internal native GIF leaf now inspects owned bytes and produces
an independent H.264 MP4. It is deliberately not connected to the picker,
preparation schema, native mapper or storage yet: product GIF remains generic
File until both original GIF and converted MP4 have durable, separate records.
No interface, schema, S3 policy, engine recipe, dependency or license changed.

The held no-follow source descriptor survives conversion and output validation;
exact source facts and an optional lowercase SHA256 bind the immutable bytes.
GIF87a/89a canvas, every decoded frame and Float delays are bounded:20MiB input,
4096 per axis,16M canvas pixels,256 frames,256M decoded canvas work and600s.
Missing/zero/one-centisecond delay becomes0.1. The independent AVFoundation
writer uses H.264 High4.0/512kbps, no audio or resizing,600-timescale sample PTS
and the reference's Float-to-Double last-delay repeat boundary. Measured positive
MP4 duration stays distinct from the eventual reference wire duration0.
Owned output is bounded128MiB and re-probed for canvas, audio and H.264 before
return. Writer start/append/finish/cancel stay on a private actor; cancellation
only schedules actor work and awaits teardown before failed-output cleanup.
BGRA/sRGB, explicit black matte, disabled frame reordering and offline input are
independent implementation choices, not copied upstream helper code.

Actual combined stub RED:12 tests/11 failures(11 unexpected). A separate test
actor-isolation setup failure and two writer Swift6 setup failures are retained
as compilation failures, not behavior evidence. First compiled native run fails
16/6 because the test reader supplies no container hint for extensionless owned
payload paths; production's hinted native validators already accept the output.
Adding the independently expected video/mp4 hint only to test readers gives
focused GREEN16/0. Actual pixel/PTS readback proves full and partial canvas,
disposal2/3, single-frame output, the0.33 Float boundary and unchanged originals.
Ownership, symlink, forged size, bounds, digest/facts mismatch and pre-cancel
are covered. In-flight cancellation/mutation, transparency and odd-axis native
behavior remain unproved; no end-to-end GIF send/recovery claim is made.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**910 XCTest (834 Telegram +76 core), zero failures;32 Python regressions**.
Final incremental test/build logs have no compile warning; three existing test
warnings appeared during the earlier compiled focused attempt.266 upstream t19
teardown diagnostics remain without test failures.

Actual owned synthetic common-window screenshots are inspected after updating
the QA bundle: strict signatures and raw unsigned built–QA equality pass.
Mail→Telegram retains chat7 and its S3-off choice. No GIF product flow was exposed;
codec runtime evidence comes from the native tests above. No personal account,
Telegram network or microphone was used. Host27.0.1 does not prove minimum26.

Independent frozen source review reports no concrete defect. Root validates
13 before/end/current source/test/support hashes,13 raw command/exit pointers
and the author contract's14 terminal hashes with9 unchanged reference/lock/helper
guards and11 raw pointers. Worker runtime is SKIP; parent gates/UI are separate,
observed provider/model/usage unknown, no quorum. Current XERJ refresh/check/query and
reference/engine freshness checks exit0:378 files,347/347 classified code;
new GIFIO/GIFEncoder hits are source-confirmed. Hosted CI for published WebP
preview7e2c976 has succeeded in both runs.

Next: retain and re-probe raw GIF plus MP4 independently, strict schema/provenance,
File/Media projection and exact native attributes, both storage modes and restart
acceptance. Recorded voice/codec, ordered source options, Archive and caption
normalization follow. Full Telegram parity and the sequential migration goal
remain open.

## Historical optional WebP transport JPEG (7e2c976)

Typed WebP now supplies a separate optional first-frame JPEG in native enqueue:
transformed index0, maximum320px without upscaling, quality0.7 and at most1MiB.
The same held owned bytes are checked against the frozen plaintext digest before
encoding. Original WebP bytes/animation and schema9 remain unchanged. The distinct
webPPreview role reuses the existing bounded JPEG identity; mandatory video
thumbnails retain their role. MediaBox reads back exact derivative/original bytes;
batch admission rejects shared/cross-original IDs and ACK checks every hidden
representation flag. Codec/encode omission is optional; ownership/hash/cancel
errors still fail. No dependency, engine recipe or license change was introduced.

Actual RED: missing native preview1/1 twice, local/S3 recovery2/2, mapper1/7,
shared/cross-original admission1/2. Combined stub RED19 tests/22 failures,
zero unexpected. First focused implementation58/1 fails only the quality test's
oracle: native prototype exit0 proves ImageIO quantization differs between a
WebP CGImage and a decoded JPEG CGImage at the same0.7 quality. Correcting the
oracle to start from the literal original fixture gives focused GREEN58/0.
Production quality remains0.7. Native fixtures prove640×320→320×160, small
20×10 without upscaling, animated frame0, partial canvas and digest mismatch.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**894 XCTest (818 Telegram +76 core), zero failures;32 Python regressions**.
Full test compilation reports three existing warnings (unreachable catch in
TelegramRetentionJournalTests and two weak-let suggestions in batch controller
tests);266 upstream t19 teardown diagnostics remain without test failures.
Build log has no compile warning. Temporary private readback tests were removed.

Actual owned common-sidebar UI picks196-byte partial-canvas WebP under.bin in
S3-off chat7, retains its12-UTF16 caption after hash-verified source removal,
SIGTERM and relaunch, then accepts one native queue ID. Another restart shows no
preparation resurrection; Mail→Telegram retains chat/off. Screenshots were
inspected; strict signatures and raw unsigned built–QA equality pass. The File
composer still shows its existing icon; this slice supplies transport preview.
Native GoTo paste left the old selected path unchanged; AXsetValue corrected and
verified the exact owned source before opening. No product input bug is inferred.
No personal account, microphone or Telegram network was used; native host remains
macOS27.0.1, without local runtime proof on minimum macOS26.

Private real Postbox/PostgreSQL/S3 readbacks before/after acceptance each pass1/0:
same preparation/local record, exact original bytes/hash/metadata/caption, absent
local/conventional S3 keys and empty archive-file metadata. Accepted MediaBox has a separate
320×160 JPEG/default flags and unchanged WebP original. Both storage recovery
paths and no promotion after re-enable remain covered. JPEG is regenerated from
the authenticated original and creates no archive/S3 record.

XERJ refresh/check/query and reference/engine freshness checks exit0:
373 indexed files,342/342 classified code. Root confirms new webPPreview hits
against source and validates the author contract's10 terminal source/lock hashes.
Independent frozen source review reports no concrete defect; root verifies9 patch
hashes and14 supporting source/lock/report hashes plus25 raw command/exit pointers.
Worker runtime is SKIP; root gates/UI remain separate, observed provider/model/
usage unknown, no quorum. This preview slice is published as7e2c976;
hosted CI has succeeded in both runs.

Next: GIF typed conversion and explicit voice/codec work, then the frozen ordered
source-option fold, Archive and caption normalization. Full Telegram parity,
Account/server delivery and the remaining sequential migration stay open.

## Historical typed original WebP (036cded)

WebP now retains original bytes and strict width/height metadata in schema9.
Content inspection runs before photo/suffix classification, including misleading
.jpg/.wav/.bin and an explicit photo choice. Native mapping has exact
ImageSize/FileName/Sticker order and canonical image/webp MIME in both projections;
animated input does not infer Animated/Video. Any typed WebP forbids grouping.
Legacy generic files remain untyped. Audio schema9 compatibility is retained.
No engine recipe, dependency or license change was introduced.

Apple ImageIO checks a held owned no-follow snapshot:12-byte sniff, exact RIFF
length,20MiB encoded,8192 per axis/40M pixels,1…256 frames, safe canvas/frame0
and a bounded256px thumbnail decode. Synthetic lossless/lossy, animated and
partial-frame inputs keep exact original bytes; partial first20×10 at(100,60)
uses full320×160 canvas. Native prototype and product tests ran on macOS27.0.1,
not the minimum26 runtime. Whole-stream/all-frame integrity is not claimed.
Own limits and refusal instead of upstream512×512 fallback are explicit differences.
Recognizable unsafe new input stays unchanged generic File; typed restore must
re-probe exactly. Optional320px JPEG transport preview remains open.

Actual RED: six initial pipeline tests fail with six unsupported-kind failures.
Combined IO/pipeline stubs fail19 tests/33 failures(5 unexpected); separate
controller/reopen RED4/40(0 unexpected) proves missing classification/grouping.
First focused implementation run fails25/3: the root test mutated an intermediate
reference which the resource deliberately recomputes. Corrected coverage mutates
the real native queue media instead. A subsequent helper argument-order compile
failure is setup FAIL, not behavior evidence. Final focused GREEN26/0 exit0.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**877 XCTest (801 Telegram +76 core), zero failures;32 Python regressions**.
Final incremental logs have no compile warnings;262 upstream t19 teardown
diagnostics remain without test failures. Temporary native readback tests were
removed;12 frozen source/test hashes retain the independently reviewed scope.

Actual owned common sidebar UI picks the synthetic196-byte partial-canvas WebP
under an opaque .bin name in S3-off chat7. The10-UTF16 caption and File preparation
survive hash-verified source removal, SIGTERM and relaunch. The native queue
accepts one ID; another restart shows no preparation resurrection. Mail→Telegram
retains chat7/off. Screenshots were inspected; strict signatures and raw unsigned
built–QA equality pass. One keyboard typing attempt inserted only spaces; native
paste corrected it and the exact caption was verified before acceptance.
No personal account, microphone or Telegram network was used.

Both private real Postbox/PostgreSQL/S3 readbacks pass one test each: same local
record/preparation, original bytes/hash, typed dimensions/caption, empty archive-
file metadata and absent objects under local and conventional S3 keys. Accepted
native MIME/attributes match exactly. Real integration also covers S3-enabled
recovery, changed dimensions despite a valid digest, immutable acceptance after
restart and no promotion after policy re-enable.

Independent frozen WebP review reports no concrete defect; root verifies12 patch
hashes and11 supporting sources plus3 research reports. Root gates/UI are actual;
worker runtime is SKIP, observed provider/model/usage unknown, no quorum.
Final XERJ refresh/check/query and reference/engine freshness checks exit0:
371 indexed files,340/340 classified code. New inspectOwned passage is confirmed
against current source. Hosted CI for c0e9789 and9e42da7 reports success; current
WebP patch awaits its own hosted CI runs.

Next: WebP transport preview, GIF typed conversion and explicit voice/codec work,
then the frozen ordered source-option fold, Archive and caption normalization.
Full Telegram parity and Account/server delivery remain open. Other services,
dossiers, backup/restore and packaging remain in sequence; the migration goal
stays active.

## Historical typed ordinary audio (9e42da7)

Ordinary music now retains original bytes and exact integral duration/title/
performer in strict schema9. File/Media projection, metadata-only edits,
policy-aware capture, restart re-probe, MediaBox preparation and transaction-bound
complete receipts retain that descriptor. Native attributes are Audio(false,
duration,title,performer,nil) followed by FileName. Legacy generic files remain
untyped; single-file APIs refuse typed items. Synthetic WAV, tagged M4A and ID3
MP3 are proved. No engine recipe, dependency or license changes were introduced.

The owned probe derives MIME from CoreAudio byte inspection, then validates
AVFoundation duration, a bounded PCM fragment and tags. Opaque spool names require
that content-derived hint; filenames are not decoding proof. Snapshot/ownership
and cancellation guards remain. Full-stream integrity, exhaustive codecs,
deterministic in-flight mutation/cancellation tests, OGG/Opus and recorded voice
are not claimed. The ObjC reference's Key/Identifier comparison quirk is recorded
separately from Makosh's verified native tag identifiers.

Actual initial RED:19 tests/52 failures, including intentional probe stubs and
separate assertion/lifetime fixture failures. First implementation attempt remains
FAIL19/18; the content-derived MIME fix and fixture corrections produce focused
GREEN22/0. A separate grouping RED1/1 closes filename-only admission into a typed
music group. A later conflicting-null RED1/3 is fixed and covered by the full gate.
Worker Swift6 setup compilation failure is not behavior RED.

`scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**853 XCTest (777 Telegram +76 core), zero failures;32 Python regressions**.
The final incremental test/build logs have no compile warnings;252 upstream t19
teardown diagnostics remain without test failures. All temporary QA tests were
removed;19 frozen source/test hashes match the independently reviewed snapshot.

Actual owned UI in the common service/sidebar window prepares synthetic M4A in
S3-off chat7, retains the11-UTF16 caption, then survives hash-verified source
removal and SIGTERM. Restored File preparation accepts one native queue ID;
another restart has no preparation resurrection. Mail→Telegram retains chat/off.
Screenshots were inspected; strict signatures and raw unsigned built–QA equality
pass. No personal account, microphone or Telegram network was used.
The verified native QA host is macOS27.0.1; actual runtime on the product's
minimum macOS26 is not established by this host run.

Private real Postbox/PostgreSQL/S3 readbacks before/after acceptance pass one test
each: same preparation/local record, exact original bytes/hash, typed metadata,
caption, empty archive-file metadata and absent objects under both local and
conventional S3 keys. Accepted native Audio/FileName attributes match exactly.
The first accepted readback crashed because its private test closure inherited
MainActor onto the Postbox queue; moving only that helper to the existing
nonisolated test pattern fixed it. Raw failed log/crash evidence is retained;
this was not a product-code change or a passed attempt. One initial CUA capture
failure also remains separate from successful subsequent UI observations.

Independent frozen source review reports no concrete defect; worker runtime/UI
is SKIP, observed provider/model/usage unknown, no quorum. Root validates both
worker contracts and all current source hashes. Initial XERJ queries failed
exit2 with no node; after restoring the loopback node, retries exit0 and reference/
engine source signatures are confirmed. Final project refresh/check/query and
reference/engine freshness checks exit0:366 indexed files,335/335 classified code.
New inspectOwned/verifyMetadata passages are confirmed against current source.

Next: WebP/GIF typed resources and explicit voice/codec work, then frozen ordered
source options, Archive and caption normalization. Full Telegram parity and
Account/server delivery remain open. Other services, dossiers, backup/restore and
packaging remain in sequence; the full migration goal stays active.

## Historical source logical-size photo eligibility (c299b72)

Photo admission now follows the selected TelegramSwift source's `NSImage.size`
in points before JPEG generation. Pixel/byte/frame limits still bound decoding.
64×64@144DPI remains its original File;32×32@36DPI can prepare a32px JPEG while
retaining the raw PNG. Different DPI per axis follows logical aspect/40-point
limits. No new schema, dependency, engine recipe or license change is introduced.

Actual TDD RED: eligibility10 tests/six failures; controller one test/ten failures
against the former helper. GREEN:21 focused tests/zero failures.
Final `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0:
**830 XCTest (754 Telegram +76 core), zero failures;32 Python regressions**.
The incremental final gate has no compile warnings; earlier focused compilation
retains three existing warnings.248 upstream t19 teardown diagnostics remain
without test failures. Temporary private native readback tests were removed.

Owned native QA stays in the common service/sidebar/chat window. S3-off chat
prepares high-DPI PNG as354-byte File, then low-DPI PNG as795-byte JPEG with
267-byte original. File/Media switching retains a9-UTF16 caption. After the two
selected synthetic sources are hash-verified and removed, SIGTERM/relaunch
restores File, caption and both representations. Actual native queue accepts
one ID; another restart leaves no preparation. Mail→Telegram retains the chat
and off choice. Actual screenshots were inspected; strict signatures and built–QA
unsigned payload equality pass. No personal account or Telegram network was used.

Real owned Postbox/PostgreSQL/S3 readbacks before/after acceptance each pass one
test: same preparation/two canonical records, encrypted local state, exact267-byte
original/hash,32px JPEG/64-point source, retained mode/caption, empty archive-file
metadata and absent S3 objects under local and conventional keys. These prove the
new eligibility path respects the prohibition on every new S3 copy.

Frozen independent source review finds no new concrete defect in the three-file
delta; root verifies their hashes. Worker runtime is SKIP, observed provider/model
and usage unknown. Two separate read-only research contracts establish the full
remaining GIF/WebP/music/voice and whole-list dependency order in
`telegram-album-migration.md`. Their expected concurrent PhotoEligibility drift
is superseded by this frozen review; raw failed source-path lookup is retained
separately, not promoted to PASS. Research is not type-support or delivery proof.
Final project XERJ refresh/check/query and reference freshness check exit0:
361 indexed files,330/330 code; current helper/tests are source-confirmed.

Next: strict typed source/payload metadata and native GIF/WebP/music/voice pipeline,
then frozen ordered options/state, Archive and caption normalization. The existing
S3 prohibition, immutable archive and raw-original recovery remain intact. Remaining
Telegram action/search/profile/settings/live validation and the later MMail/Aether,
WhatsApp, Teams, Telemost, dossiers, backup/restore and packaging follow the existing
sequence. The full migration goal remains active.

## Historical Telegram Media/File mode (00d68dd)

The existing Telegram preparation menu switches the complete ordered set between
Media and File. Schema8 retains canonical resources; File selects a photo's raw
original and verifies its digest before/after copying to MediaBox. All new picker
selections use ordered preparation, including single files. Mixed sets start in
File, disable grouping in Media and retain caption/placement/spoiler across modes.
Static-photo eligibility leaves GIF/WebP/multiframe and unsupported inputs as
original files. Full reference classification, archive mode and caption trimming
remain open; this is not complete Telegram parity.

The per-chat S3 prohibition from46bf2d9 remains intact: every initial outgoing
resource uses an encrypted local envelope/receipt when disabled. Mode/list edits
are metadata-only; local resources never become S3 resume jobs after re-enabling.
Personal cloud chats default on, groups/channels off. Message versions and existing
archive objects remain retained, and PostgreSQL stores no file payload bytes.

Independent source review identified four concrete P2 defects. Actual regressions
first reproduced mixed Media option refusal and lost detached mode retry, then
final-visual removal leaving invalid Media (14 tests/20 failures), and list/mode
retry lost after rebind (21 tests/28 failures). Fixes preserve media controls for a
mixed set, atomic remaining-list/File normalization, exact old/new mode/order/group
CAS and original-store requests with latest caption/options across rebind and retry.
Restore/send stay blocked until confirmation; cancellation/newer pointers cannot
be overwritten. A separate cancellation-retention regression also passed after
cleanup. Corrected compatibility coverage passes43 tests, including legacy schema6/7.
Raw compile/setup and invalid test-fixture failures remain separate from PASS gates.

Final `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` exit0.
The final full gate passes **827 XCTest (751 Telegram +76 core), zero failures;
32 Python regressions**. The recompiled test target emits three existing warnings
(two weak-reference mutability suggestions and an unreachable catch), plus248
upstream t19 teardown diagnostics without test failures. Earlier incremental
812/820 gates are superseded by this final source snapshot.

Owned native QA verifies off → select PNG+TXT → File/Media/File → caption/options
retained → remove the two selected synthetic sources → SIGTERM. Preparation began
on the preceding built snapshot; final built payload then restores the same two
stable IDs, original179/37-byte payloads and10-UTF16 caption. It repeats mode
switching with retained placement/spoiler, accepts all three native queue IDs,
and stays closed after another restart. Separate real Postbox/S3 readbacks before
and after acceptance pass (one test each): same preparation/three canonical records,
local state, exact payloads, empty archive-file metadata and absent S3 objects
under local and conventional keys. Mail→Telegram retains the chat/off choice.
A second native mixed preparation removes its sole photo and leaves one ready
24-byte document; it was explicitly cancelled. Actual screenshots were inspected.
Strict signatures/raw unsigned built–QA payload equality pass. No personal account,
Keychain or Telegram network was exercised.

Frozen independent source review and two delta reviews close all four findings
with no new concrete defect in the touched route. Root revalidates all19 source/test
hashes; worker runtime is SKIP and observed provider/model/usage remain unknown.
Final project XERJ refresh/check/query exit0:361 indexed files,330/330 code;
reference freshness check exits0 and source reads confirm retrieval. Engine/license
pins and the reference-free build boundary remain unchanged. Private QA/readback
helpers and their temporary test are excluded from publication. Selected-credential
publication audit exits0:366 publishable files/five selected fields, zero matched
files or PR-body matches. Git and hosted-CI publication are recorded separately.

Next: complete upstream whole-list classification/options, archive preparation and
caption normalization, then remaining Telegram action/search/profile/settings and
live-account validation. MMail/Aether, WhatsApp, Teams, Telemost, dossiers, portable
backup/restore and standalone packaging follow in the existing order. Local
preparation collection/portable backup remain unfinished. The sequential goal is active.

## Historical per-chat S3 prohibition (46bf2d9)

The common conversation header exposes **Сохранять файлы в S3**. Personal cloud
chats default on; groups and channels default off. Exact service/account/chat
choices persist encrypted in PostgreSQL. Off prohibits every new S3 admission,
including prepared files, normalized photos, raw originals and video covers.
Outgoing preparation uses encrypted local envelopes and authenticated receipts;
these never join S3 resume, even after re-enabling. Existing objects and append-only
message text remain retained. Queued old copies recheck the resolved chat policy;
a PUT already admitted before disabling may still finish.

Real PostgreSQL/S3/Postbox RED reproduced the preparation bypass, stored-only
recovery validation and group/channel default bypass. Independent review found
that local capture skipped metadata limits; its real regression failed with one
test/seven failures before shared admission validation fixed it. One worker test
fixture was corrected to compare the latest revision after intentional retry.
The final focused gate passes **24 tests (9 Telegram +15 core), zero failures**.
It covers exact restart recovery of all five batch resources, enabled-group S3,
local receipt permissions/symlink/tamper, payload tamper, foreign pointers, invalid
metadata before queue creation, and tagged/untagged old receipt policy checks.

`scripts/dev-db.sh up`, `scripts/test.sh` and `scripts/build-app.sh` exit0.
The full gate passes **784 XCTest (708 Telegram +76 core), zero failures;
32 Python regressions**, no compile warnings, and236 upstream t19 teardown
diagnostics. Current native owned synthetic QA verifies persisted off, file
preparation, source removal, SIGTERM/relaunch, recovered ready preview, synthetic
native acceptance and no preview resurrection after another restart. Real
Postbox/S3 readback before/after acceptance verifies the same preparation/object,
exact56 bytes, `local` state, empty S3 archive metadata and HTTP404 under both
local and conventional S3 keys. Mail→Telegram retains the selected chat and off.
Strict signatures/raw unsigned built–QA payload equality pass. No personal
account or Telegram network was exercised; group/channel defaults are integration
coverage rather than native UI fixtures.

Independent frozen source review plus the five-file fix addendum found no
remaining concrete defect. Root verifies all16 current source/test hashes against
the reviewed snapshot; worker runtime is SKIP, observed model/provider/usage
unknown. Current project XERJ refresh/check/query exit0:358 files,327/327 code;
retrieval is source-confirmed. License/engine pins and the reference-free build
boundary are unchanged. Local preparation collection and portable backup/restore
remain unfinished.

Next: rebase the private exact media/file checkpoint over local preparation
support, then fix its two source-review P2 findings: mixed Media caption/spoiler
controls and detached failed mode-save retry. Its earlier gates describe that
parked snapshot only. The sequential migration goal remains active; Telegram and
the remaining communication/storage/backup/package work are not complete.

## Historical Telegram raw photo originals (8850d55)

Picker photos now retain the raw source separately from the prepared JPEG,
including single selection. The frozen source produces the JPEG; both resources
use one stable item ID and distinct encrypted S3 objects. Schema7 preserves their
records through reorder, restart, cancellation and complete native acceptance.
Schema1–6 remain readable; source-bearing schema6 and incomplete schema7 fail
closed. Legacy JPEG-only photos cannot reconstruct missing originals. Temporary
cleanup covers both resources; immutable archive objects remain retained.

The real original-source regression first failed with schema6 and no original
record, then passed. It now covers exact PNG bytes after deleting the selected
source, same-name/size raw substitution refusal, reorder, authenticated full-set
restoration, later-original failure cleanup and full native receipt acceptance.
Additional regressions cover schema downgrade/alias/scope refusal, derivative
failure, cancellation and detached initial-write lifetime for both stages.
Final scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**765 XCTest (700 Telegram +65 core), zero failures;32 Python regressions**.
The final test log retains226 upstream t19 teardown diagnostics without failures.
The earlier compilation retained two weak-reference mutability warnings; the
incremental final test compile prints no warning. Raw test/setup failures remain
separate from passing gates.

Owned native QA verifies11 selected PNGs, stable-ID context-menu movement across
the10/11 boundary, exact11-ID/order/19-UTF16 caption restoration after SIGTERM,
local queue acceptance and no preparation after the next restart. Root found
that the single-photo picker still entered the old API and changed only that
routing: one photo now uses an ungrouped ordered preparation while preserving
the single-photo preview. On the final payload, single-photo preparation created
two stored archive objects in the isolated schema; exact byte/kind proof is the
separate integration test. Its13-UTF16 caption, spoiler and caption-above options
survive restart, native queue acceptance and another restart without resurrection.
Mail/Telegram switching preserves the selected dialog in the common shell.
Strict signatures and raw unsigned built/QA payload equality pass. No personal
account, Keychain or Telegram network was used. A drag gesture produced no
observed reorder and remains unaccepted; the coordinate context menu passed.

Media/file switching, whole-list eligibility, archive preparation and caption
normalization remain the next album work. The other Telegram action/search/
profile/settings workflows and live-account delivery/sync/reconnection remain
open; MMail/Aether, WhatsApp, Teams, Telemost, backup and packaging follow in the
existing order. This foundation does not complete Telegram or the full goal.
Independent frozen source review found no new concrete correctness defect. Root
revalidated all18 source/lock hashes and both project/reference pins. The raw
worker report required contract normalization; its16 recorded zero-exit reads
are source evidence, while worker tests/build/UI remain SKIP and observed
provider/model/usage remains unknown. Parent test/build/native gates are separate.
Final project XERJ refresh exits0 (354 files,323/323 code); project and reference
freshness checks exit0, and a final query retrieves saveOriginal/restoreOriginal,
confirmed against source. Final selected-credential audit exits0:359 publishable
files, five selected credential fields, zero matched files or PR-body matches.
Git/PR publication is recorded separately. Previous-head d216eab9 CI38130275556 (PR)
and38130272671 (push) both completed successfully; they do not cover this patch.

## Historical Telegram ordered controller and preparation UI (d216eab9)

The existing common Telegram pane now accepts multiple selected files and owns
one ordered upload state machine. Stable item IDs bind reorder/remove/selection,
per-item covers, persistence, restart and the complete native queue receipt.
Schema6 recovery restores the whole preparation; unknown enqueue outcomes remain
non-resendable. Native synthetic QA verified three document selections, reorder,
removal, separate grouping and restart with both remaining IDs and the exact
caption. The actual picker order was preserved; click order is not claimed.

Native synthetic queue QA exposed an account sentinel (-1) converted into a
native PeerId assertion. A real Postbox regression reproduced that crash; the
fix supplies a separate synthetic native author and seeds only the isolated DEBUG
Postbox, preserving the scoped archive account identity. The regression now
passes (1 test, zero failures, exit0). A multi-file header AX label was corrected.
Final scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**760 XCTest (695 Telegram +65 core), zero failures;32 Python regressions**.
Full logs retain224 upstream t19 teardown diagnostics without test failure.
Compile/setup reds and the reproduced native assertion are retained separately.
Independent frozen controller and crash/AX delta source reviews found no new
concrete defects; root revalidated the reviewed source hashes. Workers did not
execute tests/build/UI; observed route/model/usage remains unknown.

Owned native QA now verifies the visual10+1 boundary, context-menu movement of
the11th stable item into the first group, exact11 IDs/order and23-UTF16 caption
restoration, and local native queue acceptance. A second11-image preparation
removed exactly the second-group item, then queued the remaining10. Accepted
preparations stayed closed after restart. The prior crashed preparation restores
uncertain with its two IDs/caption and no send action. Mail/Telegram switching
preserves the selected dialog in the common shell. Strict built/QA signatures and
raw unsigned executable equality pass. No personal account/network was used;
local acceptance does not establish server delivery. Publication is recorded
separately from these gates.

Remaining Telegram work still spans six broad areas: album preparation/send
fidelity; other message/media/special-chat actions; full search filters/navigation;
profiles and chat administration/gallery; settings/sessions and remaining reference
screens; real-account delivery/sync/reconnection acceptance. Current album gaps
include whole-list mode/group eligibility, raw-original mode switching, archive
preparation, caption normalization and native drag/drop gesture acceptance. These
areas are not a task count, percentage or time estimate. The sequential goal stays
active, with the other communication channels following Telegram.

## Historical Telegram native batch provider (b9c6c3d)

Telegram remains in the common Makosh service sidebar/dialog/conversation/dossier
window. Album migration steps1/2 provide ordered schema6 Postbox/S3 preparation
storage and a native batch provider. Every original/cover has a stable item/resource
identity. All originals must match archived SHA256 before and after MediaBox copy.
The full batch uses one native admission transaction and one complete typed-ID
receipt. Grouped sends split10/10/1 at21 items; caption/entity placement follows
verified reference source. Separate sends can add one leading rich-text message.
Every queued ID participates in Account pending-status observation; local queue
acceptance and100% progress never establish delivery.

The picker, controller/recovery protocol and preparation UI still accept one
file and reject schema6. Multi-selection, stable-ID reorder/remove/editor actions,
whole-list mode/group normalization and the reference album screen remain steps3/4
in telegram-album-migration.md. Schema1–5 remain supported. No first-item fallback
or automatic resend is permitted. Reference runtime and live Account/network
sending have not been exercised.

scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**753 XCTest (688 Telegram +65 core), zero failures;32 Python regressions**.
Focused23 batch tests pass. Real encrypted native Postbox tests cover all21 local
IDs and bytes across reopen, mixed photo/covered-video derivatives, later changed
payload, malformed/partial receipts, lost acknowledgement, stale retry and stop
at commit boundary. Existing real PostgreSQL/S3 regressions verify retained
objects, ordered restoration and previous-pointer preservation. Full logs retain
216 upstream t19 teardown diagnostics without test failures. Compile/setup failures
and an earlier actor-isolation crash are retained separately from behavior reds;
the nonisolated queue fault mapping and final gates pass.

Independent frozen review identified two P2s: unsupported peer namespaces reached
preparation, and reply quote/todo/thread attributes could receive acknowledgement.
Root reproduced and fixed both. A related real-Postbox regression also reproduced
an original reply fingerprint paired with a forged thread; admission now compares
freshly derived thread metadata. A third P2, choosing the first rather than native last media in a migrated
quote, was reproduced with1 test/2 failures and fixed. Empty and multi-media
migrated quote fixtures now pass; live multi-media reachability stays unknown.
All focused regression cases pass. Final bounded delta review found no new
findings; root revalidated16 source/lock hashes,8 helper hashes and both pins.
Worker tests/UI were not run; observed provider/model/usage remains unknown.
Some worker read records retain command descriptions, so they are source evidence
rather than independent executable gates.

Owned synthetic native QA verifies existing single-photo caption, spoiler and
caption-above restoration after restart. On the final build, the prior preparation
stays closed after restart and Mail/Telegram switching preserves the common shell.
Strict built/QA signatures and raw unsigned executable equality pass. QA uses
isolated Postbox/PostgreSQL/S3, without personal accounts, Keychain or Telegram
network. Batch picker/UI and live delivery are still unverified.

Six broad Telegram areas remain: albums/multi-file preparation and sending;
remaining message/media/special-chat actions; full search filters/navigation;
profiles/chat administration/gallery; settings/sessions and reference UI gaps;
real-account delivery/sync/reconnection acceptance. These are work areas, not an
exact task count or percentage estimate. MMail/Aether, WhatsApp, Teams, Telemost,
backups and standalone packaging follow Telegram. The sequential goal stays active.
Previous ffe2196 PR38125833903 and push38125829691 CI are terminal success for
that exact SHA; publication/current-head CI is recorded separately.

## Historical inserted images in the Telegram video cover editor (246f446)

Telegram remains inside the common Makosh service sidebar/dialog/conversation/
dossier window. The main cover editor now inserts an immutable oriented image
from a file or explicit paste, moves it, exposes eight resize handles and Shift
geometry, changes layer order, copies/deletes it and supports whole-action undo/
redo. Multi-file paste is atomic and has one undo step. Images retain fitted-point
rectangles and captured source multipliers, following the inspected reference.
They render above base/paint and before final crop directly into bounded320px
JPEG, including unrotated mirrored output. Original video remains unchanged;
final cover bytes and previous cover versions use the existing encrypted S3 path.
Layer editing state is ephemeral; no storage or credential schema changes.

scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**720 XCTest (657 Telegram +63 core), zero failures;32 Python regressions**.
Focused41 tests pass. Meaningful image behavior red8tests/91failures and batch
red11/2 preceded implementation; missing-API compile reds are separate. Final
logs retain160 upstream t19 teardown diagnostics without test failure.

Independent frozen source review found two P2s. Root reproduced both natively:
drag Undo retained the new selection and a handle double-click reset crop.
Capture-before-selection and shared actual handle hit regions fix them. Native
rechecks pass for all eight stationary handle double-clicks, unselected-layer
drag/Undo, Cmd+C/V, Delete/Cmd+Z/Shift+Cmd+Z, pointer resize/Undo and drawing Cancel.
The insertion Menu was absent from AX; matching the existing borderless style
restores its visible/actionable menu. Strict built/QA signatures and unsigned
payload equality pass. Root revalidated the final review's13 hashes and both pins;
the worker ran no tests/UI and observed provider/model/usage stays unknown.

Prepared and accepted Postbox/S3 readbacks both exit0:320×192 JPEG, four known
quadrant colors plus two white border samples, exact caption, unchanged original
video and matching retained-cover digest/receipt. Restart restores preparation;
after local synthetic acceptance, another restart keeps it closed. QA uses only
isolated synthetic storage, without personal accounts, Keychain or Telegram
network. Native release-only Shift, interrupted drag/import and clipped hit-test
edge cases remain unexecuted; reference runtime was not run.

Deliberate differences include deterministic center, bounded immutable decode,
16 live layers/64 history steps/40M retained decoded pixels, no stale redo and
retaining overlays in unrotated-mirror export. Captured reference point geometry
can diverge between preview/export after base refitting; see reference-interface.md.
Complete Telegram/album/menu and live Account/network parity, MMail/Aether,
WhatsApp, Teams, Telemost, backups and standalone packaging remain open. The
sequential goal stays active. Parent edf12db PR38122489641 and push38122486132
CI are terminal success for that exact SHA. New-head evidence stays private.

## Historical fitted initial crop and source-pixel precision (edf12db)

The editor now initializes its selection once from the actual fitted canvas:
floor(min(width,height)) square, then retained preset/Original aspect correction
and centering. This closes the documented1001×601→552×332 initial-width gap.
Returning from the drawing sheet preserves a moved selection, verified natively.
Export independently rounds transformed source-pixel x/y/width/height, clips
right/bottom to source bounds like CoreGraphics cropping, and rejects an axis
rounded to zero. It no longer expands fractional selections with floor/ceil.
Rendering still draws directly into the bounded320px cover, including paint;
original image/video and stored prior versions remain unchanged.

scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**709 XCTest (646 Telegram +63 core), zero failures;32 Python regressions**.
Focused30 crop/transform/painting/brush tests pass. Pixel behavior red7tests/
28failures covers eight orientations, wrong boundary color, zero pixel axes
and half-pixel edge intersection. Initial-selection behavior red13/6 precedes
implementation; missing-API compile red is separate. Full logs retain160
upstream t19 teardown diagnostics without test failure.

Owned native QA uses a1001×601 synthetic quadrant image, moves its initial
selection, opens/cancels drawing, restores its position and saves. Restart
restores the cover and exact caption. Prepared and accepted Postbox/S3 readbacks
both exit0:320×192 JPEG, four known colors, unchanged original video, retained
cover digest and matching receipt. Strict signatures/unsigned payload match pass.
The same isolated synthetic Postbox/PostgreSQL/S3 is used; personal accounts,
Keychain and Telegram network are excluded. No schema/credential format changes.

The reference still has conditional aspect/minimum feedback and callback timing
differences described in reference-interface.md; its native runtime was not
executed. Initial fitting and source-pixel rounding are now implemented.
Inserted-image overlays, complete Telegram/album/menu parity, live Account/
network delivery, MMail/Aether, WhatsApp, Teams, Telemost, backups and standalone
packaging remain open. The full sequential goal stays active. Parent6bd97b6
PR38121793369 and push38121790902 CI are terminal success for that exact SHA.
Current-source index/review/publication evidence is retained privately.

## Historical video-cover crop fitting and pointer gestures (6bd97b6)

Telegram remains in Makosh's common service sidebar/dialog/conversation/dossier
window. Crop and drawing now share the reference's shrink-only two-pass fitting:
reduce width then height, ceil the orthogonal extent, and reserve8pt padding.
Body movement ceils each pointer position before subtraction. Four20pt L-shaped
corner handles use the absolute ceiled canvas pointer and width-driven aspect
resize. The fitted-view minimum is40pt wide, constrained by image bounds and
the opposite anchor. Double-click inside the selection, including its corners,
and the accessible action select the largest centered preset/original region.
Native portrait QA exposed zero-distance corner drag resizing on mouse-down
(50%→45%) and swallowing double-click (40% instead of100%). A1pt movement
threshold fixes both; top/bottom stationary clicks, double-click and actual
minimum-size dragging pass in the rebuilt native app.

scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0 after the
gesture fix: **704 XCTest (641 Telegram +63 core), zero failures;32 Python
regressions**. Focused25 crop/transform/painting/brush tests passed before that
UI-only fix and are included in the final full suite. Meaningful geometry reds
(9 tests/13 failures) and pointer reds (11/3) preceded implementation; missing-API
compile failures are separate. Logs retain160 upstream t19 teardown diagnostics.

Owned native QA verifies landscape minimum/movement/outside-double-click,
corner maximum, portrait top/bottom clicks and Cancel. Prepared and accepted
Postbox/S3 readbacks exit0:320×160 JPEG, four known quadrant colors, exact caption,
unchanged original video, retained cover and matching receipt. Restart restores
the prepared cover and does not reopen accepted preparation. These readbacks
preceded the corner movement-threshold fix; renderer/storage were unchanged.
Strict built/QA signatures and unsigned executable equality pass. QA uses only
isolated synthetic Postbox/PostgreSQL/S3; live Account/network delivery is open.

Frozen source research/review confirmed the reference pin and file hashes;
root reproduced and corrected the portrait runtime frontier. Provider/model/
usage metadata remains unknown. Makosh deliberately keeps bounded anchored
aspect geometry; upstream's conditional feedback and40×40 intermediate minimum
can produce different transient bounds. Initial fitted-point precision and final
source-pixel rounding remain explicit gaps, along with inserted-image editing.
See reference-interface.md and telegram.md. Parent6ccd673 PR38120760210 and
push38120757388 CI are terminal success for that exact SHA. Final current-source
XERJ refresh and publication evidence are retained privately.

Complete Telegram parity, albums, MMail/Aether, WhatsApp, Teams, Telemost,
backups and standalone packaging remain open. The full sequential migration
goal stays active; the next editor work is inserted-image overlays and the
remaining fitted/source-pixel precision differences.

## Historical video-cover drawing, arrows, eraser and stroke history (6ccd673)

Telegram stays inside the common Makosh service sidebar/dialog/conversation/
dossier window. The cover editor now opens a separate drawing sheet over the
full transformed source without enlarging small images, following the selected TelegramSwift workflow. Cancel
leaves accepted paint unchanged; Done accepts a value copy. Reopening keeps
accepted strokes undoable and clears redo. Undo/redo operate on whole strokes;
a new stroke clears redo. Brush/arrow toggle, eraser, Cmd+Z/Shift+Cmd+Z, physical
A/E/L, Cmd+D, Return and Escape are available. A small sheet-local AppKit first
responder fixes bare tool-key delivery observed failing with SwiftUI alone;
it has no global event monitor and detaches on close.

The continuous nine-stop reference palette keeps color/weight preferences.
Initial weight0.22 produces5pt; pressing the strip produces4pt, and pulling
up increases thickness to18pt. Paint keeps original-oriented normalized points,
capture canvas dimensions and width. Export scales width by mean(sx,sy), applies
round caps/joins, first-to-last arrows with the strict per-axis length threshold,
and clear blending within a separate paint layer. Erasing reveals original
pixels. Drawing remains registered through later rotation/mirror/crop. Final
paint renders directly in the bounded320px output; no extra full-size paint or
transformed bitmap is allocated. Original image/video and prior S3 objects
remain unchanged. No archive schema or credential/config format changed.

scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**698 XCTest (635 Telegram +63 core), zero failures;32 Python regressions**.
Focused10 drawing/brush regressions pass. Meaningful behavior reds cover paint/
history/geometry (6 tests/37 failures), brush gestures (2/10), and physical tool
keys (1/7). Review behavior red (10 tests/5 failures) covers Retina half-point precision
and computed-width overflow rejection. Missing-API compilation failures are
retained separately. The full
log retains160 upstream t19 teardown diagnostics without test failure.

Owned native CUA verifies palette/18pt black brush, actual stroke/arrow/eraser,
Cmd+Z/Shift+Cmd+Z, A/E/L, Return/Escape, save/reopen/cancel, rotation of accepted
paint and clearing redo after a new stroke. Restart restores the final cover
and exact caption. Read-only Postbox/S3 checks for prepared and accepted states
both exit0:320×160 JPEG, four independently known color samples plus two black
stroke samples, unchanged original video, retained cover digest and matching
receipt. After synthetic acceptance, restart does not reopen the preparation.
Strict built/QA signatures and unsigned executable equality pass. This uses
isolated synthetic Postbox/PostgreSQL/S3, with no personal account, Keychain,
Telegram network or server-delivery claim.

Reference research checked11 frozen file hashes and exact pin with fresh XERJ;
root confirmed current source. Final review identified five issues: Cmd+D,
small-image fitting, computed-width overflow, Retina knob precision and
conditional near-white outline; all were corrected and rechecked privately;
root owns all runtime gates. Provider/model/usage metadata remains unknown.
Parent e219c21 PR38119331552 and push38119329063 CI are terminal success for
that exact SHA. New-head publication/CI/index evidence is recorded privately.
Remaining editor gaps include fitted-point rounding/40pt constraint, double-click
full bounds and inserted-image editing. Complete Telegram parity, albums,
MMail/Aether, WhatsApp, Teams, Telemost, backups and standalone packaging remain
open; the full sequential migration goal stays active.

## Historical original cover source, rotation and horizontal mirror (e219c21)

Telegram remains in the shared service sidebar/dialog/conversation/dossier
window. The existing video-cover editor now retains original image bytes and
full EXIF-oriented geometry, with20MiB/8192px-per-axis/40M-pixel limits. The
normal photo attachment path is unchanged. Apply authenticates the displayed
snapshot on the same source read, then renders rotation/mirror/crop directly
into the bounded320px quality1.0 JPEG. Original video and first-frame thumbnail
remain separate, and final cover bytes continue through encrypted S3.

Rotate (Cmd+R) and Mirror sit between Cancel and Done. Preview fits the rotated
extents; crop movement/resize and export use transformed coordinates. Source
research confirms CCW quarter-turn state followed by horizontal output mirror.
The reference retains CCW crop transport while mirrored, although the visible
rotation then appears CW; this upstream behavior and operation-order crop paths
are explicitly regression-covered. No outer GPLv2 UI/assets are copied.

Source research also corrected two misleading frontier claims: crop has four
corners; eight handles belong to inserted images.200×200.aspectFitted(canvas)
can enlarge to the canvas's smaller dimension, so it is not a literal200pt cap.
Existing normalized initialization already matches the main reference formula.
Remaining editor work includes fitted-point rounding/40pt constraint, double-click
full bounds, drawing/eraser/undo and inserted-image editing.

scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**688 XCTest (625 Telegram +63 core), zero failures;32 Python regressions**.
Focused14 tests pass. The full log retains160 upstream t19 teardown diagnostics
without test failure. Original-source behavior red (2 tests/5 failures) and
corrected transform behavior red (4 tests/17 failures) precede implementation.
Missing-API/init compilation and small-JPEG/color-tolerance fixture failures are
retained separately; corrected focused/full checks pass.

Owned native CUA QA verifies Cmd+R, horizontal mirror, transformed preview/crop,
drag to an independently known yellow quadrant, Done, restart restoration and
local synthetic acceptance. Read-only Postbox/S3 verification confirms160×320
JPEG with four yellow samples, unchanged original video, exact caption, retained
cover and accepted receipt. Strict built/QA signatures and unsigned payload match
pass. No personal account, Keychain, Telegram network or server delivery is used.
Independent source research/review checked frozen hashes; final review
found no concrete issue in its9-file scope, but did not execute tests or UI.
Provider/model/usage runtime metadata remains unknown; root owns all gates.

Parent3c88a7f PR38118310901 and push38118307892 CI are terminal success for that
exact SHA, verified directly. New-head CI/publication/index evidence is recorded
privately. Complete Telegram parity, albums, MMail/Aether, WhatsApp, Teams,
Telemost, backups and standalone packaging remain open. The full sequential
migration goal remains active.

## Historical video cover picker, crop, replacement and removal (3c88a7f)

Telegram stays inside the common service-sidebar/dialog/conversation/dossier
window. The existing preparation menu now exposes Add/Change/Remove cover,
following PreviewSenderController.swift:318–382. A single-image NSOpenPanel
opens an owned snapshot in a nested crop editor with Cancel/Done, fixed aspect,
move, four corner resize handles, arrow keys and accessibility size adjustment.
SelectionRectView.swift:53–112 chooses an exact matching preset, otherwise
Original (the image's aspect); it does not approximate a nonstandard video ratio.
The applied JPEG is bounded to 320px and quality1.0; original video and ordinary
first-frame thumbnail remain separate. Outer GPLv2 UI/assets are not copied.

Account-bound serialized replacement freezes the cover inode before suspension,
checks the preparation/revision and reuses the committed object after lost ACK.
Previous encrypted S3 cover versions remain retained after change/removal.
Picker/crop ownership and digest verification on the same source read prevent
applying a replacement of the displayed snapshot. Editing or unconfirmed cover
persistence blocks sending; explicit retry confirms cover plus visible caption
and options. Late results cannot alter a rebound account/window. Native QA found
a restored-ID/caption-generation mismatch that made cover menu actions no-ops;
a behavior red reproduced it and the durable-ID/editor guards now admit them.
Another behavior red covers resaving a previously failed caption with the cover.

scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**684 XCTest (621 Telegram +63 core), zero failures;32 Python regressions**.
Final focused33 tests pass. The full log retains160 upstream t19 teardown
diagnostics without test failure. Session, geometry, snapshot and controller
behavior reds precede their implementations. Missing-API/CGFloat/catch-shadow
compilation errors and readback fixture setup/dimension errors are recorded
separately from behavior evidence. Final gates and corrected readbacks pass.

Owned native CUA QA exercises image selection, crop adjustment, Cancel/Done,
replacement/removal, restored preparations and local synthetic acceptance.
Readback verifies unchanged original video, exact caption, accepted receipt and
all three retained S3 cover versions. Restart restores the selected cover or its
removal and does not reopen an accepted preparation. Strict built/QA signatures
and unsigned payload match pass. Personal accounts, Keychain, Telegram network
and server delivery remain untested. Parent 5b13eae push38116708250 and
PR38116711546 CI are terminal success for that exact SHA, verified directly.

This is basic cover editing, not complete reference-editor parity. Rotation,
mirror and drawing/undo are still open at this historical stage. Later source
research below corrects the earlier eight-handle/literal200pt frontier claims. Selection currently uses photo normalization (JPEG at most2560px,
quality0.85), rather than the reference editor's full original source. Albums,
complete Telegram parity, MMail/Aether, WhatsApp, Teams, Telemost, backups and
standalone packaging remain open; the sequential goal stays active. Final
index/review/publication evidence stays in the private root report.

## Historical custom video cover storage, transport and restoration (5b13eae)

Telegram remains in the common service-sidebar/dialog/conversation/dossier
window. The cover groundwork follows SenderController.swift:130–165,374–382
and ChatInteractiveContentView.swift:758–770: a separate bounded JPEG/native
videoCover preserves the ordinary first-frame thumbnail and disables autoplay.
Own IO crops oriented pixels, scales to at most320px, encodes JPEG quality1.0
without source metadata, and verifies owned stage, dimensions and SHA256.
No outer GPLv2 UI/assets or reference build dependency is introduced.

Original video and cover use separate encrypted S3 objects with PostgreSQL
metadata. Pending schema5 retains the cover through caption/options, submission
and atomic acceptance; schema1–4 without a cover remains readable. Older builds
reject schema5 rather than silently dropping its cover. Authenticated restoration
recreates both owned stages. Cancellation releases stages, not archived objects;
previous cover objects remain retained. MediaBox keeps three distinct resources
and reads back the original and both exact JPEGs before enqueue. Strict native
receipt validation rejects missing, altered, foreign or noncanonical covers.

scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**673 XCTest (610 Telegram +63 core), zero failures;32 Python regressions**.
Final focused70 tests pass. The full log retains158 upstream t19 teardown
diagnostics without test failure. Behavior reds cover crop/orientation/digest,
mapping, schema, S3 restore, session preservation, native MediaBox/receipt and
controller restoration. Missing-API compilation, a draft fixture forced-unwrap
trap, a receipt fixture's reused native media identity and two QA seed setup
failures are recorded separately; corrected fixtures and final gates pass.

Owned native CUA QA restores a synthetic covered preparation in the existing
sheet, shows the green portrait cover instead of the video's first frame, hides
it under spoiler, and preserves edited caption and cover after restart. Local
synthetic acceptance closes the sheet; read-only Postbox/S3 readback verifies
the accepted receipt and retained cover bytes. A second restart does not reopen
the accepted preparation. Strict built/QA signatures and unsigned payload match
pass. This uses isolated Postbox/PostgreSQL and synthetic local S3 fixtures.
Personal accounts, Keychain, Telegram network and server delivery are untested.

The Upload/Change/Remove cover menu, picker/crop editor and serialized replacement
operation are not yet exposed. This is storage/transport/restoration groundwork,
not complete custom-cover workflow parity. Parent a812fb3 push38115191311 and
PR38115193331 CI are terminal success for that exact SHA, verified directly.
Current index/review/publication evidence stays in the private root report.
Albums, complete Telegram parity, MMail/Aether, WhatsApp, Teams, Telemost,
backups and standalone packaging remain open; the sequential goal stays active.

## Historical muted looping video preparation preview (a812fb3)

Telegram remains inside the common service/sidebar/dialog/conversation/dossier
window. Video preparation now uses the reference's muted loop in its visible
key window, retaining the existing caption, spoiler, placement and send controls.
Reference evidence: MediaPreviewRowItem.swift:46–55,212 and
ChatInteractiveContentView.swift:26–39,566–577,758–770,1136–1174. The original
video is not transcoded. Own SwiftUI/AppKit integration uses the existing native
AVPlayer engine; no outer GPLv2 source/assets or reference build dependency is added.

A dedicated preparation controller validates metadata and the owned immutable
stage before opening, supplies the container MIME hint for extensionless bytes,
and rechecks its inode/stat snapshot after native readiness. Playback is muted,
external playback disabled, and a native AVPlayerView observes its actual window's
key/occlusion state. It pauses when invisible/inactive. The upload owner detaches
the decoder before submission, stage release or rebinding; spoiler and sheet
closure also stop it. Player identity and generation guards reject stale view
callbacks and late loading results. A 30-second loading deadline and visible
safe errors preserve the first-frame fallback. Received-media end behavior keeps
its previous default. This slice changes no persistence schema, archive retention
or encrypted S3 format.

Four new regressions exercise actual AVPlayer with generated MOV/MP4: owned-stage
URL, silent playback/visibility, repeated loops, replacement and stale callbacks,
spoiler/dismiss/rebind/send ordering before unlink/submit, invalid metadata,
removed stage and immediate cancellation. Focused4 tests pass. Initial missing
API compilation and a 4-test/5-failure behavior red are recorded separately;
AppKit build initially failed on notification-name qualification and was fixed.
scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**658 XCTest (595 Telegram +63 core), zero failures;32 Python regressions**.
The full log retains152 upstream t19 teardown diagnostics without test failure.

Owned native CUA QA uses an animated portrait MOV in the existing preparation
sheet. The final native video surface has a labelled accessibility image;
spoiler removes both video and poster from accessibility, and Escape returns the
ordinary draft. Restart preserved that draft without restoring cancelled media.
Strict built/QA signatures and unsigned payload match pass. UI actions and visual
observations are recorded in the private root report; repeat/visibility and
before-release ordering are proven by real-player regressions, not screenshot
inference. Native window inactive/occlusion notifications and deterministic held
in-flight cancellation have not been separately exercised through CUA.

Parent dde0e6d push38114425140 and PR38114428835 CI are terminal success for the
exact SHA, verified by direct readback. Current index/review/publication outcomes
are in this slice's private root report. Custom cover, multiple selection/albums,
complete Telegram visual/workflow parity and full Account/network/server delivery
remain open. MMail/Aether, WhatsApp, Teams, Telemost, backups and standalone
packaging still follow; the full sequential migration goal remains active.

## Historical outgoing video JPEG and verified MediaBox preparation (dde0e6d)

The reference's first-frame JPEG now accompanies ordinary video in one native
previewRepresentation: preferred transform, at most320px and quality0.3. The
original video remains byte-for-byte unchanged in the archive. A separate local
resource carries the derivative, with bounded dimensions/size and canonical
flags. Photo/file mappings reject a video thumbnail; video mapping requires one.
No reference folder, generated-engine, PostgreSQL schema or S3 format change is
needed: recovery regenerates this derivative from the authenticated original.

Production and explicit synthetic providers share MediaBox preparation. Both
resources have keep leases; a first readback on the native FIFO data queue runs
after both writes and verifies complete original and exact JPEG bytes before
caption/reply validation or enqueue. Void writes alone are not an acknowledgement;
incomplete/wrong data reports known failure. Stop cancels decoding and observations; guarded late callbacks
cannot publish readiness. The atomic receipt requires the same unique thumbnail
resource, size, dimensions and every representation flag. Native equality omits
several of these fields and is deliberately insufficient.

Real encrypted Postbox/MediaBox tests carry MP4/MOV, JPEG and exact native
representations through the shared enqueue core and reopen. Refusal coverage
includes missing/extra/changed/secret/noncanonical thumbnails and same-size
wrong cached bytes. Immediate cancellation suppresses readiness and retains the
owned stage; deterministic held in-flight decoding/readback cancellation remains
unverified. Full Account/network/server acceptance remains unverified.

scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**654 XCTest (591 Telegram +63 core), zero failures;32 Python regressions**.
Focused93 XCTest and final12 transport regressions pass. Full logs retain152 upstream t19 teardown diagnostics
without a test failure/trap. Behavior reds: JPEG2tests/1failure, mapping1/2,
receipt1/16, MediaBox/cache3/4, synthetic video1/2 and real write failure1/2. Missing-API and fixture
compilation errors are separate. The first MediaBox implementation trapped on
a MainActor-inherited map callback; constructing that pure map outside MainActor
fixed the reproduced executor failure, and the real integration then passed.
Review also exposed ignored incomplete snapshots and a metadata test short-circuit
caused by its missing thumbnail. The failure-path regression reproduced the
first issue, then passed after FIFO single-snapshot readback; metadata tests now
provide a valid thumbnail so their existing guards remain observable.

Owned native CUA QA in the common service/sidebar/dialog window verified MOV
preparation and local synthetic queue acceptance with the shared MediaBox path;
caption cleared after acceptance. Strict built/QA signatures and unsigned payload
match pass. Personal accounts, Keychain and Telegram network were not used.
Final review/index/publication outcomes are recorded in this slice's private
root report. Parent dc20186 hosted push38113225482 and PR38113228172 are both
terminal success for the exact SHA, verified by direct readback.

Next transfer playback, custom cover and albums, then remaining Telegram
workflows. MMail/Aether, WhatsApp, Teams, Telemost, backups and standalone
packaging remain open; the full sequential migration goal stays active.

## Historical combined photo/video picker and first-frame preview (dc20186)

Telegram stays in the shared service-sidebar/dialog/conversation/dossier window.
The attachment menu now follows the reference's Photo or Video choice, with a
separate File choice. MP4/MOV open a video preview with a transformed, bounded
first frame; PNG still follows photo normalization, and MP4 selected as File
stays a document. Placement, spoiler and one-shot send actions now include video.
Playback, custom cover and albums are still open.

Recipe9 adds a local entry point sharing the production enqueue transaction
wrapper and native message core. Production media transformation and the lazy
clock read are preserved. Regeneration changed only EnqueueMessage.swift plus
its preparation record; exact input/output and reverse-substitution body hashes
are checked. Real encrypted Postbox/MediaBox tests carry original MP4/MOV bytes
through native message construction, preserve rich caption/options and an atomic
receipt across reopen, and reject a second admission of an accepted preparation.
No Account or network managers are constructed by those tests.

Native CUA QA on the owned synthetic app verified MOV/MP4 first frames, portrait
orientation, spoiler mask/accessibility, edited caption/placement/spoiler after
restart, one-shot synthetic ACK, Escape without submission, photo/file cancel,
Mail→Telegram and restart preserving the ordinary draft without resurrection.
The UI fixture still constructs explicitly synthetic StoreMessage records;
shared native construction is verified separately. Strict built/QA signatures
and unsigned executable payload match pass. No personal accounts, Keychain or
Telegram network/server actions were used.

Focused23 XCTest pass. Final scripts/dev-db.sh up, scripts/test.sh and
scripts/build-app.sh exit0: **648 XCTest (585 Telegram +63 core), zero failures;
32 Python regressions**. Logs retain146 upstream t19 teardown diagnostics without
a test failure/trap. Poster runtime red was3 tests/1 failure; synthetic video
receipt/options red was1 test/2 failures. Missing-API/actor-isolation compilation,
a synthetic marker incorrectly converted to PeerId, and a QA-generator missing
XCTest import are recorded separately from behavior failures. The fixture
conversion was fixed without weakening native assertions.

Final review/index/publication outcomes are recorded with this slice's private
root verification report. Parent9a6a228 hosted push38111857277 and PR38111860659
are both terminal success, read back for the exact SHA.

Next transfer native JPEG thumbnails/MediaBox, playback, custom cover and albums,
then remaining Telegram workflows. Full Account enqueue/server acceptance and
visual parity remain unverified. MMail/Aether, WhatsApp, Teams, Telemost, backups
and standalone packaging remain open; the full sequential migration goal stays
active. Archive retention, encrypted S3 format and PostgreSQL schema are unchanged.

## Historical ordinary video groundwork (9a6a228)

Published one-shot photo work is c9ed40c on PR1. Hosted PR38110295928 and
push38110293029 are both terminal success for that exact SHA, verified by direct
readback. This slice adds verified video groundwork, still unexposed in the picker.
Publication/new-head hosted CI outcomes are recorded in the private root report.

Owned video staging preserves original MP4/MOV bytes and original name. A
restricted AVFoundation probe records transformed dimensions, audio presence
and canonical Float32-round-tripped duration; extensionless private stages use
an explicit MIME hint. Cancellation and inode/stat checks reject missing or
changed copies. Schema4 freezes typed video metadata and inCollage separately
from final message grouping. File/photo writes remain schema3; legacy1–3 files
named.mp4 stay ordinary files. Malformed/cross-kind metadata fails closed.

Encrypted Postbox preserves video metadata through edits, submission and
terminal markers. Real PostgreSQL/S3 restore authenticates original bytes and
re-probes dimensions/duration/audio against the frozen descriptor; inCollage is
preserved. Same-preparation retries cannot change it, and cancellation retains
archived bytes. Native media mapping matches the reference's Video flags,
filename/MIME, non-MP4 hint and conditional Animated choice. A same-transaction
receipt requires one exact queued video/resource before accepting its marker.
Controller restore now admits matching owned videos, retains rich input/options,
and refuses metadata substitution or resend of unknown submissions; internal
placement/spoiler/one-shot support is covered without exposing video controls.

Runtime regressions were observed before fixes: schema3tests/4failures,
stage8/2, S3restore1/10, mapping4/3, Postboxsession1/1, receipt1/10 and
controller1/17. Missing-API, actor-isolation and fixture/registration errors are
recorded separately. Final focused53 tests pass. scripts/dev-db.sh up,
scripts/test.sh and scripts/build-app.sh exit0: **643 XCTest (580 Telegram +63
core), zero failures;30 Python regressions**. Logs retain138 upstream t19
teardown diagnostics without test failure/trap. Final XERJ refresh/check exit0:
312files,282/282 code; scoped queries were confirmed against source. Final
read-only review found no confirmed actionable issue across32 frozen files;
root rechecked all SHA256/bytes and36 raw check records. The launcher failure
exit127 and successful Python-selected retry remain separate evidence.
Root owns runtime gates; worker runtime/build/UI are SKIP.

Video UI and full engine enqueue/server acceptance are not verified by these
StoreMessage/adapter/controller fixtures. Next transfer the combined photo/video
picker, poster/playback/cover and preview actions inside the common window;
then lifecycle/native QA, album preparation and remaining Telegram workflows.
MMail/Aether, WhatsApp, Teams, Telemost, backups and standalone packaging remain
open. The full sequential migration goal stays active.

## Historical one-shot photo Send as Spoiler

Telegram remains inside the common service-sidebar/dialog/conversation window.
The photo send control now offers Send as Spoiler on secondary/held click;
ordinary primary click still sends with the preview's current choice. The
one-shot command follows PreviewSenderController's `asSpoiler ?? state.isSpoiler`
behavior: it freezes true for that submission without changing the preview
toggle. Captured preparation/revision, readiness and caption validation reject
stale menus, ordinary files and started/uncertain submissions.

The existing submission marker, provider and acceptance storage-only retry carry
the same frozen rich input, placement and true spoiler flag. An unconfirmed
marker never dispatches or automatically retries the send. Pending schema3,
PostgreSQL/S3 formats, engine pins/recipe8 and archive retention are unchanged.

Missing-API compilation is recorded separately from runtime red: four tests,
22 failed assertions before implementation. Focused green:21 tests. Final
scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit0:
**623 XCTest (560 Telegram +63 core), zero failures;30 Python regressions**.
Logs retain134 upstream t19 teardown diagnostics without a test failure/trap.
Read-only source review covers4 changed and8 supporting files; all12 SHA256/bytes
match before/after and root verification, with no source findings. Worker
runtime gates are SKIP; observed provider/model/usage remain unknown.

Owned native QA confirms right-click and800ms held-click menus, one-shot local
synthetic queue acknowledgement, ordinary primary-click submission, Escape
without submission, file exclusion, photo/file cancellation, Mail→Telegram and
restart preserving the ordinary draft without resurrecting the cancelled photo.
Strict deep built/QA signatures and unsigned executable payload match pass.
QA uses only owned encrypted synthetic Postbox and isolated PostgreSQL/S3;
personal accounts, Keychain and Telegram network/server actions are excluded.
Native fault injection and live Telegram acceptance remain unverified.

Prior f511626 hosted PR38109541663 and push38109539048 are terminal success.
Final XERJ refresh exits0 (305 files,275/275 code, zero junk); project/reference/
engine freshness checks and scoped queries pass with source-confirmed hits.
Publication audit checks310 publishable files and the PR body against5 credential
fields with zero matches. Publication/new-head CI outcomes are recorded separately
in the root report. Next Telegram work includes video/album preparation and the
remaining reference send/media options; animated dust, autoload, specialized
renderers, other workflows, live-account acceptance, then MMail/Aether,
WhatsApp, Teams, Telemost, backups and standalone packaging remain open.
The full sequential migration goal stays active.

## Historical outgoing photo media spoilers

Telegram remains in the common Makosh service-sidebar/dialog/conversation window.
Photo preparation now offers Hide with Spoiler / Disable Spoiler through native
photo actions and the whole-header context menu. The preview is masked and its
image is hidden from accessibility while enabled. Ordinary files have neither
photo option. Rich input, selection, placement and spoiler stay independent;
stale menus and started/uncertain submissions cannot change the choice.

Submission freezes all content/options together. Pending JSON writes schema3
with an explicit mediaSpoiler Bool; schema1/2 without it restore false, while
legacy true claims, missing new fields, future schemas and spoiler-on-file fail
closed. Native enqueue carries exactly one MediaSpoilerMessageAttribute when
requested. Admission and same-transaction receipt validate the choice/count;
accepted/cancelled records preserve it. PostgreSQL schema, encrypted S3 format,
engine pins/recipe8 and archive retention are unchanged.

Read-only review found that rebinding during the first write could lose newer
input/options. Three runtime regressions reproduced initial-write and ready-state
loss, plus missing detached-write failure reporting. Detachment now freezes the
latest tuple on the original store; completion consumes the initial snapshot
before stale-binding guards. Failed writes have an inline storage-only retry;
restoring the same preparation is blocked while its update is unconfirmed.
A second review regression held file export until a detached save completed:
the stale loaded draft was still admitted (one test, three failures). Recovery
now captures an epoch before load; reset and detached write start/completion
invalidate older snapshots even after pending markers are cleared. A rejected
export is discarded, and explicit recovery reloads the current rich input/options.
Cancellation retains its separate tombstone path. This cannot guarantee unsaved
changes across process death during a failed storage write.

Final scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh results are
recorded in the local root verification report. Full tests after the review fix
exit0: **619 XCTest (556 Telegram +63 core), zero failures; 30 Python regressions**.
The log retains134 upstream t19 teardown diagnostics without a test failure/trap.
Initial schema red:1 test/7 failures; spoiler runtime red:4/11; recovery runtime
red:23/20; rebind red:1/4; detached retry red:2/8; ready rebind red:1/3;
stale restore red:1/3. Focused epoch green:23 tests. Missing-API,
test-conformance and duplicate-parameter compile failures are separate evidence.
A new test initially trapped because its inline Postbox closure inherited
MainActor; the crash frames confirmed the cause, and a file-level helper fixed
it before the runtime red. No engine assertions were weakened.

Real encrypted Postbox tests cover exact native counts/admission/reopen. Real
PostgreSQL/S3 tests restore normalized photo bytes, rich caption and both options,
and retain the immutable archive on cancellation. Owned native AX/screenshots
verify the old missing menu, enable/disable through both menus, masked preview,
independence after input/placement changes, restart restoration, synthetic queue
acknowledgement, file exclusion, reset/cancel and Mail→Telegram. QA uses only owned
encrypted synthetic Postbox and isolated PostgreSQL/S3, without personal accounts,
Keychain or Telegram network/server operations. Detached failure presentation has
controller/source coverage; native failure injection was not performed. Server
acceptance and exhaustive visual parity remain unverified.

Hosted CI for prior72af053 is now terminal success for both PR38107976142 and
push38107973476. The first project XERJ refresh refused to record freshness because a test changed
during indexing (exit1); final refresh/check/query, source review and new-head
publication/CI are recorded separately in the root report. Remaining Telegram preparation work
included albums/video, one-shot Send as Spoiler and other reference options;
animated dust parity, autoload, specialized renderers, live-account acceptance,
subsequent MMail/Aether, WhatsApp, Teams, Telemost, backups and standalone packaging
remain open. The full sequential migration goal stays active.

Final source review covers20 changed and11 supporting files. All31 hashes/bytes
match before/after; both P2 findings are resolved with no remaining source finding.
Worker runtime gates are SKIP; root owns verification. Final XERJ refresh exits0
(305 indexed files,275/275 code, zero junk), and project/reference/engine freshness
checks plus scoped queries pass with source-confirmed hits. Publication audit
checks310 publishable files and the PR body against5 credential fields:zero matches.
Latest built/QA signatures and unsigned executable match pass. Latest native QA
repeats photo restoration with exact input/options, cancellation, ordinary draft,
Mail→Telegram and final restart without resurrecting the cancelled photo. Native
failure injection and live-server acceptance remain unverified. Observed route
and usage remain unknown; no quorum is claimed.

## Historical new-photo caption placement

Telegram remains inside the common Makosh service-sidebar/dialog/conversation
window. New photo preparation offers Move Caption Up/Down through native actions
and header context menus, including an empty caption. The editor remains below
the preview, as in the active reference layout. File preparation has no placement
action. Text/entities/selection and placement remain independent; captured
context/revision rejects stale menus and sending/uncertain states.

Submission freezes input and placement together, stores the marker and passes
InvertMediaMessageAttribute to the native queue. Admission/atomic receipt check
the exact flag; acceptance retries retain the choice without resubmitting.
Pending JSON writes schema2 with an explicit Bool. Legacy schema1 restores below;
malformed/future versions and above-on-file fail closed. Older apps refuse schema2.
The PostgreSQL schema, encrypted S3 format, engine pins and recipe8 are unchanged.

Initial runtime red: five tests, fourteen failed assertions. Recovery runtime red:
nine tests, eleven failed assertions. Missing-API compilation, a duplicate-parameter
compile error from the initial API scaffolding, and an orchestration syntax error
are separate failed evidence. Final scripts/dev-db.sh up, scripts/test.sh and
scripts/build-app.sh exit0: **609 XCTest (546 Telegram +63 core), zero failures;
30 Python regressions**. Full tests/build repeated after review cleanup. Logs
retain130 upstream t19 teardown diagnostics without a test failure/trap.

Real encrypted Postbox tests check native placement admission/receipt and reopen.
Real PostgreSQL/S3 tests restore normalized photo bytes, caption, placement and
cancellation with immutable archive retention. Native old-UI red confirms missing
placement menus. Owned native AX/screenshots verify actions/header context menus,
default/reset choice, preservation after text editing/restart, synthetic queue
acknowledgement, file exclusion, cancellation, Mail→Telegram, and final restart
without resurrecting the cancelled photo. Ordinary input survives cancellation.
Strict deep signatures and unsigned built/QA payload match pass. QA uses only
owned encrypted synthetic Postbox and isolated PostgreSQL/S3, without personal
accounts, Keychain or Telegram network/server operations. Server acceptance is
not established.

Read-only source review identified retention of cancelled caption payloads in an
unbounded controller dictionary. Payloads now exist there only while their
initial write is in flight and are consumed on completion; task/retry retains
the frozen copy. The cancellation/rebind regression passes before/after this
cleanup; memory volume was not measured and no failing memory test is claimed.
The final source freeze covers17 changed and9 supporting files; worker and root
hashes/bytes match with no remaining source finding. Final lexical XERJ refresh
exits0 (304 files,274/274 code); project/reference/engine fingerprints and scoped
queries pass with source-confirmed hits. Publication audit checks309 publishable
files and the PR body against5 credential fields, with zero matches. Worker
runtime gates are SKIP; root owns them. Observed route/usage remain unknown.

Previous bac77ff hosted PR/push CI was still in progress at the current live
observation; no pass or terminal result is inferred. New-head publication and
CI are recorded separately after publication. Photo albums/video preparation,
other media options, autoload, specialized renderers, exhaustive visual parity,
live-account acceptance, later channels, backups and standalone packaging remain
open. The full sequential migration goal stays active.

## Historical Telegram caption editing placement

Telegram remains in the common Makosh service-sidebar/dialog/conversation window.
The inline edit accessory now offers Move Caption Up/Down across its full surface,
following verified TelegramSwift behavior. Raw native placement is independent
of text/entities/selection and received presentation. Placement-only edits are
accepted; menu/submit capture session/revision/context, reject stale or uncertain
actions, and preserve newer input on an old acknowledgement. Edit requests and
unchanged-text reconciliation retain/check native placement.

Read-only review identified a legacy-caller boundary where correct native
fingerprints could accompany omitted additive metadata. A real Postbox regression
reproduced two failures; dispatch now builds content from the freshly validated
message. The final frozen nine-file source snapshot and eleven supporting files,
plus two additional supporting sources, have matching before/after hashes;
the finding is resolved with no remaining source finding. Worker runtime/build/UI
checks are SKIP; root verified these gates. Observed model/provider/usage remain
unknown and no quorum is claimed.

Initial runtime red: ten tests, 25 failed assertions. Missing-API compilation and
an async-autoclosure test compile error are separate failed evidence; the latter
was corrected before runtime red. Focused green: 46 tests. Final
scripts/dev-db.sh up, scripts/test.sh and scripts/build-app.sh exit 0:
**599 XCTest (536 Telegram +63 core), zero failures; 30 Python regressions**.
The full suite was repeated after the legacy boundary fix. The log retains 126
upstream t19 teardown diagnostics without a test failure/trap.

Native old-UI red confirms the missing accessory menu. An intermediate new UI
opened it on text but missed the empty middle of the band; contentShape repairs
that confirmed hit-area gap. Final owned native AX/screenshots verify whole-band
right-click, up/down menu state, placement-only enabled confirmation with unchanged
text, preservation through text edits/chat switches/Mail→Telegram, cancel/source
reopen, synthetic applied acknowledgement and restart. The ordinary draft is
preserved; restart resets temporary edits. QA uses only owned encrypted synthetic
Postbox and isolated PostgreSQL/S3, without personal accounts, Keychain or Telegram
network/server operations. Strict deep signatures and unsigned built/QA payload
match pass. Live-server acceptance is not established.

Final lexical XERJ refresh exits 0: 303 files, 273/273 classified code;
project/reference/engine fingerprints and scoped queries pass. Current source
hits were checked directly. Selected-field publication audit checks 308 publishable
files and the PR body against five credential fields, with zero matches. Machine
configuration, indexes, runtime and raw QA artifacts stay ignored.

Previous 40964da passed both hosted PR and push CI. Current-head publication/CI
and final index/audit evidence are recorded separately after publication.
New-media preparation placement is the next reference workflow. Specialized
renderers, autoload, exhaustive pixel parity, later channels, backups and standalone
packaging remain open; the full sequential migration goal stays active.

## Historical received Telegram captions above visual media

Telegram stays inside the common Makosh service sidebar, dialog list and
conversation/dossier. Received photo and ordinary-video messages now retain the
native `InvertMediaMessageAttribute`: history and search place their existing
rich caption above media when requested; the default stays below. Visual albums
use the first member's placement and the first nonempty caption, matching the
verified reference. File/audio/voice/round-video cards and WebM are excluded from
this mapping. Sending a new caption-above option and specialized renderer parity
remain open. No outer GPLv2 code/assets were copied; pins, recipe 8, PostgreSQL
schema and S3 format are unchanged.

Runtime red reproduces seven failed caption-placement assertions in nine focused
tests; the final focused run passes all nine. Missing-API compilation red is
separate. An initial green attempt referred to an outer-UI-only `isWebm` extension
and failed compilation; the final code uses the verified MIME rule directly.
An intermediate native build with the old UI fails the caption-above assertion
for search129 before the UI change. Final `scripts/dev-db.sh up`,
`scripts/test.sh` and `scripts/build-app.sh` exit 0: **590 XCTest (527 Telegram +
63 core), zero failures; 30 Python regressions**. The full tests were repeated
after the fixture readiness changes below. Logs retain 126 upstream t19 teardown
diagnostics without a local failure/trap. Failed raw evidence is not a pass.

Actual native AX/screenshots verify caption-above search129, separate Reveal,
loaded photo preview, caption-above focused history129 with a fresh Reveal and
exact one-message selection. Visual album129/130 and portrait album126 retain
caption-above order; default album122 and file cards retain below order. The
moved album caption deselects/reselects exactly IDs129/130; selection hides inner
media actions. Mail → Telegram retains the selected chat and ordinary draft.
An owned-process restart preserves the draft and caption placement while requiring
Reveal again. QA uses only owned encrypted synthetic Postbox and isolated
PostgreSQL/S3, without personal accounts, Keychain or Telegram network/server
operations. Native video-above placement is covered by mapping regression, not
claimed as a separate playback check in this slice.

The previous e114ce8 head passed
[push CI](https://github.com/Mesteriis/makosh-native/actions/runs/38105288325) but
failed [PR CI](https://github.com/Mesteriis/makosh-native/actions/runs/38105290875)
at the upstream SQLite WAL assertion. Read-only investigation finds exactly two
of nineteen synthetic Postbox test files missing both MediaBox initialization
barriers. RetentionJournal and ArchiveEndToEnd now wait, with a bounded timeout,
for storage/cache readiness before proceeding to teardown. This repairs the
confirmed fixture gaps; the historical crash cause remains unproven because its
log lacks a stack, database path and SQLite error code. Engine assertions remain
unchanged. Current-head hosted CI is recorded separately after publication.

Read-only review found no new source finding in the frozen ten-file snapshot;
all ten changed and fourteen supporting hashes match before/after and at root
integration. Worker runtime/build/UI gates are SKIP; root owns those checks.
Observed provider/model/usage remain unknown and no quorum is claimed. A failed
auxiliary review-artifact invocation remains recorded separately from its passing
correction. Final lexical XERJ refresh exits 0: 301 files, 271/271 classified code;
project/reference/engine fingerprints pass and query hits were confirmed against
current source. Strict deep signatures and unsigned built/QA payload comparison
pass. Selected-field publication audit checks 306 publishable files and the PR
body against five credential fields, with zero matches. Final diff check passes.
Machine indexes/configuration/runtime and raw QA artifacts remain ignored.
Autoload, specialized renderers, exhaustive pixel parity, live-account acceptance,
later channels, backups and standalone packaging remain open. The full sequential
migration goal stays active.

## Historical Telegram ordinary photo/video presentation

Telegram remains inside the common Makosh service sidebar, dialog list and
conversation/dossier. Ordinary history and search now show photo/video inline,
with caption text below the attachment. A shared own renderer retains album
behavior; ordinary rows use aspect-fit and reference-derived bounded sizing.
Photo bounds, small-image minimums, portrait caption space and landscape/portrait
video sizing are covered by literal geometry regressions. Narrow-window bounds
and a one-pixel minimum for pathological video dimensions are own adaptations;
exhaustive pixel parity is not claimed.

Media spoilers require a separate Reveal before preview/photo/player actions.
The guard belongs to the exact descriptor and account context; search and history
have separate local reveal state. Explicit full-file download/save remains
available while hidden, but neither preview nor playback is exposed. Nonvisual
attachments retain their file cards. DEBUG album search now receives the same
page configuration as history, preserving hidden descriptors and source versions.
Default fixtures and live search are unchanged. No outer GPLv2 code/assets were
copied; dependency pins, recipe 8, PostgreSQL schema and S3 format are unchanged.

Runtime red reproduced 15 failed geometry/search assertions; the focused green
run passes 10 tests. On an intermediate build with the old UI, native search129
had no Reveal action: that explicit UI assertion failed before the renderer change.
Final `scripts/dev-db.sh up`, `scripts/test.sh` and `scripts/build-app.sh` exit 0:
**587 XCTest (524 Telegram + 63 core), zero failures; 30 Python regressions**.
Logs retain 126 upstream t19 teardown diagnostics without failure/trap. The first
diff check caught an extra EOF blank line after extraction; it was removed before
the final checks. Failed raw evidence remains private and is not a pass.

Actual native AX/screenshots verify hidden search129, explicit full-file loading
without hidden preview/player menu actions, separate Reveal and photo preview,
history navigation with a fresh Reveal, exact one-message selection and suppressed
media actions during selection. Video115 loads explicitly and plays the real
12-second synthetic fixture; portrait126 uses a full aspect-fit image with caption
below. Existing album IDs remain available. Mail → Telegram and an owned-process
restart retain the ordinary draft; restarted search129 requires Reveal again.
QA uses only the owned encrypted synthetic Postbox and isolated PostgreSQL/S3,
without personal accounts, Keychain or Telegram network/server operations.

Read-only review found no new source finding in the frozen nine-file snapshot.
Before/after hashes and sizes match; the unchanged reveal guard was separately
hashed. Worker runtime/UI/build checks are SKIP; root owns those checks. Observed
model/provider/usage remain unknown and no quorum is claimed. Caption inversion,
autoload, specialized audio/round-video/sticker/paid/secret renderers, exhaustive
pixel parity and live-account acceptance remain open. Later channels, backups and
standalone packaging remain open; the full sequential migration goal stays active.

Previous forward-options head 58ac00c passed both hosted
[PR CI](https://github.com/Mesteriis/makosh-native/actions/runs/38104293456) and
[push CI](https://github.com/Mesteriis/makosh-native/actions/runs/38104290482).
Current-head publication/CI evidence is recorded separately after publication.
Final lexical XERJ refresh exits 0: 300 files, 270/270 classified code. Project,
reference and prepared-engine fingerprints pass; current geometry/shared-view
and reference sizing query hits were confirmed against source. Strict deep
signatures and unsigned built/QA payload comparison pass. Final diff check
passes. Machine configuration, runtime data, indexes and raw QA artifacts remain
ignored; publication uses the selected-field credential audit.

## Historical Telegram forward author/caption options

Telegram remains in the common service-sidebar/list/conversation window. The
forward accessory now shows checked author and caption choices with counts of
distinct native author IDs and captioned messages. Caption changes follow the
reference's default author coupling until the user explicitly chooses an author
option, including choosing the already checked Show item. Later caption changes
retain that choice. Menu actions freeze context/chat/intent/draft revision and
refuse stale or uncertain composers. Rich input, UTF16 selection and reply remain
independent. Ordinary re-targeting retains the choice; Saved re-targeting keeps
its previously verified fresh default options.

The optional schema-4 `explicitHideNames` field survives draft persistence and
restart. Missing legacy fields remain valid; malformed types and inconsistent
known flags are refused. Persistence of this explicit choice is Makosh's own
adaptation: the reference's `tempSenderName` is not restored by decoding. The
accessory title follows the author preference, while native transport retains
the reference's `hideNames || hideCaptions` rule. No outer GPLv2 UI/assets were
copied. Pins, recipe 8, PostgreSQL schema and S3 format are unchanged.

Final `scripts/dev-db.sh up`, `scripts/test.sh` and `scripts/build-app.sh` exit 0:
**582 XCTest (519 Telegram + 63 core), zero failures; 30 Python regressions**.
Logs retain 126 upstream t19 teardown diagnostics without failure/trap. Initial
missing-API compilation errors are separate from runtime reds, which reproduced
missing coupling/preference, stale-menu and native preview-identity behavior.
One first-green fixture expectation used account ID 999 instead of the existing
outgoing synthetic author's -1; correcting that literal left production behavior
unchanged. Failed raw logs remain private and are not passes.

Actual native AX/screenshots verify checked counts 1/3, default caption cycling,
fresh already-checked Show-author selection, both explicit author choices,
ordinary re-targeting, picker Cancel and Mail → Telegram preservation. An actual
owned-process restart followed by another caption cycle retains explicit Show.
An initial coordinate-only attempt did not establish that choice; the fresh
exact-AX replay passes without a source change. No coordinate-hit fix is claimed.
QA uses only the owned encrypted synthetic Postbox and isolated PostgreSQL/S3;
no personal account, Keychain or Telegram network/server operation was used.

Read-only review found no new source finding in the frozen nine-file snapshot;
before/after hashes and sizes match. Worker runtime gates are SKIP; root owns
the tests/build/native checks. Observed model/provider/usage remain unknown and
no quorum is claimed. Exhaustive media/options/special/topic/secret/paid behavior,
singleton spoiler rendering and live-account acceptance remain open. Later
channels, backups and standalone packaging remain open; the full sequential
migration goal stays active. Final lexical XERJ refresh exits 0: 297 files, 267/267 classified code.
Project/reference/engine fingerprints pass; current option/reference query hits
were confirmed against source. Strict deep signatures and unsigned built/QA
payload comparison pass. Publication audit checks 302 publishable files and the
PR body against five selected credential fields, with zero matches. Machine
configuration, runtime data, indexes and raw QA artifacts remain ignored.

## Historical Telegram album history and selection

Telegram remains inside the shared Makosh service sidebar, dialog list and
conversation/dossier. The loaded history now projects native UI album identities
into scoped rows, independently of the native forwarding grouping key. Visual
groups use a bounded SwiftUI mosaic; files retain per-member cards. Visual albums
show the first nonempty caption while preserving every original message and ID.
Explicit image/video loading uses the existing leased media flow; thumbnails
decode to at most 512 px. Native media-spoiler flags require a separate Reveal
before opening a visual tile, and a changed context/descriptor hides it again.

Selection can target one tile or the visible group. Partial groups add missing
members; full groups remove their members. Shift ranges, the 100-member limit,
frozen versions, independent sticky permissions and session/window/revision
guards remain enforced. Copy/forward/delete receive exactly the selected IDs;
neither projection nor backend actions expand hidden album members. Group Shift
uses a deterministic first new member rather than the reference's unordered set
endpoint. No outer GPLv2 UI/assets were copied; pins, recipe 8, PostgreSQL schema
and S3 format are unchanged.

Final `scripts/dev-db.sh up`, `scripts/test.sh` and `scripts/build-app.sh` exit 0:
**570 XCTest (507 Telegram + 63 core), zero failures; 30 Python regressions**.
Logs retain 124 upstream t19 teardown diagnostics without failure/trap. Focused
runtime reds cover group selection, version/permission guards, thumbnail bounds,
spoiler reveal and synthetic workflow version consistency. One initial fixture
binding compile failure was corrected before the final passing run; failed raw
logs remain private and are not reported as passes.

Actual native AX/screenshots verify two-wide, three-portrait and four-square
layouts, explicit photo preview/video playback, protected-file forwarding
refusal, partial selection and ordinary recipient staging. The first physical
tile-center click exposed a hit-area defect; a full rectangular Button label
fixes it. On the final binary, physical center click selects one tile, Shift
expands from three to five selected IDs, ordinary click removes only one, and
outer whitespace fills/removes the group once. Cancel restores the ordinary
draft without revealing the spoiler. Mail → Telegram retains selection, and
restart restores a prepared partial forward with enabled simulated Send. An
explicit accessible photo Button opens its preview; physical keyboard activation
was not established and is not claimed.

The explicit DEBUG album fixture uses the same page configuration for history
and forward/Saved/copy/range/reply resolution. Default fixtures are unchanged.
QA uses only the owned encrypted synthetic Postbox and isolated PostgreSQL/S3;
queue simulation is not live Telegram Account/server acceptance. No personal
account, Keychain or Telegram network was used. Same-model read-only review
found no further source defect on the final 27-file snapshot. Its source hashes
match before/after; runtime gates were run by root, not the reviewer. Observed
model/provider/usage remain unknown and no quorum is claimed. An earlier review
after-hash failure is retained: the root was then changing only the UI hit area;
the subsequent frozen snapshot passes.

For the prior published head 755b3ad, hosted PR CI passed but push CI failed in
an upstream SqliteValueBox WAL assertion. Inspection found an asynchronous test
StorageBox-open/fixture-removal lifecycle gap. The fixture now waits for both
storage boxes before teardown; final local gates pass. This repairs a verified
race opportunity, without establishing the historical trap's exact cause or
weakening the engine assertion. Album head 92769eff passed both hosted
[PR CI](https://github.com/Mesteriis/makosh-native/actions/runs/38103351575) and
[push CI](https://github.com/Mesteriis/makosh-native/actions/runs/38103348144).
Forward-options head CI is tracked separately.

Exhaustive mosaic pixel parity, ordinary singleton spoiler rendering, remaining
media/options/special/topic/secret/paid behavior and live-account acceptance stay
open. Later channels, backups and standalone packaging remain open; the full
sequential migration goal stays active. Final XERJ refresh exits 0: 296 files,
266/266 classified code. Project/reference/engine fingerprints pass; active
group-selection, reveal/fixture and spoiler searches were confirmed against
current source. A final documentation check corrected a group-toggle reference
from ChatPresentationInterfaceState to ChatGroupedItem:753–783, followed by a
fresh index. Strict deep signatures and unsigned built/QA payload comparison
pass. Publication audit checks 301 publishable files and the PR body against
five selected credential fields, with zero matches. Machine configuration,
runtime data, indexes and raw QA artifacts remain ignored.

## Historical Telegram accessory Saved forwarding and reconnect recovery

Telegram remains in the shared service-selector/list/conversation window.
**Другой получатель…** now pins **Избранное** first and accepts a full-row click
without navigating or sending the old comment/reply. The picker freezes the
account context, origin chat/revision and intent. Optional origin metadata keeps
schema-1 originless receipts compatible. Fresh native admission requires the
exact prepared origin; the queue transaction records the unique Local receipt
and clears only that forward together. Rich input/UTF16 selection/reply survive.
Saved re-targeting uses default visible author/caption options; ordinary re-target
retains its existing options, with exhaustive option parity still open. Picker
Cancel before dispatch retains the origin, a documented adaptation of the
reference's early forward-ID clearing. Archive PostgreSQL/S3 data is unchanged.

Final `scripts/test.sh` exits 0: **536 XCTest (473 Telegram + 63 core), zero
failures; 30 Python regressions**. The earlier Saved-focused run passes 25 cases; the final full run also covers newer-origin recovery. Final
`scripts/build-app.sh` exits 0; the earlier unchanged dev PostgreSQL/S3 gate
exits 0. Logs retain 124 upstream t19 teardown diagnostics without failure/trap.
The initial model red reproduced missing accessory Saved behavior. Postbox
fixture compile errors were corrected before the runtime red demonstrated
stale-origin admission and missing origin removal. New encrypted regressions
cover invalid receipts, changed/unknown origins, genuine reopen, lost ACK and
literal legacy schema-1 receipt recovery.

Root review found a separate unsafe recovery gap: unreadable Saved records left
an unidentified prepared forward editable/sendable. A new red regression failed
four assertions before the model lock was extended to unknown recovery with no
request. Final tests verify prepared-forward blocking and independent ordinary
input in another chat. No automatic resend is introduced.

Actual native AX/screenshots verify restored comment/reply/forward, picker
Cancel, one-click Saved without navigation, ordinary re-targeting, unknown-result
resubmission/input/forward-cancel blocking, another chat's editable input,
Mail → Telegram preservation and accepted-receipt restart without a new modal.
QA uses the same owned encrypted synthetic Postbox and isolated PostgreSQL/S3;
DEBUG queue simulation is not a live Account/server operation. The final recovery
lock is established by regressions; no unreadable-record native fault injection
is claimed. Personal accounts, Keychain and Telegram network were not used.

Reference source confirms fresh ForwardMessagesObject, own-peer default options
and forward-only clearing. No outer GPLv2 UI/assets were copied. Pins, recipe 8
and PostgreSQL schemas remain unchanged. Scoped read-only review found a same-model reconnect gap after lost ACK: accepted
recovery unlocked a stale cached forward. A red regression reproduced it before
an accepted-recovery callback was added ahead of unlock. Exact account/origin
revision/intent/sources guard memory-only clearing, including offscreen; recovery
does not save or enqueue. Final regressions verify zero recovery writes, unchanged
durable snapshot, input/reply retention and a newer origin surviving. The reviewer
found no further defect in the amended source/tests; worker runtime gates were
SKIP, observed model/provider/usage remain unknown, and no quorum is claimed.
Root ran final integration gates. Album selection, normal option parity, special/topic/secret/paid behavior and live-account acceptance remain
open. Later channels, backups and standalone packaging remain open; the full
sequential migration goal stays active. Final index/publication evidence covers the frozen reconnect fix; hosted CI
is tracked separately for each published commit.
The reference forward picker hides its caption field through multipleSelection
→ presentation → hasCaptionView; its generic perform(comment:) API does not
establish visible picker comments. The earlier picker-comment gap is corrected;
comments remain in the chosen recipient composer. Real-account reconnect and
concurrent multi-window reconciliation are still unverified.
Final XERJ refresh exits 0: 287 files, 257/257 classified code; project,
TelegramSwift and engine fingerprints pass. Active origin-CAS, native enqueue
and reference searches were confirmed against source. Strict deep signatures
and unsigned built/QA payload comparison pass; the reconnect-fix executable repeats
restored comment/reply and one-click accessory Saved behavior in the shared window.
There is no native synthetic same-model rebind control; the regression establishes
that lifecycle path, and no live reconnect is claimed. Publication audit
checks 292 publishable files and the PR body against five selected credential
fields, with zero matches. Machine configuration, QA data and indexes stay ignored.

## Historical Telegram initial picker Saved Messages forwarding

Telegram remains inside the shared service-selector/list/conversation window.
The initial history/selection recipient picker pins **Избранное** first; one
explicit click anywhere in the row queues the captured batch without navigation
or a recipient composer. Ordinary recipients still stage their composer. The
ordinary Saved input/reply/forward is preserved by a separate account-scoped
schema-1 Postbox intent/receipt, with bounded decoding and unknown-byte retention.
Started is durable before enqueue; final fresh whole-batch admission and the
unique outgoing Local receipt share native queue transactions. Only proven
zero-queue refusal clears the exact intent. Cancellation, timeout or ambiguous
results never trigger automatic retry; restart reads accepted/started state.
Local acceptance clears only the original selection revision and does not prove
server delivery or power-loss survival. PG archive records/S3 files are unchanged.

`scripts/dev-db.sh up`, focused/full `scripts/test.sh`, `scripts/build-app.sh`
and strict deep signature/payload checks exit 0: **526 XCTest (463 Telegram +
63 core), zero failures; 30 Python regressions**. Saved-focused 16 cases pass.
Encrypted Postbox tests cover separate ordinary bytes, actual queue records,
genuine reopen, unknown formats, duplicate intent refusal and changed/protected/
foreign-source admission. The lost-ACK test counts actual native queue history
and preserves ordinary bytes. Full logs retain 114 upstream t19 teardown
diagnostics without failure/trap.

Initial focused tests trapped because MainActor transaction closures ran on the
Postbox queue. A separate real-provider recovery regression reproduced the same
SIGTRAP before nonisolated signal builders fixed both recovery and rejection
boundaries; callback delivery remains MainActor. Further real-provider coverage
exposed the offline logical account -1 being used as an invalid native PeerId.
The DEBUG fixture now reserves valid destination 10000 in its isolated Postbox,
retains account -1 only as its logical scope and records actual native queue IDs.
The first native row-center click merely selected the intrinsic-width button's
row; a full-width label/hit area fixed one-click behavior. Failed raw logs remain
local rather than being converted into passes.

Actual native AX/screenshots verify one-click selection forwarding, source chat/
ordinary draft/reply130 retention, selection clearing, ordinary-recipient staging
and protected120 forward refusal. Lost-ACK simulation shows uncertainty with
resubmission disabled while ordinary recipients remain enabled. Mail → Telegram
preserves state. Restart reads the accepted receipt, removes uncertainty and
retains ordinary input/reply without a new modal. DEBUG forwarding is explicit
StoreMessage/receipt simulation, not a live Account enqueue; native admission/
receipt behavior is separately established by encrypted regressions. No personal
account, Keychain, Telegram network or server send was used.

Reference ShareModalController.swift:1296–1335 confirms the initial own-peer
exception and ordinary recipient staging. No outer GPLv2 source/assets were
copied; dependency pins, preparation recipe 8 and PG schemas remain unchanged.
Remaining Telegram parity includes picker comments, Saved
accessory re-targeting, album selection, special moderation/scheduled/topics/
secret/paid actions and live-account acceptance. Later channels, backup and
standalone packaging remain open; the full sequential migration goal stays active.
This slice uses root source review/integration evidence, without new workers or
quorum claims. Final XERJ project refresh exits 0: 287 files, 257/257 classified
code. Project/engine/reference fingerprint checks pass; active Saved admission,
native enqueue and reference own-peer queries are confirmed against source.
Publication audit checks 292 publishable files and the PR body against five
selected credential fields, with zero matches. Index attempts interrupted by
concurrent source changes remain recorded as failures; the final frozen refresh
passes. Machine configuration, runtime data and QA artifacts remain ignored.
Prior published head dafa334 passed both hosted PR/push CI; new-head CI is separate.

## Historical Telegram selected-message copy and delete

Telegram remains inside the shared service-selector/list/conversation window.
The reference panel now exposes Delete/count/Forward, with Cancel/Escape beside
the count. Command-C copies the full eligible selection through a scene-scoped
SwiftUI command. A single cached Postbox read rechecks every frozen source's
account/chat/migration/thread/fingerprint and copy permission before returning
masked author/text/media projections. Missing or changed records refuse the
whole copy. Clipboard writes require the original session/revision/context.
Protection and other action permissions invalidate independently and remain
sticky until reselection; permitted deletion survives copy/forward protection.

Delete requires explicit whole-selection local/everyone confirmation. Saved
Messages suppresses everyone deletion. Recipe 8 adds exact-hash-checked native
admission and exact-ID removal in one Postbox transaction, without expanding
unselected album members. No dependency pin or schema changes are introduced.
The prior snapshot and removal marker remain in the existing retention journal;
the new operation never deletes PostgreSQL archive records or S3 objects. Local
queue acceptance clears only its captured selection/edit revision and preserves
ordinary input/reply. Cancellation or timeout after dispatch remains uncertain
and blocks resubmission until explicit reconnection; it never retries itself.

`scripts/dev-db.sh up`, focused/full `scripts/test.sh`, `scripts/build-app.sh`
and strict deep signature/payload verification exit 0: **510 XCTest (447 Telegram
+ 63 core), zero failures; 30 Python regressions**. The focused run passes 33
cases. New encrypted Postbox regressions prove exact selected album IDs,
retained snapshots/removal markers across genuine reopen, whole-batch rejection
and fresh permission loss. Controller/model regressions cover synchronous and
late callbacks, stale revisions, deadlines, masked text/protected batches and
independent ordinary/reply/edit state. The full run prints 98 upstream t19
teardown diagnostics without failure/trap.

Actual native AX/screenshots verified physical Command-C for 130+121, author/ID
order, photo caption and masked spoiler, including after Mail → Telegram.
Protected120 blocks Copy/Forward while Delete remains available. Cancel retains
the selection; confirmation requires an explicit scope and uses the permission
intersection. Simulated local acceptance restores ordinary input/reply130 and
shows local-queue/retention status. Standard editor Command-C still works after
leaving selection. The initial `onCommand` implementation left native Copy
disabled; focus-gated menu attempts also failed. The final scene command remains
available throughout an eligible panel's lifetime and passes the native flow.
QA uses the same owned encrypted synthetic Postbox and isolated PostgreSQL/S3,
matching unsigned executable payload and strict signatures. The DEBUG delete
provider is explicitly simulated and does not mutate Postbox; actual native
deletion/journal behavior is established by the encrypted regressions. No
personal account, Keychain, Telegram network or server send was used.

Scoped worker source review reported no confirmed actionable defect, with
runtime gates skipped. Root amended the copy deadline's token guard and command
routing/enablement, reviewed current source, and ran final gates/native QA.
Worker model/provider/usage remain unknown; this is not a quorum review.
Specialized moderation/scheduled/topics/secret/paid actions, exhaustive media
localization/music metadata, album selection, Saved Messages immediate forward
and live-account acceptance remain open. Later channels, backups and standalone
packaging remain open; the full sequential migration goal is active. Prior head
`612c26a` passed both hosted PR/push CI; current-head hosted CI is separate.

Final XERJ project refresh exits 0: 279 files, 249/249 classified code. Project,
engine and TelegramSwift fingerprint checks pass; selected-copy command and
native admission queries were confirmed against source. An earlier project
refresh exited 1 after source changed during indexing; it was closed before
the final refresh. One reference query used the wrong prefix and found no
dataset; the corrected locked prefix returned the expected copy implementation.
Publication audit checks 284 publishable files and the PR body against five
selected credential fields, with zero matches. Machine configuration, runtime
data, QA artifacts and indexes remain ignored.

## Historical Telegram cached Shift-range selection

Telegram remains inside the shared service-selector/list/conversation window.
Shift-click toggles the endpoint first, then adds cached numeric IDs between it
and the previous anchor in descending order, filling up to 100. Cloud wins an
identical Local number; protected/Local sources remain in selection and prevent
the entire forward. Shift-deselect removes only its endpoint and preserves the
anchor. Recipe 7 adds exact-hash-checked native cached ID lookup, retaining all
prior adaptations and the independent dependency pin. Two index reads are
bounded to 200 each, with a merged maximum of 200 sources; there is no network
history fetch, full-history allocation or iteration over missing integers.

Request/session/revision/account context and captured page guards reject late
callbacks. New click/page/chat/account or explicit cancel disposes pending work;
page changes retain already selected endpoints/items. Forward waits for range
completion. A 30-second timeout keeps the prior selection with a visible error.
A newly observed changed off-page source invalidates its frozen version rather
than replacing it. Synchronous provider callbacks dispose their returned lease
once. Ordinary-deselect uses the deterministic minimum native greater anchor;
the reference picks an arbitrary greater element from its Set.

`scripts/dev-db.sh up`, final focused/full `scripts/test.sh`,
`scripts/build-app.sh` and strict deep signature verification exit 0:
**487 XCTest (424 Telegram + 63 core), zero failures; 28 Python regressions**.
The focused run passes 33 cases. Thirteen new tests cover controller range rules,
off-page changed bytes, encrypted Postbox sparse-ID/namespace/order/bounds and
synthetic model cross-page/lifecycle/synchronous callbacks. The first focused
run failed compilation of a new test's tuple flatMap expression because Swift
could not typecheck it in reasonable time. Explicitly typed tuple appends fix
the fixture without changing its assertions; final gates pass. The full run
prints 74 upstream t19 teardown diagnostics without failure/trap. Earlier
independent failures remain recorded below.

Actual native AX/screenshots verified a physical Shift-click from selected130
to previous-page40 (count91), Shift-deselect40 (count90), Mail → Telegram
preservation and Shift39 (count92, reselecting40 proves the anchor survived).
Extending to1 partially fills100; another page shows31 unselected and32 selected.
Latest retains protected120 and masked spoiler121; deselect120 produces99 and
enables Forward. Escape restores the original ordinary draft and reply130.
QA used the same owned encrypted synthetic Postbox and isolated PostgreSQL/S3,
with matching unsigned executable payload and strict signatures. No personal
account, Keychain, Telegram network or server send was used. Pending callback
and namespace behavior are established by regressions, not live-account QA.

Readonly scoped review reported no confirmed actionable defect. Root amended
the original controller to invalidate freshly changed off-page versions and
simplified the reviewed provider test fixture after its compile failure. Worker
runtime gates were SKIP; root ran integration gates and native acceptance.
Observed worker provider/model/usage remain unknown. The original project
freshness log was stale during integration; final refreshed evidence is separate.
Scheduled/topic/migrated-peer ranges, album selection, selected copy/delete,
Saved Messages exception and live-account acceptance remain open. Later channels,
backups and standalone packaging also remain open; the sequential goal is active.
Previous head `79fc7d4` passed both hosted PR/push CI runs. Current-slice hosted
CI is recorded separately after publication.

Final project XERJ refresh exits0:267 files,237/237 classified code. The
selection resolver and native shim query hits were confirmed against current
source; final project/engine/TelegramSwift freshness checks exit0. Publication
audit checked272 publishable files and the private PR body against five selected
credential fields, with zero matches. Machine configuration/QA data stay ignored.

## Historical Telegram history selection and batch forwarding

Telegram remains inside the shared service-selector/list/conversation window.
The history context menu now starts selection of up to 100 typed native IDs.
A count/cancel/forward panel replaces the ordinary composer without changing its
input/reply or active edit. Frozen sources retain native MessageId order across
pagination; a non-forwardable or visibly changed source blocks the whole batch.
The recipient picker captures the selection revision and refuses stale snapshots.
Accepting it clears selection and stages the existing recipient composer without
sending. Ordinary/reply/edit state stays independent. Selection survives service
switches; Cancel/Escape, search, actual chat/account change clear it. Restart
resets selection. Chat-change reset is an explicit bounded lifecycle adaptation,
not a claim that the reference always clears on controller disappearance.

`scripts/dev-db.sh up`, focused and full `scripts/test.sh`, `scripts/build-app.sh`
and strict deep signature verification exit 0: **474 XCTest (411 Telegram +
63 core), zero failures; 26 Python regressions**. The focused run has 23 passing
cases. Thirteen new selection/model tests cover native ordering/100 limit, typed
scope/session/window/revision guards, page absence, sticky changed versions,
protected whole-batch refusal and ordinary/reply/edit preservation. Two additional
presentation regressions cover spoiler surrogates/source preservation and safe
unavailable-format fallback. The first selection focused run failed one fixture
case (three assertions): it chose id25 outside the preceding 31–80 page. Correcting
the fixture to id40 retains both stale-window rejection and off-page preservation;
final tests pass. The full run prints 66 upstream t19 teardown diagnostics without
failure/trap. Earlier unrelated cleanup/SQLite failures remain recorded below.

Actual native AX/screenshots verified context-menu selection, count/row toggles,
selection across previous/latest history pages and Mail → Telegram, protected
source disabling the entire forward, and Escape returning the original draft/reply.
Picker cancellation retained selection; acceptance navigated to the recipient
with two sources and no send. The selected batch/comment restored after process
restart; explicit Command-Enter synthetic acceptance cleared the exact forward.
The source ordinary draft/reply survived. A separate restart during active row
selection reset that temporary selection and retained ordinary/reply. QA used the
same explicitly owned encrypted synthetic Postbox and isolated PostgreSQL/S3,
matching unsigned executable payload and strict signatures. No personal account,
Keychain, Telegram network or server send was used. The synthetic provider does
not execute a live Account's native enqueue algorithm.

Readonly review found a P2: the new row's accessibility label used raw text,
exposing an unrevealed spoiler. Root changed it to the existing default masked
presentation with a safe unavailable-format fallback, added regressions, and
verified masked AX/screenshot output. Corrected review hashes match current
source; no further confirmed scoped findings remain. Worker runtime gates were
SKIP; root performed integration gates/native QA. Observed model/provider/usage
remain unknown. Shift-range, album individual/group selection, selected copy/
delete, Saved Messages immediate exception and live-account acceptance remain
open. An existing edit takes precedence over a staged forward accessory until
finished/cancelled; no reference evidence justifies silently discarding that edit.
Other Telegram parity, later channels, backups and standalone packaging remain
open; the full sequential migration goal stays active. Prior head `0d32197` passed
both hosted PR/push CI runs; this slice's hosted CI is separate.

Final project XERJ refresh exits 0: 262 files, 232/232 classified code. Current
selection/staging/presentation queries were confirmed against source; project,
engine and TelegramSwift freshness checks exit 0. Publication audit checked
267 publishable files and the private PR body against five selected credential
fields, with zero matches. Runtime configuration and QA artifacts stay ignored.

## Historical Telegram recipient composer and forward receipt

Telegram stays inside the shared service-selector/list/conversation window.
Forward now follows the reference's normal recipient-picker → recipient chat →
composer accessory workflow. Choosing a recipient only stages the intent;
explicit Send submits it with an optional rich comment. The recipient's ordinary
input/selection/reply survive staging and cancellation. Name/caption options and
source fingerprints persist in schema-4 account/chat drafts; schemas 1–3 remain
readable and unknown formats are preserved. Another recipient retains the old
chat's ordinary comment/reply. Native draft loading/error blocks editing/send;
the existing programmatic delayed-restore operations retain their compatibility.
A stale attachment picker cannot consume a newly staged forward draft.

The bound-account provider revalidates the complete source/destination/comment
batch after upstream media transforms. Native enqueue and exact owned accepted
receipt share one Postbox transaction. The optional reply applies only to the
comment. Nonempty unexpected IDs or post-admission receipt failure remain
uncertain; only a proven zero-queue rejection can return to prepared. Restart or
storage-only receipt checks consume acceptance without submitting again. This
single local batch is a documented Makosh adaptation: the reference chains
comment and forward operations separately. Queue acceptance does not prove
server delivery, fsync or power-loss safety.

`scripts/dev-db.sh up`, final `scripts/test.sh`, `scripts/build-app.sh` and strict
deep signature verification exit 0: **459 XCTest (396 Telegram + 63 core), zero
failures; 26 Python regressions**. New tests cover schema/limits, exact snapshots,
controller callbacks/deadlines, source/recipient permissions, rejected/uncertain
queue states, encrypted Postbox receipts and model navigation/recovery. The
final run prints 66 upstream SQL t19 teardown diagnostics without failure/trap.
An intermediate run failed in 15 existing composer-model cases (50 assertions):
an overly broad loading guard broke delayed-restore input/reply/upload APIs.
The boundary was corrected without weakening those tests; final gates pass.
Earlier retention-cleanup and upstream SQLite failures remain recorded below.

Actual native AX/screenshots verified the common window, recipient navigation,
rich comment plus existing reply, hidden name/caption, Mail → Telegram, cancel
retaining comment/reply, and process restart restoring the forward/options/input.
Command-Enter cleared the exact accepted draft. Explicit DEBUG lost-ACK injection
then left a frozen comment/accessory, disabled Send and a local-queue check;
process restart consumed the receipt and opened an empty composer. QA used the
same owned synthetic encrypted Postbox and isolated PostgreSQL/S3, with matching
unsigned executable payload and strict signatures. The synthetic provider writes
StoreMessages/receipts but does not execute a live Account's enqueue algorithm.
No personal account, Keychain, Telegram network or server send was used.

Root reviewed the integration diff and corrected an unsafe synthetic post-write
rejection and recipient permission checks before final gates. Worker source
checks are distinct from root runtime gates; observed model/provider/usage remain
unknown. Saved Messages' immediate-forward exception, multi-selection UI,
topics/paid/secret content, combined new attachment + forward, actual IME and
live-account acceptance remain open. Later channels, backups and standalone
packaging remain open; the full migration goal is active. Previous head 0992ea0
passed both hosted PR/push CI runs; current-slice hosted CI is separate.

Final project XERJ refresh exits 0: 258 files, 228/228 classified code. Actual
staging/receipt/batch queries were confirmed against current source; project,
engine and TelegramSwift fingerprints are fresh. The publication audit checked
263 publishable files and the private PR body against five selected credential
fields, with zero matches. Machine configuration, research clones and QA data
remain excluded from publication.

## Historical in-process edit sessions — 2026-10-11

Telegram remains inside the shared service-selector/list/conversation window.
Its active edit now belongs to the account-context model, with independent chat
sessions retaining source, exact rich input and scalar-safe UTF16 selection.
Chat/service switches restore the edit while ordinary input/reply stay separate.
Explicit Cancel discards that edit and its exact source cache; reopening starts
from the message original. Changed source fingerprints have separate cache keys.
Account stop clears all temporary sessions/cache; restart does not restore edit.
The reference's AccountContext temporary state and cancellation paths were
source-confirmed through XERJ; no outer GPLv2 UI/serializer code was copied.

Applied acknowledgement closes only the session/revision/input captured before
provider admission, including synchronous callbacks and a different selected chat.
Newer text/formatting/selection or a replacement session survives. Rejection and
uncertainty retain the active edit without automatic retry. Source validation
still uses current Postbox. Unlike the reference's normal edit clearing at local
commitment, Makosh waits for its existing provider's applied event.

Final `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh` and strict
signature verification exit 0: **432 XCTest (369 Telegram + 63 core), zero failures;
26 Python regressions**. Seven new model tests cover independent chats, source
versions, stale context/session calls, selection/formatting, cancel/reopen,
ordinary reply isolation, synchronous/late ACK, rejection/uncertainty and account
stop. A failing regression first exposed the old cached text after account stop;
clearing that cache fixes it. The full run prints 46 upstream t19 teardown
diagnostics. An intermediate full run failed in an existing retention fixture's
temporary-directory cleanup (NSCocoaErrorDomain 513 / EPERM); its six-test probe
and subsequent full runs pass. The cleanup cause remains unconfirmed; the failed
run is retained. Historical upstream SQLite trap evidence remains below.

Actual native AX/screenshots verified two independent edits; bold text/selection
across Mail → Telegram and chat switches; Cancel returning the original ordinary
reply; reopening from source; Command-Enter applied; and process restart resetting
edit while retaining the ordinary reply. QA used explicitly owned synthetic
Postbox and isolated PostgreSQL/S3, matching executable payload/strict signatures.
After the final cache-reset correction, the matching final payload repeated
rich edit/selection across services and Cancel returning the ordinary reply;
account-context cache clearing is established by the focused regression/full run.
No personal account, Keychain, Telegram network or server send was used.
Topic navigation, actual IME, other Telegram parity/live-account acceptance,
later channels, backups and standalone packaging remain open. The full migration
goal stays active. Prior head 59c554c passed both hosted PR/push CI runs; hosted
CI for this slice is separate. Worker route/usage metadata remains unknown;
root performed integration gates and native acceptance.

## Historical send-key preference — 2026-10-11

The next reference slice adds the application-wide Enter / Command-Enter choice
to native Settings and the shared rich editor. Ordinary/reply, inline edit and
attachment captions explicitly use their existing guarded submit actions. Both
physical Return keys follow the reference modifier policy; marked text stays
with the native text system. Unmatched Command/Shift Return inserts a newline.
The default remains Enter, and unknown stored values fall back without rewriting
the stored preference. No account or server setting is involved.

`scripts/dev-db.sh up`, focused `scripts/test.sh --filter TelegramSendKeyTests`,
full `scripts/test.sh`, `scripts/build-app.sh` and strict deep signature verification
exit 0. **425 XCTest (362 Telegram + 63 core), zero failures; 26 Python regressions**.
Three new tests cover all 256 independent modifier combinations on both Return
keys, marked-text refusal and isolated preference persistence. The full run
prints 46 upstream SQL t19 teardown diagnostics without a test failure/trap.

Actual native AX/screenshots verified both settings choices, Command-Enter reply,
edit and caption submit, Return/keypad Enter reply submit, rejected Command/Shift
Return newlines and native newline undo. The selection survives process stop/
relaunch, updates an already open editor, and retains the new draft across the
shared Mail → Telegram switch. QA used the same explicitly owned synthetic
Postbox, isolated PostgreSQL/S3 and a bundle with matching unsigned executable
payload/strict signatures. These are synthetic actions, without personal account,
Keychain, Telegram network or server send. Actual IME input-source acceptance
remains open; the policy test only proves its marked-text guard.

Root verified two worker implementation/test hashes and seven independent review
hashes. No confirmed scoped findings remained; worker runtime gates were SKIP,
observed model/provider/usage unknown. Source-confirmed XERJ queries and final
freshness checks are recorded privately. The preceding atomic-receipt commit
f47717a passed both hosted PR/push CI runs; this slice's hosted CI is separate.
Final project refresh exits 0: 246 files, 216/216 classified code; the current
policy/editor queries are source-confirmed. Project/reference/engine freshness
checks exit 0. Publication audit checked 251 publishable files and the private
PR body against five selected local credential fields, with zero matches.
Other Telegram parity and later channels remain open in [migration-plan.md](migration-plan.md).

## Historical atomic queue receipt — 2026-10-11

Telegram remains inside the shared native service-selector/list/conversation
window. New file/photo submissions pass their exact preparation UUID to the
provider. Preparation recipe 6 adds hash-checked optional admission/commit hooks
to the pinned native enqueue API; its original media transformation and default
callers remain intact. The owned pointer is checked before enqueue, and accepted
receipt is written beside the queue message in the same Postbox transaction.
Receipt requires one existing outgoing Local message in the captured chat with
exact UTF8 caption/native entities. Scoped pending metadata, original draft,
selection/reply and archived file survive unchanged. Hook construction is
nonisolated; only UI observations return to MainActor.

After a lost UI callback, restart can read the committed receipt and acknowledge
only the original draft revision without resubmitting. Duplicate/stale/foreign/
malformed/cancelled pointers refuse admission. Unexpected nonempty IDs or a
receipt refusal after addMessages remain uncertain, without a rollback claim.
Older submissionStarted records remain uncertain: the pinned engine's
correlation-to-sent-ID mapping lives in process memory and is not restart proof.
No server delivery/read or power-loss/fsync guarantee follows from queue admission.

Current gates: `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh`
and strict deep signature verification exit 0. **422 XCTest (359 Telegram +
63 core), zero failures; 26 Python regressions**. Three new encrypted Postbox
tests cover queue/receipt reopen before UI ACK, duplicate refusal, scope/state/
caption/reply/file checks, orphan/incoming/wrong-content messages and malformed
native results without fabricated ACK. A controller regression covers stale
preparation during rebind; expanded assertions verify frozen UUID/input and
storage retries without resubmission. Two new Python checks pin the adaptation
and reject changed source. The full suite prints 46 upstream SQL t19 teardown
diagnostics; no test failure or trap occurred in this run.

Actual native AX/screenshots used the same explicitly owned synthetic Postbox
and isolated PostgreSQL/S3. The QA executable's unsigned payload matches the
built app and strict signatures pass. The explicit DEBUG lost-ACK fixture
commits a synthetic StoreMessage/receipt, then hides acceptance from the UI.
Verified: edited/bold caption with immutable original, uncertain modal without
Send, process stop/relaunch, no recovered resend modal, original revision
cleared, newer draft surviving a second restart and Mail → Telegram in the same
window. No personal account, Keychain, Telegram network or actual send was used.
The synthetic transaction does not execute a live Account's queue algorithm.

Root verified eight worker source/test hashes and the final eleven-file readonly
review. Two source findings (orphan-message acceptance and UI-actor hook creation)
were corrected before the full run. Review gates remain SKIP for workers; runtime
model/provider/usage are unknown. Engine refresh exits 0, 721 files/686 code;
actual hook/reference queries were confirmed against pinned source. Prior head
5304893 passed both hosted PR/push CI runs. Live queue/cloud-ID reconciliation,
other Telegram parity, later channels, backups and standalone packaging remain
open in [migration-plan.md](migration-plan.md). The full migration goal is active.

Final project refresh exits 0: 243 files, 213/213 classified code files, with
source-confirmed receipt/provider queries. Project, engine and reference content
freshness checks exit 0; mutable status remains outside the index. Publication
audit checked 248 publishable files and the private PR body against five selected
local credential fields, with zero matches.

## Historical pending attachment runtime — 2026-10-11

Telegram's runtime now saves an owned pending file/photo to encrypted S3 with
PostgreSQL metadata, then keeps caption/entities/selection, original revision,
reply target and lifecycle in the account/chat Postbox pointer. Serial writes
remain bound to the original repository after UI cancellation or account changes.
Initial storage gates send; the latest caption and `submissionStarted` persist
before provider admission. Durable `.accepted` gates the original draft ACK.
A failed acceptance-save retry only saves storage; it never resubmits. Restored
`submissionStarted` is uncertain and cannot send automatically. A current reply
source is resolved again before prepared recovery. Ordinary send/actions and
attachment admission are blocked while recovery is loading or has failed.
Cancellation tombstones retain archived bytes; a failed cancellation is visible
outside the dismissed modal and offers a storage-only retry.

Current gates: `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh`
and strict deep signature verification all exit 0. **418 XCTest (355 Telegram +
63 core), zero failures; 24 Python regressions**. Thirteen runtime regressions
cover ordering, cancelled callers, scope/transition refusal, exact original ACK,
stale account/chat loads, missing reply, prepared/uncertain restoration, failed
acceptance-save and cancellation retry without resubmission. The passing full
suite prints 40 upstream SQL t19 teardown diagnostics. Earlier compile failures
and a staging-cancellation regression were fixed; one full run also trapped at
upstream `SqliteValueBox.swift:458`. Its six-test retention probe and two subsequent
full suites passed; the isolated assertion's cause remains unconfirmed.

Native acceptance used the same explicitly owned synthetic Postbox and isolated
PostgreSQL/S3, with an injected synthetic encryption key. The QA executable's
unsigned payload matches the built app and both bundles pass strict signatures.
Actual AX/screenshots verified the shared service selector, native file choice,
file modal, edited rich caption/selection recovery after process stop/relaunch,
Escape returning the original draft, no cancelled resurrection after another
restart, normalized JPEG/preview/caption recovery, synthetic queue ACK clearing
the original, no accepted recovery modal after restart, and Mail → Telegram in
the same window. File choice initially left Open disabled; explicitly setting
allowed content types for both file/photo modes fixed the observed flow.
No personal account, Keychain, Telegram network or actual send was used.
Root verified all 12 current worker source/test hashes across bounded handoffs
and read-only reviews. Two source findings (hidden cancellation error and ordinary
send bypass during recovery) were fixed and covered; no later scoped findings
were reported. Workers skipped runtime gates; observed model/provider/usage remain
unknown. Final project refresh reports 239 files, 209/209 code (exit 0), with
source-confirmed runtime/reference queries. Mutable status is excluded from indexing.
Project/reference/engine freshness checks exit 0. Publication audit checked 244
publishable files and the private PR body against five selected local credential
fields, with zero matches.

Unit/storage tests establish conservative unknown-result handling; native
unknown-result/fault-injection and live queue reconciliation remain unverified.
Transaction completion does not prove fsync, power-loss or disk-full acceptance.
Other Telegram parity/live-account gaps, later channels, archive/key backup and
standalone packaging remain open in [migration-plan.md](migration-plan.md).
The full sequential migration goal remains active.

## Historical pending attachment storage foundation — 2026-10-10

Telegram remains in the shared native workspace. Recovery adapters now preserve
an owned pending file/photo in encrypted S3 with authenticated PostgreSQL metadata
and a separate account/chat Postbox schema-1 pointer containing typed caption,
selection, original draft, reply target and lifecycle disposition. Revision CAS,
exact-byte retry and cancellation tombstones protect existing data. The opaque
`pending-upload:<UUID>` identity is a draft resource, not a received-message event
or engine mutation target. Cancellation retains the immutable archived bytes.

Current checks: `scripts/dev-db.sh up`, `scripts/test.sh`,
`scripts/build-app.sh` all exit 0; **405 XCTest (342 Telegram + 63 core), zero
failures; 24 Python regressions**. Seven new tests include actual encrypted
Postbox release/reopen, real PostgreSQL/S3 file and exact normalized-JPEG restore,
unknown/foreign payload preservation, CAS/ABA/idempotence and a combined
caption/selection/reply/submissionStarted/file recovery with cancellation/archive
retention. The passing suite prints **40 upstream SQL t19 teardown diagnostics**.
Strict deep bundle signature verification exits 0. Final project XERJ refresh
exits 0 (**234 files, 204/204 code**); project/reference/engine fingerprints and
source-confirmed recovery queries are current. Publication audit checked
**239 publishable files** and the private PR body against five selected local
credential fields, with zero matches.
Readonly cross-reviews of the seven changed source/test files found no scoped
defects; workers did not run the integration gates and observed model/provider/
usage remain unknown. This storage change does not alter a native UI flow;
the previous modal UI acceptance is recorded below, not relabeled as recovery
acceptance.

Runtime/model/UI recovery wiring, saving before submission, current reply
resolution and uncertain queue reconciliation remain the next slice. Neither
this adapter nor its `submissionStarted` value proves crash/power-loss or live
delivery acceptance. Telegram's other recorded gaps, later channels, archive/key
backup and standalone packaging remain open in [migration-plan.md](migration-plan.md).
The full sequential migration goal remains active.

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

## Telegram visible-history reads and durable pending sync — 2026-10-10

The common workspace now applies native interactive read through an actually
visible stored cloud message. Own geometry follows the reference's 10-point
visible-height tolerance; stored outgoing rows can read preceding incoming
messages. Search, loading/timed-out pages, pending/failed/local/scheduled rows
and stale account/chat/request observations cannot supply the boundary. Native
peer identity is preserved for associated old history in a migrated group.
The AppKit bridge checks current window eligibility immediately before the
MainActor model call. Weak callbacks expire on detach/dismantle, and a mount
token republishes eligibility after returning to Telegram without update loops.

An encrypted Postbox reopen regression exposed a pinned-engine defect: a signed
SQLite full-table range `key > 0 AND key < -1` reloaded no pending read operations.
Preparation recipe 5 uses a hash-checked integer-key scan. The failing reopen
assertion was retained and now passes; no database schema or account data is
changed. The engine pin, reference-folder independence and license boundary
remain unchanged. Local transaction completion is not a server read receipt.

Actual evidence:

- `scripts/dev-db.sh up`: exit 0, PostgreSQL/S3 healthy. Recipe-5 preparation:
  exit 0, 21 packages; the verified recipe-4 generated directory was preserved
  under an unused ignored backup name before rebuilding from the locked source.
- Final `scripts/test.sh`: exit 0, **305 XCTest (242 Telegram + 63 core),
  0 failures**, plus **24 Python regressions**. Twelve new Swift tests cover
  geometric admission, full MessageIndex ordering, pending/rebind callbacks,
  stale/model/search boundaries, migrated-peer identity and real encrypted
  Postbox read-state/pending-push persistence after release/reopen. Read marking
  preserves content/version and journal events; native cross-namespace timestamp
  behavior and the untouched other peer are checked. Twenty upstream t19
  fixture-teardown diagnostics follow the passing Telegram suite.
- Intermediate failures remain private: the original pending-push reopen
  assertion, an absent outer-reference MessageIndex initializer, and a new
  test incorrectly passing the synthetic account sentinel into native PeerId
  mapping. The fixture now maps with a valid ordinary cloud identity while
  retaining its synthetic model/provider context. None is relabeled a pass.
- Final `scripts/build-app.sh`: exit 0; ad-hoc signing and strict verification
  passed. The full suite preceded the final UI-only remount correction;
  subsequent final build and native QA cover that correction. Temporary boolean
  diagnostics were removed and the reviewed source hash restored before the
  final build. No diagnostic flag or logging was added to product source.
- Final synthetic QA executable payload matched the built app; exact process
  arguments and isolated PostgreSQL configuration were verified. Native AX and
  screenshots established **12 focused conditions**: shared service selector,
  initial/query search with zero read admissions, active history admission,
  exact draft input, honest unconnected mail, restored active observer on return,
  retained selection/draft, no duplicate boundary, profile sheet opening/return
  and cleared synthetic draft. In History selected message 81 in window 32...81.
  That fixture does not prove a visible boundary below the loaded window's end;
  bounded admission is covered by the separate model/geometry regressions.
- A temporary private boolean trace on synthetic UI confirmed key=false and
  attachedSheet=true produce inactive admission, and closing it restores active
  reading. Source review also found/fixed a stale cached eligibility race and
  missing republish after remount. Final source review found no further confirmed
  issue; workers did not run root runtime gates. Model/provider/usage metadata
  remain unknown; no quorum was used.
- The computer-use secondary-action route restarted a QA app without its
  parameters and reached a database setup error; those runs were discarded.
  Unique fixture identities and direct executable launch with explicit synthetic
  arguments resolved process attribution. A capture error during search was
  followed by AX confirmation of the exact query/result. Coordinate focusing
  remains unavailable. No personal account, Keychain, private Telegram content
  or Telegram network/send was used.
- Final project XERJ refresh/check: exit 0, **186 files, 156/156 code**;
  prepared recipe-5 engine and locked TelegramSwift freshness passed. Actual
  context/admission/window-gate queries were checked against source; sibling
  Postbox remains directly audited, outside the TelegramCore index scope. Root
  verified all fourteen reviewed source hashes. The publication audit checked
  four selected local secret fields against **191 publishable files** and the
  private PR body, with zero matches.

Secret/topic read handling and live server receipts remain unimplemented or
unverified. Minimize/hide/occlusion matrices, remaining reference screens,
archive file opening/backup, earlier dossier GUI acceptance and later channels
remain open. The sequential migration goal remains active.

The shared-sidebar head `027e5baa4c940503dd56ff45493f8c04b5ff0bbb` passed
[PR CI 38075646435](https://github.com/Mesteriis/makosh-native/actions/runs/38075646435)
and [push CI 38075644661](https://github.com/Mesteriis/makosh-native/actions/runs/38075644661).
Hosted CI for this read-marking change is tracked after publication.

## Retained S3 attachment preview — 2026-10-10

The existing local archive now offers **Посмотреть** beside **Сохранить из
архива…**. It reads the retained S3 copy through the authenticated repository
export boundary, then presents native Quick Look inside a SwiftUI sheet. It
requires no Telegram authorization or cache fetch. Each preview owns an
independent 0700 directory/0600 plaintext file; a sanitized display title is
separate from the generic disk basename and bounded ASCII extension. Quick
Look's item retains the lease until the view closes. Cancellation/failure removes
partial files, and ordinary dismissal releases the plaintext without removing
the encrypted S3 object. Forced termination/crash cleanup is not guaranteed.

Reference XERJ retrieval and source reads confirmed TelegramSwift's
`ChatFileContentView.swift:79–99` and `QuickLookPreview.swift:68–145` native
file-preview workflow. The archive sheet/lease are own code; no outer GPLv2 UI
was copied. Normal Telegram remains in the shared WorkspaceView service
selector/list/conversation layout; the standalone S3 route is a DEBUG QA fixture.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; development PostgreSQL/S3 available.
- `scripts/test.sh`: exit 0, **308 XCTest (245 Telegram + 63 core), 24 Python**.
  Three new regressions exercise real isolated PostgreSQL/S3 with deterministic
  synthetic keys: cache unlink plus a deletion event, new repository instance,
  forged metadata rejection, private modes, hostile labels, independent leases,
  failure and cancellation cleanup. Upstream t19 teardown diagnostics remain
  separately visible after the passing Telegram suite.
- `scripts/build-app.sh`: exit 0, Debug build and strict ad-hoc signature check.
  The final build includes the additional export cancellation-publication guard;
  this UI-only guard followed the full test run. Native QA confirmed Save-panel
  cancellation before export, not cancellation after export completes. No
  release-signing/notarization claim is made.
- Final native QA used an explicitly isolated synthetic S3/PG fixture, unique
  bundle identifier, exact executable/config flags and verified unsigned payload.
  **14 recorded conditions passed**: Quick Look displayed the exact retained
  text/bytes after the fixture deleted its source cache; private modes matched;
  button close removed the first directory, reopen created a different lease,
  Escape removed it, Save panel opened/cancelled, and archive dismissal returned
  to the fixture. Screenshots confirmed the existing archive actions and preview.
  No private account, Keychain or Telegram network/send was used.
- Fresh project/engine/reference index checks preceded source selection; project
  refresh completed exit 0 with **189 files, 159/159 classified code**. Root
  verified all six reviewed source hashes. Private worker records retain route
  and usage as unknown; no quorum was used.

Native dismissal while an S3 fetch is still in progress was not established by
this fast local fixture; the cancellation seam is covered by regression tests.
Quick Look format coverage beyond synthetic text, large-media performance,
crash cleanup, portable archive/key backup and the remaining Telegram/reference
features are open. The sequential migration goal remains active. Hosted CI is
checked separately for each published head.

## Reactive Telegram peer cards in the shared workspace — 2026-10-10

The existing conversation-header card now supports people, bots, basic groups,
supergroups and channels. It follows the selected reference's native peer-view
subscription and displays available descriptions/counts, distinguishes unknown
counts from zero, and preserves native scam/fake warnings while hiding their
descriptions. The engine maps the peer/cache observation to an immutable
Sendable DTO before main delivery. Account/chat/request and exact-snapshot guards
remain active for subsequent updates. Closing the card or leaving Telegram
disposes observation; an already issued engine RPC is not claimed cancelled.
Groups, channels and bots cannot be attached to a person dossier, including at
the workspace write boundary. The existing person linking workflow remains.

Normal Telegram stays inside WorkspaceView: shared service selector, dialog list
and conversation. The new DEBUG fixture uses that same root and an explicitly
isolated PostgreSQL schema, without personal account or Telegram network access.
No outer GPLv2 UI/assets were copied and no research-folder runtime dependency
was added.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; PostgreSQL/S3 healthy.
- Final `scripts/test.sh`: exit 0, **312 XCTest (249 Telegram + 63 core),
  0 failures; 24 Python regressions**. Mapping tests cover native peer kinds,
  description/count availability, namespace rejection and scam/fake suppression.
  Three new model regressions cover later guarded updates, initially unavailable
  data recovering on the same request, and dismissed/reloaded request rejection.
  An actual encrypted synthetic Postbox test observes initial and changed
  name/about values. It does not exercise a real Account/ViewTracker RPC or a
  separate group/channel cached-data update integration. Twenty upstream t19
  fixture-teardown diagnostics remain separately visible after the passing suite.
- Intermediate compile failures remain private: passing a native PeerView across
  actor isolation, using a switch directly as an argument, and an incorrectly
  named engine flag type in a test. Moving DTO mapping before main delivery,
  assigning the switch value and using pinned `UserInfoFlags` resolved them.
- Final `scripts/build-app.sh`: exit 0, signed Debug build with strict ad-hoc
  verification. No production edits followed the passing full tests/build.
- Native AX and screenshots established **11 focused conditions**: group,
  channel, supergroup, bot, unknown count, zero count, preserved person dossier
  action, exact draft input, honest unconnected mail, retained chat/draft after
  Mail/Telegram switching, and profile reopening after return. The draft was
  cleared afterward. Root verified the copied unsigned executable payload,
  exact synthetic process arguments and private isolated configuration. No
  personal account, Keychain, private Telegram content or Telegram send was used.
- Final project XERJ refresh/check: exit 0, **191 files, 161/161 classified code**;
  prepared engine and locked TelegramSwift freshness checks passed. Retrieved
  peer-view, description and count behavior was confirmed against current source.
  Root verified all eleven final reviewed source/test hashes. Worker runtime
  gates were not run; route/model/usage remain unknown and no quorum was used.
- `git diff --check`: exit 0. Publication audit checked **196 publishable files**
  and the private PR body against five selected local credential fields, with
  zero matches. Hosted checks are recorded separately for the published head.

Live server-refresh acceptance, secret-chat profiles, photos/presence, member
lists/administration, other reference screens, archive/key backup and subsequent
channels remain open. The sequential migration goal remains active.

The preceding head `fc12c2d84b4fec9242acb00204711a16ba270ccd` passed
[PR CI 38077756700](https://github.com/Mesteriis/makosh-native/actions/runs/38077756700)
and [push CI 38077753148](https://github.com/Mesteriis/makosh-native/actions/runs/38077753148).
These results do not establish hosted CI for the new peer-card change.

## Static Telegram avatars and cached peer status — 2026-10-10

Telegram remains inside the shared WorkspaceView. Dialog rows, the conversation
header and peer cards now show native static small/large photos, with initials
for absent/invalid images. Account-bound peer/resource observations replace old
fetches on photo changes; complete-file events are decoded through bounded
regular-file/ImageIO admission. Profile photos are transient MediaBox cache;
retained message attachments still use encrypted S3 with PostgreSQL metadata.
No outer GPLv2 UI/assets or research-folder runtime dependency were added.

The header/person card now presents cached native presence with privacy buckets,
self/bot/support/service conventions, optional counts and cancellable expiry
refresh. Server offset affects comparisons/deadlines; absolute last-seen dates
retain native Unix time. Account/chat/visibility changes dispose selected-peer
observation and reject stale events. Relative hours/today/yesterday wording,
animated avatars, profile galleries and list online badges remain open.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; PostgreSQL/S3 healthy.
- Final `scripts/test.sh`: exit 0, **331 XCTest (268 Telegram + 63 core),
  0 failures; 24 Python regressions**. Nineteen new tests cover native avatar
  mapping, replacement/account/cancellation guards, image admission, presence
  expiry/server-offset/date/count mapping and selected-peer lifecycle/recovery.
  The first fixture compile failed on PeerId namespace typing; it was fixed.
  Twenty upstream t19 teardown diagnostics remain separately visible.
- Final `scripts/build-app.sh` and strict ad-hoc signature verification: exit 0.
  A final UI-only accessibility-label correction followed the full suite and
  was covered by this build and the native checks. This is a Debug build;
  release/notarization is not established.
- Native AX/screenshots verified **19 focused conditions**: shared workspace,
  accessible header online, list/header photo, profile photo/status/dossier,
  no-photo group initials/count, corrupt-photo channel initials/count, initial
  short online, automatic expiry without switching, approximate presence,
  unavailable presence, hidden self status, bot status, unknown channel count,
  zero group count, exact draft input, honest unconnected mail, retained
  chat/draft/status on return, cleared draft and profile reopening. Unsigned
  copied/built payloads matched and exact synthetic process/configuration were
  verified. The explicit schema/private file contract was preserved. No personal
  account, Keychain, Telegram network or Telegram send was used.
- Root verified all **14 final reviewed source/test hashes** and reviewed the
  complete change. Worker runtime gates were not run; observed provider/model
  and usage remain unknown, with no quorum. Root owns passing integration gates.
- Project XERJ publication refresh/check covers **203 files, 173/173 code**;
  engine and locked TelegramSwift freshness checks passed. Actual source queries
  confirmed the avatar/controller definitions and reference presence timer.
  One query used an incorrect prefix and returned no matches; the verified
  prefix returned the reference. This is not compiler-grade call-graph evidence.

Native pending-fetch timeout, a real Account/ViewTracker/network lifecycle and
clock changes without new peer emissions were not exercised. Decoder admission
is capped at 2 MiB; native network bytes are not capped by that admission limit.
Remaining Telegram/reference features, archive/key backup and subsequent channels
remain open. The full sequential migration goal remains active. Publication
secret audit and hosted CI are recorded separately for the actual published head.

The preceding head `41bd0f1d3d9d5e13b0d1144034c7c806dc8441ad` passed
[PR CI 38078692061](https://github.com/Mesteriis/makosh-native/actions/runs/38078692061)
and [push CI 38078688295](https://github.com/Mesteriis/makosh-native/actions/runs/38078688295).
These results do not establish hosted CI for this avatar/status change.

## Static peer-photo gallery and calendar presence — 2026-10-10

The peer-card avatar now opens a static native-photo gallery inside the shared
WorkspaceView. Its guarded account session supplies immutable metadata and
complete-file events, prefers cached personal/photo data, uses a current-avatar
fallback and preserves historical avatar-list references. The gallery offers
name/date/position, partial total count, mouse/keyboard navigation and separate
list/image retry. Empty RPC results remain ambiguous in the UI. Closing, changing
the peer or rebinding the account cancels the selected lease/session and rejects
late results. Synchronous list callbacks are covered. These transient MediaBox
photos are separate from retained message attachment bytes in encrypted S3.

Cached presence now follows reference calendar wording: same-day hours,
yesterday with local time, then day/month/year. Hour, midnight and year refresh
deadlines preserve native Unix timestamps and account for server offset and
23/25-hour DST days. No new personal-account access is involved.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; existing PostgreSQL/S3 healthy.
- Final `scripts/test.sh`: exit 0, **344 XCTest (281 Telegram + 63 core),
  zero failures; 24 Python regressions**. Thirteen new tests cover native photo
  mapping, cache/reference fallbacks, list/image/context cancellation and stale
  events, corrupt-image recovery, synchronous callbacks, navigation bounds,
  current-profile admission and calendar/offset/DST boundaries. Initial mapping
  compilation failed on inherited optional Media.id; native imageId fixed it
  before the passing run. Twenty upstream t19 teardown diagnostics remain
  separately visible.
- Final `scripts/build-app.sh` and strict ad-hoc signature verification: exit 0.
  Native QA first found a blank gallery title. The final UI-only fix passes the
  name in an immutable Identifiable sheet item; this followed the full suite
  and was covered by the final build and actual native checks below.
- Final native AX/screenshots verified **25 focused conditions**: common service
  selector; avatar/dossier actions; named gallery; initial position/date/partial
  count; first image proportions; second photo/video-frame label; keyboard-right
  corrupt third image without stale pixels; selected-image retry; recovered image
  proportions; keyboard-left; mouse-back/boundary; Escape to profile; reopening
  at the first photo; mouse close; profile close preserving conversation; empty
  gallery without old pixels; empty retry; correct group-profile return; hours;
  yesterday; exact draft input; honest disconnected mail; retained chat/draft/
  status on return; draft cleanup; and gallery reopening after service switching.
  An initial QA assertion incorrectly expected a person-link action on the
  group card; actual group return was reinspected and correctly verified via its
  not-person state. This was an assertion correction, not a product patch.
  Unsigned final copied/built payloads matched. Root verified mode-0600 explicit
  isolated configuration and exact synthetic process flags. No personal account,
  Keychain, Telegram network or send was used.
- Root reviewed the complete change and verified **11 final worker-reviewed
  source/test hashes**, including the final title fix. The two new appearance
  fixtures were reviewed by root. Worker runtime gates were not run; observed
  model/provider and usage remain unknown, with no quorum. Root owns integration
  checks; private evidence remains outside Git.
- Final project XERJ refresh/check: exit 0, **210 files, 180/180 code**.
  Engine and locked TelegramSwift fingerprints are current. Actual final query
  retrieved the gallery controller and model opening guard, confirmed against
  source. `git diff --check` passed. Publication audit checked **215 publishable
  files** and the private PR body against five selected local credential fields,
  with zero matches. Hosted CI is recorded for the exact published head separately.

The gallery currently uses a sheet. Reference fullscreen/transition, thumbnail
strip, zoom/rotation/save/share, extra public fallback photos, stories, animated
avatars and list online badges remain open. The engine returns a bounded first
page; complete photo-history pagination is not claimed. Gallery decoder admission
is 20 MiB/8192 pixels per dimension/40 MP/1280-pixel thumbnail, not a network-byte
cap. Native pending-fetch timeouts, real account/server refresh and clock changes
without peer emissions remain unverified. Archive/key backup, other Telegram
screens and later channels remain open; the sequential migration goal is active.

The preceding avatar/status head `3eb5b6e3ea51ce1050cd6d083a5932c5fbfc35c0`
passed [PR CI 38079890192](https://github.com/Mesteriis/makosh-native/actions/runs/38079890192)
and [push CI 38079886120](https://github.com/Mesteriis/makosh-native/actions/runs/38079886120).
These results do not establish hosted CI for this gallery change.

## Screen-sized profile gallery, thumbnails and original export — 2026-10-10

The shared workspace's peer-card avatar now opens a separate borderless gallery
on the parent screen. A finite hosting-root frame preserves the screen size;
the SwiftUI request and a narrow AppKit coordinator own window/session cleanup
and focus restoration. Reference controls include a 95-point footer, real lazy
thumbnails, 0.25–8 zoom with 0.5 steps, bounded pan, rotation and original-file
Save. Keyboard arrows, minus/equal, Cmd-R/Cmd-S, Escape/Space and Cmd-W are scoped
to the gallery. Apple SDK virtual-key constants preserve them with Cyrillic input;
the native Save panel keeps its own keyboard handling.

Small native representations have independent leases, a 32-job cap and bounded
decoding. Save detects the original representation's format and verifies its
SHA256 during the atomic streaming copy. A same-size mutated cache is rejected
before destination replacement. Navigation/transforms are blocked while saving;
close cancels owned work. Cancellation after committed rename cannot undo export.
These photos remain transient MediaBox data, separate from encrypted S3 message
attachment retention. Profile share is absent consistently with reference nil
chatMode. No reference code/assets or new third-party dependencies were copied.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; PostgreSQL/S3 available.
- `scripts/test.sh`: exit 0, **348 XCTest (285 Telegram + 63 core), zero failures;
  24 Python regressions**. Four new regressions cover independent thumbnail/full
  leases, exact original bytes/format, stale/rebound/released callbacks,
  metadata replacement/invalidation, and same-size cache mutation preserving the
  existing destination and cleaning temporary files. Twenty upstream t19 teardown
  diagnostics remain separately visible after Telegram tests pass.
- Final `scripts/build-app.sh` and strict ad-hoc signature verification: exit 0.
  Full tests preceded the final UI-only fixes; those fixes were verified by the
  final build and native scenarios. Native QA first found a 510×266 fitting-size
  window. A finite root frame plus reapplying the screen frame fixed it. Standalone
  SwiftUI shortcuts then failed; explicit window routing and physical virtual keys
  fixed actual Russian-layout key delivery. Temporary synthetic diagnostics were
  removed. A modal-window hypothesis was disproved and its change removed.
- Final native AX/screenshots verified **33 focused conditions**: common selector;
  profile/dossier entry; initial title/date/position/partial count/boundary;
  keyboard zoom/rotation and zoom-out; both zoom limits; thumbnail selection with
  reset/video label; corrupt image with disabled actions; retry; keyboard-back;
  actual fullscreen composition/proportions/thumbnail pixels; mouse-back/boundary;
  visible drag pan; Cmd-S; Save cancel preserving the gallery; original Save after
  transform; Escape; reopen reset; Cmd-W; Space; mouse-close/conversation return;
  empty state/retry/group return; exact draft input; honest disconnected mail;
  retained chat/draft on return; draft cleanup; reopen after switching; mouse
  zoom/rotation. Exported PNG is **900×640, 11,897 bytes, mode 0600**, despite a
  90-degree/200-percent preview. Payload hashes of the copied and built app match;
  the explicit isolated PostgreSQL configuration and synthetic process flags were
  verified. No personal account, Keychain, Telegram network or send was used.
- Root reviewed the complete source/test change and verified **9 current
  worker-reviewed hashes**, including the final window/keyboard fixes. Worker
  runtime gates were not run; observed provider/model and usage remain unknown,
  with no quorum. Root owns integration results; private evidence stays ignored.
- Final project XERJ refresh/check: exit 0, **211 files, 181/181 code**. Engine
  and TelegramSwift fingerprint checks passed. The final actual query retrieved
  the window's command handler/ownership, confirmed against current source.
  `git diff --check` passed. Publication audit checked **216 publishable files**
  and the private PR body against five selected local credential fields, with
  zero matches. Hosted CI is recorded separately for the published head.

Pinch, multiple displays/display changes, native pending-fetch deadlines and real
account/server delivery remain unverified. Avatar transitions, precise theme/
hover/thumbnail animations, additional F mode, public fallback/stories/video,
first-page photo pagination, archive/key backup, other Telegram workflows and
later channels remain open. The full sequential migration goal remains active.

The preceding static-gallery head `83796c729eb6406374eddaf062b44231ad45ad81`
passed [PR CI 38080923160](https://github.com/Mesteriis/makosh-native/actions/runs/38080923160)
and [push CI 38080920058](https://github.com/Mesteriis/makosh-native/actions/runs/38080920058).
These results do not establish hosted CI for this fullscreen-gallery change.

## Reference chat-list online badges — 2026-10-10

Telegram remains inside the shared channel selector/list/conversation workspace.
The list now displays own 12/8-point online circles at the reference avatar
position, with a selected variant. A dedicated immutable account/chat observation
preserves the reference's self/exact CloudUser 777000 exclusions, inclusive native
integer seconds, truncated server offset and recently-activity expiry. It does
not reuse the header formatter's different bot/support/service policy.

Normal chat entries supply reactive native presence without extra per-row peer
subscriptions. Search owns one cached combined presence view, disposed when its
query/folder/account is replaced; associated presence retains the original chat
identity. Row expiry tasks cancel with the view and recalculate on device clock,
wake and scene activation. No reference UI/assets or new dependencies are copied.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; local PostgreSQL/S3 available.
- `scripts/test.sh`: exit 0, **353 XCTest (290 Telegram + 63 core), zero failures;
  24 Python regressions**. Five new tests cover exact boundaries/offset rounding,
  privacy buckets, overflow/nonfinite clocks, account/native namespace isolation,
  stale search request/folder guards, and a real encrypted Postbox combined view
  through missing/present/none/recently/activity updates and disposal. Twenty-two
  upstream t19 teardown diagnostics and the prior unreachable-catch warning remain
  separately visible after passing tests.
- `scripts/build-app.sh` and strict ad-hoc signature verification: exit 0.
  Native AX/screenshots verified **14 focused conditions**: shared selector;
  initial timed presence; group absence; selected/unselected pixels; expiry
  without emissions; search presence/expiry; search beyond the first page;
  empty search without old badges; archive chat identity; pagination; exact
  synthetic draft input; honest disconnected mail; retained chat/draft/badge
  after channel switching; draft cleanup. The copied/built unsigned payloads
  match, with explicit mode-0600 isolated database configuration and synthetic
  flags. No personal account, Keychain, Telegram network or send was used.
  An initial offscreen AX timer observation was not counted. A fresh visible
  search row was observed before and 42.9 seconds after its fixed 30-second
  expiry, with no intervening UI actions; its badge disappeared while the
  adjacent long-lived status remained. Native input verification used exact
  pasted text after a typeText attempt did not establish the expected value.
- Root reviewed the entire patch and verified **10 current worker-reviewed
  source/test hashes**. Worker source/hash checks passed; workers did not run
  integration/runtime gates. Observed provider/model and usage remain unknown,
  without quorum. Root owns integration results and private evidence.
- Final project XERJ refresh/check: exit 0, **216 files, 186/186 code**. Locked
  TelegramSwift and prepared engine checks are fresh. The actual final query
  retrieved the new presence mapper/provider, confirmed against source.
  `git diff --check` passed. Publication audit checked **221 publishable files**
  and the private PR body against five selected local credential fields, with
  zero matches. Hosted CI is recorded separately for the published head.

Actual clock/wake events, server-offset changes without native emissions,
live-account presence delivery, exact theme/badge transitions and secret-chat
workflows remain unaccepted. The associated-peer test supplies the association
explicitly; it does not establish construction from a real secret peer. Gallery
transitions/theme/animations/F mode, fallback/stories/video and complete photo
pagination remain open, as do the other Telegram workflows, archive/key backup,
later channels and standalone packaging in `migration-plan.md`. The full
sequential goal remains active.

The preceding fullscreen-gallery head `7fa3117feae88a0d3258a3f77e6996497fc3afbd`
passed [PR CI 38082465063](https://github.com/Mesteriis/makosh-native/actions/runs/38082465063)
and [push CI 38082462388](https://github.com/Mesteriis/makosh-native/actions/runs/38082462388).
These results do not establish hosted CI for the list-presence change.

## Durable ordinary reply drafts in the shared workspace — 2026-10-10

Ordinary composer text and its typed reply target now share one versioned
snapshot in the selected account's encrypted Postbox. A reply with no text
survives restart. Schema 1 is readable and upgrades on the next save; unknown,
foreign or malformed bytes remain untouched. Restored identities resolve against
the current local message cache, including fresh text, author and capabilities.
An unavailable source retains the draft and offers Retry/Cancel while blocking
normal send and attachment selection. No cloud draft synchronization is added.

Reply ownership moved from the detail view to TelegramModel, so channel/view
recreation preserves it. Cancelling reply retains text; editing temporarily hides
the ordinary reply and cancellation returns it. Queue acknowledgements clear only
their captured revision, including protection against target-only changes and a
rejected second dispatch. Attachment preparation captures the same reply identity.
Reference ChatInterfaceState explicitly resets editState on restart; durable edit
mode is therefore not an outstanding parity requirement. Complete in-process
edit-mode restoration and rich ordinary input remain open.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; PostgreSQL/S3 available.
- Final `scripts/test.sh`: exit 0, **368 XCTest (305 Telegram + 63 core), zero
  failures; 24 Python regressions**. New coverage includes encrypted Postbox
  reopen/schema compatibility/fresh message resolution, missing source retention,
  stale identity/thread/request/account callbacks, synchronous completion,
  cancellation, and captured revision acknowledgement. Twenty-six upstream t19
  teardown diagnostics remain visible after passing Telegram tests; the prior
  unreachable-catch warning is unchanged.
- Final `scripts/build-app.sh` and strict deep signature verification: exit 0.
  The final native bundle's unsigned payload matches the built app. Native
  AX/screenshots verified **17 focused conditions**: common selector; text/reply
  restart; cancel retaining text; reply-only selection/restart; exact Unicode;
  honest disconnected mail; channel return; chat isolation/return; edit hiding
  reply and cancel restoring it; attachment reply/cancel; labelled simulated
  queue clearing both; clear surviving restart; synthetic draft cleanup. The
  same owned synthetic Postbox and explicit isolated PostgreSQL schema were
  reused after confirmed process exit. No personal account, Keychain, Telegram
  network or real send was used. Native attachment enqueue and live delivery
  were not accepted by this check.
- Native QA exposed an empty-search synthetic resolver that could not restore
  a valid target. It now uses a bounded message page around the exact identity;
  a regression exercises the actual provider for current/older/missing targets.
  Initial compiler failures (accessory label and test call labels) were repaired
  before the final gates. An early queue observation was not counted; acceptance
  waited for the visible labelled queued result before testing restart.
- Root reviewed the complete patch and verified **13 current worker-reviewed
  source/test hashes**; a subsequent DTO comment-only change was reviewed by root.
  Workers did not run integration/runtime gates; observed provider/model and
  usage remain unknown, without quorum. Private merged evidence stays ignored.
- Final project XERJ refresh/check: exit 0, **221 files, 191/191 code**. Locked
  TelegramSwift and prepared engine fingerprints are fresh; the actual final
  query retrieved the reply controller/provider and was confirmed against source.
  A preceding refresh failed because sources changed during indexing; it was
  superseded by the successful final refresh.
- `git diff --check`: exit 0. Publication audit checked **226 publishable files**
  and the private PR body against five selected local credential fields, with
  zero matches. Local configuration, caches, clones and build artifacts stay
  ignored.

The preceding list-presence head `41542d7c1b9c62cf441b8f724ca65a9e3726fdb9`
failed [PR CI 38083296209](https://github.com/Mesteriis/makosh-native/actions/runs/38083296209)
and [push CI 38083293058](https://github.com/Mesteriis/makosh-native/actions/runs/38083293058):
Swift 6.3 could not type-check the nested synthetic presence expression. Explicit
typed locals now preserve its behavior and reduce type-checking complexity.
Hosted CI for the new published head is tracked separately.

Actual migrated-group/channel permission construction and live source changes
remain unaccepted. Rich ordinary input/selection, reply quotes/forward state,
server drafts, complete in-process edit-mode restoration, attachment captions,
gallery gaps, other Telegram workflows, archive/key backup, later channels and
standalone packaging remain open in `migration-plan.md`. The full sequential
migration goal remains active.

## Rich ordinary composer in the shared workspace — 2026-10-10

Ordinary input now reuses the existing owned AppKit rich editor. Exact text,
typed entities, scalar-safe UTF16 selection and the optional reply target form
one revision in encrypted Postbox. Schema 3 reads legacy 1/2 and upgrades on the
next save; the envelope marker remains stable. Unknown/malformed bytes remain
untouched. Decoding checks 64 KiB text and 1,024 entities before formatted range
validation; writes bound the entire envelope to 512 KiB, including URL metadata.
Format-only and selection-only changes protect newer input from a captured ACK.

Ordinary messages and replies enqueue native text entities. Fresh Postbox checks
reject missing/hashless text mentions; inline custom emoji requires a resolved
media registry and remains unavailable for send. The ordinary transaction/enqueue
chain is constructed outside MainActor, with only guarded UI acknowledgements
delivered to the main queue. Rich attachment captions are still open: attachment
selection explicitly refuses a rich ordinary draft instead of losing entities.
Default Return submits and Shift+Return inserts a line; configurable send-key
preferences and actual marked-input/IME acceptance remain open.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; PostgreSQL/S3 available.
- Final `scripts/test.sh`: exit 0, **381 XCTest (318 Telegram + 63 core), zero
  failures; 24 Python regressions**. Added coverage includes real encrypted
  Postbox rich-input reopen, valid schema-2 text/reply upgrade, exact Unicode/
  selection/range bounds, complete payload refusal retaining existing bytes,
  entity-count boundaries, native attribute roundtrip, missing/hashless mentions
  through the production preflight, stale editor context and format/selection
  ACK races. Thirty-two upstream `t19` teardown diagnostics remain visible after
  the passing Telegram suite; the previous unreachable-catch warning remains.
- `scripts/build-app.sh`, strict deep signature verification and unsigned
  built/QA payload comparison: exit 0. Native AX/screenshots verified **21
  focused conditions** in the common workspace: exact Unicode, bold/italic,
  undo/redo, honest mail placeholder, channel/chat isolation and return,
  selection restoration on channel return/restart, reply preserving rich input,
  explicit rich-caption guard, temporary edit/cancel, rich reply restart,
  Shift+Return newline, Return to labelled simulated queue, clear after restart
  and synthetic cleanup. Restored selection was verified by native replacement
  followed by undo. The same owned Postbox and explicit isolated PostgreSQL
  schema were reused after confirmed process exit. No personal account, Keychain,
  Telegram network or real send was used. Actual Account enqueue/server delivery
  remains unaccepted.
- Native QA initially found partial-style/invalid-formatting undo/redo. Immutable
  snapshots, suppression of intermediate storage/selection callbacks and setting
  lastValue before model publication repaired it; the failed scenario was not
  counted as a pass. Readonly review also identified possible actor inheritance
  in queue closures; the nonisolated production helper and real fixture test
  address it. Final source review found no remaining scoped defects.
- Root reviewed the complete code/test/doc diff and verified **16 current
  worker-reviewed hashes**. Root separately reviewed the model regressions and
  added the valid schema-2 Postbox upgrade regression after worker storage review.
  Worker reviews did not run integration/runtime gates. Observed provider/model
  and usage remain unknown, without quorum; storage review is author self-review.
- Final project XERJ refresh/check: exit 0, **225 files, 195/195 code**. Locked
  TelegramSwift and prepared engine fingerprints are fresh. Actual queries
  retrieved the editor and outgoing helper, confirmed against current source.
- `git diff --check`: exit 0. Publication audit checked **230 publishable files**
  and the private PR body against five selected local credential fields, with
  zero matches. Local configuration, databases, caches and QA artifacts stay
  ignored.

The preceding durable-reply head `94ba5d4fb607c66d61dcaf51bc4fccabe8e59f99`
passed [PR CI 38084551427](https://github.com/Mesteriis/makosh-native/actions/runs/38084551427)
and [push CI 38084549366](https://github.com/Mesteriis/makosh-native/actions/runs/38084549366).
These results do not establish hosted CI for this rich composer change.

Reply quote/forward/cloud state, complete in-process edit-mode restoration,
rich attachment captions/inline media, other Telegram workflows and gallery
gaps, live-account acceptance, archive/key backup, later channels and standalone
packaging remain open in `migration-plan.md`. The full sequential goal remains
active.


## Formatted file/photo captions in the common workspace — 2026-10-10

Attachment preparation now copies the complete typed composer input and UTF16
selection into the same owned AppKit editor. The controller freezes formatted
caption entities on send and rejects callbacks from older preparations or after
ready phase. Native upload attributes preserve nested Unicode entities. Current
Postbox validation rejects missing/hashless mentions before fresh reply preflight;
invalid replies never become ordinary media messages. Empty/whitespace captions
remain valid. Exact full draft revision acknowledgements protect newer formatting,
selection and reply targets. Inline custom emoji and premium limits remain open.

The reference source was verified at SenderController.swift:606–617 and
PreviewSenderController.swift:1524–1543,2169–2180. The reference transfers input
into its preview, clears ordinary input and restores the original on cancellation.
This slice preserves an independently editable caption while leaving the ordinary
draft visible. An edited caption therefore retains the ordinary draft after queue
acceptance. Full temporaryInputState transfer/restore, pending-caption restart
recovery and media preview remain explicit differences, not completed parity.

Actual checks:

- `scripts/dev-db.sh up`: exit 0; PostgreSQL and S3 healthy.
- Final `scripts/test.sh`: exit 0, **389 XCTest (326 Telegram + 63 core), zero
  failures; 24 Python regressions**. Coverage includes real encrypted Postbox
  caption mention admission, nested native entities and stale reply refusal,
  immutable caption/token behavior, unsupported/empty captions, and exact-revision
  formatting/selection ACK races. Thirty-four upstream SQL `t19` teardown
  diagnostics follow the passing Telegram suite. The first integration attempt
  failed at two missing `try` calls in the new mapping test; it was repaired and
  is not counted as a pass.
- `scripts/build-app.sh`, strict deep codesign verification and unsigned built/QA
  payload comparison: exit 0. Native AX/screenshots established **21 focused
  conditions across two passes**: common service selector; Unicode/rich file
  caption transfer; frozen recipient; caption italic/undo/redo; separate ordinary
  draft; honest mail and return; labelled simulated file queue preserving a
  differently edited ordinary draft; ordinary draft restart; Unicode paste over
  bold selection and after clearing; ordinary formatted simulated queue clear;
  formatted photo preparation; cancellation preserving the draft; exact photo
  queue ACK clear; cleared restart and synthetic cleanup. The first twelve
  conditions used the caption integration build; the remaining nine used the
  final emoji-corrected build. Same owned Postbox and explicit isolated schema;
  no personal account, Keychain, Telegram network or real send.
- Native QA found a real paste failure: AppKit's color-emoji font has no
  bold/italic/monospace traits. The bridge now retains the original marker only
  for native Apple emoji fonts containing actual emoji clusters. Removing styles
  from ordinary letters or replacing emoji with an ordinary font still rejects.
  Actual NSTextView/storage fixAttributes and replacement regressions pass;
  the previously failing native paste scenarios pass in the final build.
- Root reviewed the complete patch and verified **14 current worker-reviewed
  source/test hashes**. Final readonly review reported no scoped findings.
  Workers did not run SwiftPM/runtime gates; observed provider/model/usage remain
  unknown, without quorum. Native live enqueue and additional emoji sequences
  remain unaccepted. Private merged evidence stays ignored.
- Final project XERJ refresh/check: exit 0, **227 files, 197/197 code**. Locked
  reference/engine fingerprints are fresh. Actual final queries retrieved the
  caption helper and emoji bridge, confirmed against source. The readonly worker
  explicitly used current source for the two attributed-text files while their
  index was stale; root subsequently refreshed and checked that scope.

- `git diff --check`: exit 0. Publication audit checked **232 publishable files**
  and the private PR body against five selected credential fields, with zero
  matches. Machine configuration, caches and QA artifacts remain ignored.

The preceding rich-composer head `f083b891ec17e8a955cb4996abe88e3e568caf84`
passed [PR CI 38085984601](https://github.com/Mesteriis/makosh-native/actions/runs/38085984601)
and [push CI 38085981236](https://github.com/Mesteriis/makosh-native/actions/runs/38085981236).
These are results for that exact preceding head, not this caption patch.

Full caption transfer/recovery, other Telegram flows and live-account acceptance,
archive/key backup, later channels and standalone packaging remain open in
migration-plan.md. The full sequential goal remains active.


## Telegram modal attachment preview and input transfer — 2026-10-10

The reference's `PreviewSenderController` temporary input/cancel flow now runs
inside the shared workspace as a native sheet. A document card or bounded
normalized-photo thumbnail accompanies the frozen recipient/reply and the owned
rich caption editor. Ordinary input/reply is suspended during preparation;
Cancel/Escape restores the current origin draft. The durable original is retained
as a crash-recovery backup. An edited-caption queue ACK clears only that original
revision; later revisions and picker mismatches survive. A stable preparation ID
is separate from send/editor tokens, protecting late dismissal and callback order.
Precommit rejection/failure releases the transfer; committed uncertainty retains
it until late ACK or explicit observation close without resend.

Observed checks for this slice:

- `scripts/dev-db.sh up`: exit 0; local PostgreSQL and S3 available.
- `scripts/test.sh`: exit 0, **398 XCTest (335 Telegram + 63 core)** with zero
  failures, plus **24 Python regressions**. Added production-flow draft transfer,
  cancellation, edited-caption/newer-revision ACK, picker mismatch and stable-ID
  lifecycle tests; bounded photo preview verifies owned paths, cancellation,
  normalized bytes and refusal of foreign/removed stages. The passing suite still
  prints **34 upstream SQL t19 teardown diagnostics**.
- `scripts/build-app.sh`: initial and final builds exit 0. Strict deep signatures
  and unsigned executable comparison confirm the QA app uses the final payload.
  The only post-test source change removes an inherited parent accessibility ID;
  it was rebuilt and checked natively without repeating unrelated tests.
- Native AX/screenshots establish **13 conditions across two builds**. Initial
  file sheet/rich transfer and Escape passed; the final build additionally checked
  restored rich draft after restart, individual button/file IDs, edited-file
  cancellation, photo thumbnail, original recovery after exact owned-process
  SIGTERM, edited-caption simulated queue clear, reply/photo preview, restored
  reply/input after cancel, shared channel selector, synthetic cleanup and clear
  restart. Same owned Postbox and explicitly isolated PostgreSQL schema; no
  personal account, Keychain, Telegram network or actual send.
- Native QA found an inherited SwiftUI accessibility ID overriding child controls;
  removing that parent ID restored individual IDs. Cmd-Q while the sheet was open
  did not exit; a relaunch helper correctly refused (exit 1). Exact owned synthetic
  process termination and subsequent relaunch succeeded (exit 0), preserving the
  ordinary original. This does not prove abrupt power-loss survival or edited
  pending-caption recovery.
- Root reviewed the full patch and verified **10 current worker-reviewed hashes**.
  Final readonly reviews found no scoped defects; the post-QA one-line ID fix was
  reviewed again. Workers did not run SwiftPM/runtime gates; source-only reviews
  did not reuse stale indexes. Observed provider/model/usage remain unknown,
  without quorum. Private merged evidence is ignored.

- Final project XERJ refresh/check: exit 0, **228 files, 198/198 code**.
  Reference/engine fingerprints are fresh. Actual final queries retrieved the
  photo preview and composer finish helpers, confirmed against current source.
- `git diff --check`: exit 0. Publication audit checked **233 publishable files**
  and the private PR body against five selected credential fields, zero matches.
  Machine configuration, databases, caches and native QA artifacts stay ignored.

The preceding caption head `f07d956278a51527045971eee1335fcd958ab50a` passed
[PR CI 38086826931](https://github.com/Mesteriis/makosh-native/actions/runs/38086826931)
and [push CI 38086823938](https://github.com/Mesteriis/makosh-native/actions/runs/38086823938).
These are results for that exact preceding head, not this modal preview patch.

Pending-caption/file restart reconciliation, albums/premium/inline media, other
Telegram flows and live-account acceptance, archive/key backup, later channels
and standalone packaging remain open. The full sequential goal remains active.
