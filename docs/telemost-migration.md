# Telemost first stage

The seven-task native inline plan and specification are approved. Tasks1–7 are
implemented; one final review/fix pass and post-fix canonical gates are complete.
Isolated native visual acceptance is partial, as recorded below. Real account/provider
checks are paused and no Telemost test account is selected.

MakoshTelemost uses independently authored official REST and an approach-only MIT
reference pin. No GTK/GStreamer/private messenger API is linked. The URL/transport
boundary rejects hostile/ambiguous paths and credential redirects, caps JSON4MiB,
retains unknown metadata and retries only bounded GET429/503. Mutations never retry.

Encrypted PostgreSQL current records and append-only versions retain catalogue,
conference observations and immutable attempt payload/state transitions. A
persistent encrypted local area is separate from every API account. Hide/remote
missing/disconnect do not purge history. Stable as-of version paging and JSONL
export use a fixed upper sequence. Export is explicit plaintext to the chosen
file; no credentials are included. All archive payloads in this stage are meeting
metadata, not files or recordings.

One held PG session advisory lease owns each account across processes during
auth/dispatch/refresh. Dispatch admission is persisted; orphaned dispatching becomes
unknown only after checking for a live lease. Unknown forbids replay/new admission
until explicit resolution. Late settlements check immutable attempt/state. Failed
COMMIT blocks all writes. Missing key/schema failure preserves data.

Historical Task2 checkpoint: scripts/dev-db.sh up exit0; baseline canonical focused script
exit0;21 Telemost tests exit0, including11 real-PG/catalogue/operation checks and a
separate-process lease probe; Python provenance3 exit0. Behavioral RED and GREEN,
source hashes and raw exits live in ignored .local/telemost-migration/ and the
plan ledger. This checkpoint predates the final gates recorded below.

OAuth uses S256, exact callback/state, explicit manual-code mode and checked
Yandex user-info id/client_id. Grants are single-use actor-owned proofs awaiting
confirmation, not installed sessions. Reduced scopes restrict operations; expiry
requires explicit login, refresh is never sent. Keychain has its own actor and
checked atomic update/add, with no deletion on write failure. Eight synthetic
auth/vault tests pass;29 Telemost tests pass at Task3. Native auth bridge and
ordinary OS Keychain acceptance remain separate. The native bridge is now implemented.

Runtime now installs only an actor-verified confirmed grant under its auth lease,
opens cached tokens only after explicit Connect, and gates every command by
principal/capability/expiry/generation. Disconnect cancels publication and pending
login, preserving credentials/history; close drains admitted receipts before SQL
teardown. POST/PATCH return durable operation IDs; accepted/rejected/unknown are
separate. Manual resolution uses a read observation and remains user-resolved,
not proof the original request ran. Cohost pages preserve raw observed metadata
in permanent versions, survive partial failure, resume from committed offsets and
restart on overlap. Task4 checkpoint evidence:41 Telemost tests pass, including12
worker/reconciliation checks. Dossier/UI were completed in Tasks5–6; native visual
acceptance remains partial.

Dossier references freeze meeting ID/account/source observation and one note UUID.
Retries after a lost acknowledgement or contact merge return the actual owner
without duplicating notes. No cohost-to-person import happens automatically.
Core contact notes retain their current unencrypted storage; service catalogue,
projection jobs and versions remain independently encrypted.

The native workspace supports two or more configured API accounts and a separate
local-link area. Accounts never rebind principal/client; source changes need a
new account. Browser sign-in uses the fixed app-owned callback registered in the
bundle; an explicit manual-code alternative uses verification_code. Confirm the
verified login and granted scopes before installation. Only granted actions are
enabled. Local disconnect keeps keys/history. API creation sends waiting room
only; title/notes/star/hide are local edits. Unknown operations preserve drafts
and prohibit replay until explicit user resolution; a GET observation is not
proof the original request ran. Export writes plaintext JSONL to the chosen file.

Isolated QA: run scripts/dev-db.sh up, scripts/build-app.sh, then
python3 scripts/run-telemost-qa.py --launch. The runner creates a fresh owner-only
.local/telemost-qa run, marked bundle and both qa_telemost_ schemas with a pinned
loopback address. It copies no credentials into resources. Public fake encryption
keys, memory HTTP/vault and captured opener are restricted to this debug QA
factory; normal launch fails closed for a marked bundle. Other service hosts and
OS notification registration are excluded. Restart with the same artifact.json
launch arguments to verify retained state; do not delete the schema to hide failures.

No real Telemost account/eligibility/provider/Keychain/browser or minimum-OS/clean-
machine/distribution acceptance has run. Native media, chat/calendar/files/recording
administration are separate scope, not remaining tasks of this approved first stage.

Final post-review checkpoint: canonical full tests/build/dev-db and absent-reference
build pass exit0. Rust35, Swift2776 including74 Telemost/one existing Telegram
precondition skip, Python150 across33 runs. Ordinary and final QA003 strict
signatures/provenance pass; executable text hashes match. Each bundle contains
six ARM64 binaries, including four libraries, with system/bundle library references.
Latest native QA-only fixture/launch guards pass full tests. Initial
CUA AX succeeded; pipe closed on local selection while process remained alive.
Remaining native visual scenarios are unverified, with schemas/data retained;
no UI bypass, provider or OS credential action was used. Catalogue width literal
was corrected from source after AX reported199.5 and is included in the final
build; visual acceptance remains unverified. QA001 was stopped without deleting
its data; final QA003 is launched with fresh isolated schemas. Raw logs, exact
exits, artifact inventory and the one frozen review packet remain in ignored
.local/telemost-migration/. No Git publication or real account access occurred.

Final review fix pass: HTTP401 persists an encrypted reauthorization gate bound
to the confirmed-grant epoch. Connect/restart cannot load the known-rejected
credential; only a new verified, confirmed OAuth grant clears the gate. A late
rejection from an older epoch cannot invalidate that new grant. Credentials and
history remain retained. Every REST admission checks the epoch under the account
lease. A failed new OAuth user-info exchange does not revoke the prior verified
credential. Unknown PATCH requires exact-scope GET and exposes requested versus
observed waiting room in the journal; unconditional dismissal is create-only.
Repository pages include hidden records for explicit UI recovery. Search-driven
selection removal revokes dossier navigation; rejected/unknown PATCH keeps the
editor, and partial/missing refresh publishes the retained observation plus error.
