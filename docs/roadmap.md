# Next integration stages

The active user goal is the complete sequential transfer. See [migration plan](migration-plan.md) for the full checklist, current slice and unresolved acceptance criteria. Implementation proceeds while account-dependent acceptance remains explicitly unverified.

1. Telegram uses the exact TelegramSwift iOS engine: GPL/dependency audit, native authorization/text UI, cursor-based dialogs/archive/history and regression tests. Continue search, media, message actions and dossier identity linking, then remaining source-confirmed full-client capabilities. Independently verify auth, incoming sync, server pagination/holes, sending, stop/reconnect and cache-error handling after explicit account-access authorization. Keep the selected full-client direction.
2. MMail engine extraction spike: IMAP/SMTP transport, lifecycle, source IDs, OAuth gaps, secret storage and scripted protocol tests. Apply Aether UX patterns without replacing MMail functionality.
3. WhatsApp Zen: versioned C/JSON boundary and owned-memory rules, Rust build/licensing, local session store, cancellation and source-scoped identity adapter. Verify real auth only after explicit user authorization.
4. teams-cli: selected public library Graph/OAuth modules, minimum delegated scopes, token lifecycle and Swift UI bridge. No CLI terminal embedded as product UI.
5. Telemost official API for an eligible business account: meeting list/create, provenance, browser handoff. Consumer API access is not assumed. Investigate Linux WebRTC reference separately; no portability promise.
6. PostgreSQL scale/migration: measure the initial PostgreSQL 18.6/libpq single-row JSONB store, then normalize tables if dataset/query needs justify it. Add export/backup and reversible migrations; preserve row-lock transaction, import/manual/merge invariants. Package libpq for distribution separately from the current Homebrew-linked development app.

Each stage requires license/dependency review, fresh XERJ source research, implementation tests and actual UI acceptance. Account access is a separate authorization boundary.
