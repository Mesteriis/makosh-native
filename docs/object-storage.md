# Independent file storage

File payloads belong in S3, not PostgreSQL. The first connected producer is a
completed explicit Telegram full-file download. Other channels should use this
same boundary as they are migrated; outgoing staging and other channels are not
yet connected. Preview images and unrequested media are not automatically fetched.

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

## Capture, storage and recovery

```text
complete full download → frozen read-only FD → encrypted durable queue
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
successfully captured bytes. Existing untouched cache, outgoing uploads and
historical media require further work. Permanent recovery also needs coordinated
PostgreSQL, S3 and Keychain backups; portable backup/restore is unfinished.

## Validation

Local tests use real PostgreSQL and S3 with generated schemas, deterministic
test-only encryption keys and synthetic file content. They cover cache unlink,
reopen/export, no file payloads in PostgreSQL, append-only guards, exact account
scope, S3 conditional conflicts, integrity/tamper/framing, pre-queue failure and
retry, uncertain receipt-directory sync, and S3 success followed by PostgreSQL
rollback/restart reconciliation.
Preview regressions also cover a source unlink/deletion event followed by a new
repository instance, forged metadata rejection, private modes, hostile file
labels, independent leases, and failure/cancellation cleanup.
`scripts/test.sh` selects local S3 automatically when its private config exists;
otherwise the S3 integration cases explicitly skip. Hosted macOS CI downloads a
checksum-verified pinned SeaweedFS binary and starts an isolated native service
because Docker is unavailable there. Hosted success must be checked for each
published head; workflow configuration alone does not prove a pass.
