# WhatsApp block 1

User approval: 2026-10-15, “Да делаем”, following the proposed core/connection block.

Deliver the selected WhatsApp Zen Rust foundation inside Makosh's common native
workspace: explicit companion QR connection, independent account identities,
protected durable sessions, chat list and retained paged history. Sending, media
transfer, calls, notification rules and dossier UI completion belong to block 2.
Real linking and account QA require the user's later explicit instruction; current
real Telegram/mail QA pause continues. Synthetic QA uses only qa_whatsapp_ schemas.

Use Zen 790066aa411d395562a572101a74057147af67db and its whatsapp-rust 0.7.0
protocol stack. Adapt Bot lifecycle and event mapping; do not import its global
singleton, private logging, automatic store migration/deletion, app locking or
plaintext databases. Separate AGPLv3 worker (explicit user license decision), versioned length-counted local IPC, explicit
handles, bounded requests/replies and owned response buffers. Open is offline;
connect is explicit. Stop closes admission and asynchronously disconnects/flushes
before releasing the cache. Never reset on wrong/missing key or remote logout.

SQLCipher protocol cache and durable journal are keyed from Makosh Keychain,
separate from encrypted append-only PostgreSQL message archive. No attachment
payload bytes in PostgreSQL. A journal receipt is acknowledged only after archive
and offline projection writes commit. Retry uses stable observation IDs. Preserve
received versions and deleted content indefinitely, including disappearing chats;
never rewrite source JID identity when a phone/LID alias appears. Messages never
received cannot be recovered. Per-account ownership prevents competing clients.

MainActor owns presentation only. Rust operations and SQL/Keychain/file work run
on service executors; account/context generations discard late UI results. QR is
transient, expires, and is cleared at connection/cancellation/account change.
Lists follow Zen's verified chat rows, filters and message bubbles within Makosh's
service sidebar, with explicit offline and empty states. No placeholder connected
state or unsupported send buttons. Multi-account selection is isolated.

Acceptance: reproducible pinned independent dependency build with reviewed
licenses and no reference-directory access; real native ABI tests, SQLCipher
wrong-key/reopen/ownership tests, event mapping/edit/delete/archive replay and
stable pagination tests; Swift worker/model account-generation tests; real
PostgreSQL integration; signed synthetic native UI inspection; dev-db up,
test.sh, build-app.sh, runtime closure/signature and diff checks. Real WhatsApp
QR/link/network acceptance remains separately pending, never inferred from fixtures.

License decision (2026-10-15): user approved a separate Rust worker under AGPLv3 after Signal source headers contradicted Cargo MIT metadata. Swift does not link its code; keep main application licensing and provide separate worker notices/corresponding source.
