# Independent file storage

Archived file payloads belong in S3, not PostgreSQL. Connected producers are
completed explicit Telegram full-file downloads and durable outgoing preparation.
When a chat disables S3, outgoing preparation remains encrypted locally instead.
Other channels should use this boundary as they are migrated. Preview images
and unrequested media are not automatically fetched.

## Development services

`scripts/dev-db.sh up` starts PostgreSQL and S3-compatible SeaweedFS 4.48 in
Docker. [The lock](../Dependencies/ObjectStorage.lock.json) records upstream
revision, Apache-2.0 license, multi-platform image digest and hosted-macOS test
archive checksums. Compose publishes only S3 at `127.0.0.1:55440`; its master,
filer, volumes and administrative ports remain unpublished. Telemetry and WebDAV
are disabled. The launcher copies the private host identity file into container
tmpfs and drops to UID 1000. S3 data uses its own named volume. Stopping/recreating
containers preserves data and credentials; removing volumes destroys them.

`configure-dev-s3.py` generates separate administrative and bucket-scoped app
identities in ignored owner-only mode-0600 files. It rejects symlink settings,
unsafe permissions and malformed values, and does not print credentials.
Initialization enables versioning and installs a bucket policy denying
`DeleteObject`, `DeleteObjectVersion`, `DeleteBucket`, lifecycle configuration and
suspending versioning. Anonymous/invalid-signature requests are rejected. The
app has no delete API and uses conditional `If-None-Match: *` PUT with random
object IDs. Versioning retains out-of-band replacements; the current exporter
verifies the expected hash and fails if the latest object was replaced. Selecting
an older S3 version for repair is not yet implemented. An administrator can
change policies or remove Docker data; this is not an adversarial-admin WORM
or physical disk-loss guarantee.

Run `python3 scripts/dev-s3.py probe` for a synthetic PUT/GET integrity check and
denied deletion/anonymous/lifecycle/version suspension checks. Its tiny persistent
probe object intentionally remains under `synthetic-probes/`, including after
container restart. Tests use distinct random opaque keys and never real messages.

## App configuration

Default `scripts/run.sh` supplies `--storage-config .local/s3-app.json`. For a
direct launch, place your own owner-only regular configuration file at
`~/Library/Application Support/Makosh/s3.json`, or pass `--storage-config`.
The JSON fields are `endpoint`, `region`, `bucket`, `accessKeyID`,
`secretAccessKey`. HTTPS is required except for loopback development HTTP.
Endpoint credentials, path prefixes, queries and fragments are rejected; HTTP
redirects are never followed. Configuration errors do not print decoder payloads
or credentials. Missing S3 configuration does not prevent using the contact book.

## Per-chat S3 choice

The conversation header exposes **Сохранять файлы в S3**. Personal Telegram
cloud chats default to enabled; basic groups, supergroups and channels default
to disabled. An explicit choice applies to the whole service/account/chat,
survives restart and does not follow the currently selected message or leak
into another account. PostgreSQL stores an authenticated encrypted override
and a keyed scope token, without plaintext chat identifiers.

Completed full downloads check this choice before creating a durable archive
receipt and before uploading queued work. Disabling leaves existing S3 objects
and message text intact. A previously queued encrypted archive copy pauses
until re-enabled and explicitly retried through **Проверить очередь файлов**.
A PUT already started before disabling may finish. Older untagged receipts
require an explicit conversation resolver; unresolved receipts remain queued.
Telegram resolves old preparation receipts through the same chat policy: an
outgoing-shaped message ID grants no exemption. Once that chat is enabled,
retry preserves the authenticated legacy metadata and exact file bytes.

Disabling prohibits every new S3 copy, including outgoing files, normalized
photos, raw originals and video covers. Outgoing preparation instead keeps an
encrypted local envelope and authenticated `.local` receipt in the private
spool. Its explicit `local` state, domain-separated key binding/storage identity
and object key distinguish it from an S3 receipt. The encrypted Postbox pointer
contains metadata only. Local receipts never enter S3 resume, even after the
chat is enabled later. Recovery checks the exact receipt, encrypted size/hash
and authenticated envelope before creating a temporary plaintext stage.
No payload bytes are stored in PostgreSQL. Older tagged and untagged preparation
queue receipts require the same service-specific policy resolver as other old
copies. Existing S3 objects remain readable regardless of the current choice.
Local preparation is retained on cancellation/acceptance; automatic collection
and portable backup/restore are unfinished.

Schema8 Media/File switches select existing canonical resources through guarded
Postbox metadata updates. File presentation selects a photo’s authenticated raw
original; Media selects its JPEG. The same local/S3 records, covers and encrypted
spool bytes remain unchanged across switches and restart. Enabling S3 later does
not promote a local preparation, including after a mode change or resume.

