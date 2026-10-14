# Telegram block13: remaining communication capabilities

User-approved scope (2026-10-13): implement all five parts below in the existing
Makosh workspace, followed by the already authorized integration workflow.
The withdrawn passcode proposal is excluded. Block14 remains separate.

## Invariants

- Native SwiftUI/AppKit, macOS26+, Apple Silicon; service sidebar stays common.
- TelegramSwift579cebbf0c01fd41b712eff3647fa7f69db9665d defines layouts/workflows.
  Its outer GPLv2-only UI/assets/credentials are approach-only, never copied.
- Independently pinned GPLv3 TelegramCore supplies protocol/cryptography. A new
  native VoIP dependency needs exact provenance, license and reproducible build.
  No build/run/test dependency on `.references/`; no private engine logging.
- Identity is service/account/peer. Reads and writes retain account/context/token;
  stale results cannot navigate, authorize, capture or overwrite another context.
- Explicit consent precedes writes. Fresh native identities/rights/bases gate
  mutations. No automatic write retry; missing/ambiguous ACKs are uncertain.
- Permanent PostgreSQL message/version retention survives remote deletion and
  secret TTL. File bytes use S3, never PostgreSQL; per-chat OFF forbids every new
  S3 copy. Private chats defaultON and groups defaultOFF.
- No local passcode or automatic app locking. No personal account access, real
  Telegram transmission/call or hardware capture during synthetic QA. Real account
  acceptance belongs to separately authorized block14 checks.

## 1. Remote discovery

The existing global search keeps local chat matches first, then distinct remote
results from Telegram, with deduplication by native peer identity. Root/inbox
ordinary text and usernames admit discovery; archive, #/$ queries, message-only
filters and empty/oversized/control-bearing queries do not. Debounce300ms,
deadline30s, cancellable work and visible failure/retry match existing search.
Activation captures the result context and revalidates the peer before opening
its ordinary conversation. Opening never joins, imports contacts or sends.
Remote identities become native Postbox observations, not contact imports.

## 2. Profile photos

Add explicit change/remove own and permitted group/channel avatar workflows,
plus the own public fallback photo. Follow the current photo preparation bounds,
metadata removal, native picker and reference confirmation. Recheck current own
identity or group rights and original photo basis before RPC. Preserve photo
history and existing viewing/export behavior. Account replacement cancels an
unsubmitted picker/draft; uncertain writes require refresh.

## 3. Group administration

Add member invitation/addition, invite links, join-request list/approve/decline
and administrator event history. Use native pagination and typed identities;
permissions are checked again immediately before writes. Lists distinguish empty
from failed/incomplete results, and closing cancels their owned reads. Confirm
exact targets/actions. Creating/revoking links never implicitly shares them.
No ownership transfer, group deletion or unrelated statistics scope is added.

## 4. Secret chats

Expose create/handshake state and verification in existing profiles/conversations.
Use native secret-chat encryption, negotiation and outbox rather than a new
protocol. Extend allowed formatted text/reply/media and per-chat Telegram TTL
only where the pinned engine supports them. Refuse unsafe/unsupported states
explicitly. Remote disappearance/TTL must never erase retained archive versions
or S3 objects. Consent belongs to one account/peer/secret session; stale session,
revoked rights, unconfirmed key state and unsupported resources fail closed.

## 5. Native calls

Implement incoming/outgoing one-to-one audio/video, accept/decline/end, mute,
video enable/disable and call state in the common workspace. Telegram's native
session manager owns authenticated key agreement/signaling; a reviewed native
VoIP/media engine owns encrypted transport/codecs. The displayed verification
fingerprint and privacy/P2P restrictions use native state. No automatic answer,
recording, debug logs, unreviewed prebuilt framework or invented protocol.
Capture begins only after explicit user action/OS permission; ending/rebinding
releases media and rejects late callbacks. UI cancellation is not remote rollback.

## Acceptance

For each part: regression RED/GREEN, native boundary coverage, reference source
confirmation and synthetic native UI. Required dev DB, full tests and signed app
build pass at final integration. One independent whole-branch review and exact-head
hosted checks precede merge. Real server/account/remote-call acceptance remains
explicitly distinguished from local synthetic and native media tests.
