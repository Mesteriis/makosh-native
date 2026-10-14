# Telegram block14: final settings and portability

The user requests the entire final block after merged block13. Continue inline in
this thread through local/native verification, independent review and the already
authorized GitHub integration. The common native workspace and TelegramSwift
579cebbf0c01fd41b712eff3647fa7f69db9665d remain authoritative.

## Invariants

- Native SwiftUI/AppKit, macOS26+, Apple Silicon; common service sidebar.
- No local Makosh passcode or autolock.
- No copied outer GPLv2-only UI/assets/credentials. Own MIT, combined GPLv3.
- Pinned engine, no build/run/test dependency on .references, no private logs.
- Permanent PostgreSQL archive survives deletion/TTL. Bytes live in S3.
- Personal chats default S3 ON, groups/channels OFF. Explicit OFF forbids every
  new S3 copy, including preparation and restore; old objects remain.
- Exact account/context/target admission, explicit mutation confirmation, typed
  ACK and reread; uncertain outcomes block repeat writes until reconciliation.
- QA uses synthetic data and an isolated --database-config schema. The user will
  supply a test account, peer and exact actions separately; no private access,
  transmission or physical capture is permitted before that answer.

## 1. Connected websites

Devices gains Connected Websites with bot/domain/browser/platform/created/active
and location details. Load, terminate one or all with named confirmation and a
fresh identical target/set admission. Duplicate/malformed identities fail closed.
Missing completion/ACK and timeout are uncertain; no implicit bot blocking.
Closing/rebinding cancels owned work and cannot authorize stale confirmations.

## 2. QR sign-in

The existing native login gains a QR alternative beside phone sign-in. Use the
pinned engine auth-transfer-token API, login token events, expiry renewal and
native account replacement/password state. Render with CoreImage. Tokens stay
memory-only, never clipboard/log/archive. Phone alternative/cancel revokes owned
reads/renewals. Do not auto-start QR or choose a personal account. Synthetic QR
is clearly labelled and cannot authorize an account.

## 3. Remaining general and appearance settings

Follow reference General/Appearance sections inside the existing settings form.
Add persisted, validated local controls for emoji replacement/animations and
message text size where actual consumers exist. Appearance includes wallpaper
solid/gradient/local image, preview/reset and scheduled night mode with correct
midnight crossings; wallpaper is local, metadata-stripped and bounded. Selection
is an explicit draft until save. Cloud theme/wallpaper catalogues use pinned
engine capabilities when supported; unavailable content reports a visible error.
No reference assets are copied. Telegram appearance must not tint other services.

## 4. Cache and downloads

Extend current verified cloud-cache catalogue with per-chat selection and visible
transfer management. Preserve resource allowlist, fresh rescan/consent, force:false,
occupied/preparation/secret protection and permanent archive/S3 invariants.
Add local retention/size preferences only with a real safe eviction consumer;
automatic eviction uses the same admission and never broad filesystem deletion.
Manual transfers remain separately owned; disabling automatic downloads cancels
only automatic ownership. Show loading, failed, empty and retry distinctly.

## 5. Reference polish

Close recorded block13 functional presentation gaps: actual avatar thumbnails in
profile/settings, a native secret-chat card/key/TTL entry, admin event filters,
and call window controls/background/status/recall/audio-device selection where
native APIs support them. Use own symbols/shapes and owned sounds, never upstream
GPLv2 assets. Preserve privacy/capture/proxy admission. Group calls, screen share,
notarization and unrelated service integrations are not in this final block.
Record exact remaining aesthetic differences honestly; no unsupported parity claim.

## 6. Portable encrypted archive backup and restore

Provide explicit native export/inspect/restore workflow for the permanent message
archive, policy metadata, encrypted S3 objects and archive key. Export a consistent
bounded PostgreSQL snapshot, complete manifest and verified ciphertext objects;
never Telegram authorization/session caches, API/S3/PG credentials or system data.
Protect the archive key with a separately saved cryptographically random256-bit
recovery key; authenticated encryption and per-object digest/count bind contents.
Use private staging/no symlinks/no overwrite/atomic publish and stream large files.
Wrong/missing recovery key, corruption, truncation, duplicate/path escape,
incomplete object inventory or unsupported versions fail closed before publishing.
Restore into an explicitly chosen NEW empty archive schema, never rewrite/delete
existing history/keys/objects. Reuse matching destination objects. Respect S3 OFF:
if an absent object belongs to OFF, stop before any copy and retain the backup;
user may instead reuse the original S3 bucket. Do not silently enable policies.
Inspect shows counts/size/requirements without displaying private message bodies.
Keys install only after verified data and target admission; existing different key
is a conflict. Document exact portability boundaries and recovery procedure.

## 7. Acceptance and integration

Every meaningful behavior has observed RED/GREEN regressions. Run dev DB, full
tests, signed build, actual changed native flows in isolated synthetic QA and
fresh XERJ fingerprints. One fresh same-model whole-branch review, one fix pass,
exact-head hosted checks and merge. Real-account/hardware results are separate
and require the pending explicit test scope; absence is reported, never called PASS.