## Capture, storage and recovery

```text
complete full download → frozen read-only FD → per-chat archive choice
  → encrypted durable queue
  → PostgreSQL pending metadata → conditional S3 PUT / HEAD reconciliation
  → PostgreSQL stored receipt → remove acknowledged local queue item
archive export → S3 GET → hash + authenticated decryption → native Save panel
archive preview → same authenticated S3 path → private plaintext lease → Quick Look
```

The identity is the original service/account/typed conversation/message and
attachment ID; changing visible chat/account does not retarget accepted work.
Regular files only, exact measured size, no source symlinks/FIFOs, maximum
plaintext size 4 GiB. Fixed 1 MiB AES-GCM frames authenticate object ID, version,
size, frame index/count and length, including an empty file. A domain-separated
key derives from the existing archive vault key, independently of Telegram's
session key. Streaming hash/read buffers are bounded; whole-file buffering is
not used. Source mutation is checked; already unlinked open inodes remain usable.

**Посмотреть** in the local archive opens the retained S3 copy through native
Quick Look, independently of Telegram authorization/cache. The stored receipt,
encrypted-body hash, authenticated envelope and plaintext hash must validate
before a preview is published. Each preview owns a separate temporary directory
with mode 0700 and a regular plaintext file with mode 0600. Its disk basename
uses only a generic name and a bounded ASCII extension; the display title uses
the existing sanitized attachment name. Cancellation/failure removes partial
preview files. Quick Look retains the lease until its view closes; ordinary
dismissal releases the temporary copy without deleting the encrypted S3 object.
Cleanup is best effort at release, not a guarantee after crash or forced process
termination. Quick Look format support/rendering and large-media performance
depend on macOS; unsupported previews can still use the existing Save action.

PostgreSQL `archive_file_events` contains append-only pending/stored encrypted
metadata and keyed lookup tokens, with no BYTEA/file-content column. S3 object
keys contain only random vault/object IDs, never filenames, account IDs, paths
or Telegram access hashes. File names and plaintext/content hashes are encrypted
in PostgreSQL and in queue receipts. S3 contains encrypted envelopes, with only
the encrypted-body SHA-256/size metadata needed for integrity reconciliation.

The private `FileArchiveQueue` under Application Support holds encrypted files
and encrypted receipts during unavailable/uncertain persistence. Receipt
publication is atomic and fsynced; corrupt receipts are reported without
blocking valid queued work. Unpublished partial files are never treated as
committed receipts. If directory synchronization is uncertain after publication,
the error is reported and recovery uses that same receipt/object, rather than
recapturing a second copy. **Проверить очередь файлов** retries pending work. A lost
S3 response does not trigger another blind PUT: HEAD must match the expected
encrypted hash/size. A PostgreSQL failure after S3 succeeds leaves the receipt
for idempotent recovery; the UI says saved only after both systems confirm.

Failures before durable queue creation retain up to eight frozen captures in
the running controller for explicit retry, including after cache unlink.
Those not-yet-encrypted captures do not survive process exit. Abrupt termination
before receipt publication can leave an orphan encrypted envelope; no automatic
destructive orphan cleanup is performed. These boundaries, disk exhaustion and
missing/unavailable keys prevent an absolute promise to retain unseen or not
successfully captured bytes. Existing untouched cache, delivered outgoing files and
historical media require further work. Permanent recovery also needs coordinated
PostgreSQL, S3 and Keychain backups; portable backup/restore is unfinished.

## Validation

Local tests use real PostgreSQL and S3 with generated schemas, deterministic
test-only encryption keys and synthetic file content. They cover cache unlink,
reopen/export, no file payloads in PostgreSQL, append-only guards, exact account
scope, S3 conditional conflicts, integrity/tamper/framing, pre-queue failure and
retry, uncertain receipt-directory sync, and S3 success followed by PostgreSQL
rollback/restart reconciliation.
Conversation-policy regressions cover defaults, encrypted overrides after
reopen, exact service/account/chat scope, stale UI context, disabled admission,
queue pause/re-enable, retained export and unchanged text retention.
Preview regressions also cover a source unlink/deletion event followed by a new
repository instance, forged metadata rejection, private modes, hostile file
labels, independent leases, and failure/cancellation cleanup.
`scripts/test.sh` selects local S3 automatically when its private config exists;
otherwise the S3 integration cases explicitly skip. Hosted macOS CI downloads a
checksum-verified pinned SeaweedFS binary and starts an isolated native service
because Docker is unavailable there. Hosted success must be checked for each
published head; workflow configuration alone does not prove a pass.
