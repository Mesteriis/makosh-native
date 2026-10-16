# Native Teams adapter provenance

MakoshTeams ports the public Microsoft Graph and delegated OAuth workflows from
`rvben/teams-cli` at `9c8a72c32369f9d9bd15b793099522a80070a063` (MIT).
The independent `Dependencies/Teams.lock.json` records inspected file hashes,
retained reference source and the exact license. The retained Rust files are
provenance material, excluded from compilation and product runtime. No Rust
crate, terminal UI, upstream installer, private account store or upstream public
client registration is used by this adapter.

`TeamsGraphClient.swift` adapts endpoints and paging; `TeamsOAuth.swift` adapts
the public PKCE/device/refresh contracts. Makosh owns URL/body bounds, continuation
ownership, complete pages, OIDC verification, durable archives and mutations,
file sharing, notifications and native UI. An organization-owned Entra public
client registration is required for connection. Personal accounts and calls are
outside this transfer.

Run `python3 scripts/verify-teams-dependencies.py` without research clones to
verify the retained inputs and runtime independence. Original upstream source
remains MIT; Makosh's own source is MIT and the combined application GPLv3 as
described in THIRD_PARTY_NOTICES.md.
