# Makosh engineering

- Read `docs/development-status.md`, then verify Git and current source. Preserve unrelated changes.
- Native SwiftUI/AppKit, macOS 26+, Apple Silicon. No Electron/Tauri product shell.
- Contacts need the local PostgreSQL service, without communication accounts. Never read personal accounts, mail, system Contacts or messages without separate explicit authorization. Examples and UI QA use synthetic data and an isolated schema selected through `--database-config`.
- Before architecture/module work and debugging, actively search the selected references and Makosh with XERJ; confirm hits against source. Read `docs/xerj.md`. Check commit SHA and content fingerprints before reusing an index; refresh changed scopes. Report actual failures, never substitute `rg` as XERJ evidence. Keep machine indexes/configuration in ignored `.local/`.
- Do not copy third-party code without exact license and dependency review. First stage is independently written MIT; see `docs/architecture.md` and reference research.
- Identity is (service, accountID, externalID). Imports, merges and undo must be atomic. Preserve manual overrides, source observations, identities and notes. Undo must stop after later edits; revision reuse must never enable stale undo.
- Use no more than two same-model subagents. Assign disjoint files; root alone changes manifests, integration docs, Git and publication.
- Run `scripts/dev-db.sh up`, `scripts/test.sh`, `scripts/build-app.sh`, and inspect actual UI for changed flows. These scripts supply libpq configuration; integration tests require real PostgreSQL. Compilation is not runtime proof. Keep `docs/development-status.md` current with actual results and remaining blockers.
