# CRM reference audit — 2026-10-10

Research only. No upstream programs, importers or tests were executed. Only public source trees were sent to the local lexical XERJ node; no private contact database was opened.

## Pinned sources and licensing

- 900CRM: `f49ef2207998c9d97f1201cde56da4b11ce47c90`, shallow clone [local README](../.references/900CRM/README.md), [Apache-2.0 LICENSE](https://github.com/900Labs/900CRM/blob/f49ef2207998c9d97f1201cde56da4b11ce47c90/LICENSE), [workspace manifest](https://github.com/900Labs/900CRM/blob/f49ef2207998c9d97f1201cde56da4b11ce47c90/Cargo.toml).
- Orbit: `a7c8a12297a83a71dac47c32d2521e7de594b77d`, [local README](../.references/orbit/README.md), [client manifest](https://github.com/moritzWa/orbit/blob/a7c8a12297a83a71dac47c32d2521e7de594b77d/client/package.json) declares ISC; no root LICENSE/COPYING file was present, and server package/deno manifests declare no project license. Repository-wide reuse rights therefore remain unresolved. Neither pinned tree establishes Orbit as GPL-2.0.

[Apache Software Foundation compatibility guidance](https://www.apache.org/licenses/GPL-compatibility.html) describes Apache-2.0 as incompatible with GPL-2.0-only combination, while GPL-3.0 compatibility has a different treatment. This is a planning constraint, not a legal opinion: confirm exact GPL version, scope, dependency notices and distribution obligations before combining code. No GPL component is adopted by this research.

## 900CRM evidence

[crm-core manifest](https://github.com/900Labs/900CRM/blob/f49ef2207998c9d97f1201cde56da4b11ce47c90/crates/crm-core/Cargo.toml) explicitly describes a Tauri-independent core, using rusqlite (bundled SQLite), serde, csv and uuid. [storage](../.references/900CRM/crates/crm-core/src/storage/mod.rs) separates persistence modules.

[Service merge](https://github.com/900Labs/900CRM/blob/f49ef2207998c9d97f1201cde56da4b11ce47c90/crates/crm-core/src/services/contacts.rs#L266) wraps `contact_engine::merge_contacts` and audit in a SQLite transaction. [Engine merge](https://github.com/900Labs/900CRM/blob/f49ef2207998c9d97f1201cde56da4b11ce47c90/crates/crm-core/src/crm_engine/contacts.rs#L228) rejects self merge, fills missing target fields, combines notes, moves relationships and soft deletes the source. Its contact input has a single email/phone rather than a personal address book's multivalue identities. [Duplicate candidates](https://github.com/900Labs/900CRM/blob/f49ef2207998c9d97f1201cde56da4b11ce47c90/crates/crm-core/src/storage/contacts.rs#L810) use trimmed exact email/phone and choose the older record as default target.

[Import services](../.references/900CRM/crates/crm-core/src/services/mod.rs) implement CSV/JSON previews, mapping, preflight and options. [ImportRollbackPlan](https://github.com/900Labs/900CRM/blob/f49ef2207998c9d97f1201cde56da4b11ce47c90/crates/crm-core/src/services/import_rollback.rs#L25) includes token, row number, entity id, changed fields, before/post snapshots. `rollback_completed_import` is at line 656; rollback checks the current snapshot against post-import state and records conflicts (lines 856–859). This is meaningful conflict-aware import rollback, not proof of complete reversible manual merge. Reviewed audit fields identify actors/devices; no generic per-value external source identity mapping was confirmed in the inspected slice.

## Orbit evidence and pitfalls

[getDb](https://github.com/moritzWa/orbit/blob/a7c8a12297a83a71dac47c32d2521e7de594b77d/server/src/db.ts#L6) enables WAL and foreign keys; contact_phones/contact_emails preserve multiple values. `import_log` records source/count, and `merge_redirects` uniquely maps `(source, source_id)` to a contact. [Apple importer](https://github.com/moritzWa/orbit/blob/a7c8a12297a83a71dac47c32d2521e7de594b77d/server/src/import-contacts.ts#L82) consults redirects before source id lookup; redirected imports add identities without overwriting the chosen name. This is useful re-import stability but not complete provenance per field.

[HTTP merge](https://github.com/moritzWa/orbit/blob/a7c8a12297a83a71dac47c32d2521e7de594b77d/server/src/server.ts#L673) moves identities/messages and records Apple/LinkedIn/X redirects, then deletes source contacts. The inspected handler has no surrounding transaction or undo record. It deletes source tags and LinkedIn snapshots; it queries source emails after moving/deleting them, so intended email redirects can be empty. It temporarily disables foreign keys; existing redirect/connection chains are not comprehensively retargeted in this handler. Do not copy this merge algorithm as a safe primitive.

[CLI dedup](https://github.com/moritzWa/orbit/blob/a7c8a12297a83a71dac47c32d2521e7de594b77d/server/src/dedup-contacts.ts#L3) groups exact display_name and keeps the contact with most messages; distinct people with the same name can be collapsed. It deletes redirects pointing at removed contacts. [test-merge-redirect](../.references/orbit/server/src/test-merge-redirect.ts) tests reconstructed SQL scenarios, not the HTTP merge handler end to end. Search for undo/rollback in server/client source returned no implementation. [Deno tasks](../.references/orbit/server/deno.json) request `--allow-all`; imports read private macOS application databases, and optional enrichment makes network calls. Those tasks were not run.

## Recommendation

Build a focused Swift core with PostgreSQL 18.6/libpq persistence for the native app. The first slice stores the versioned aggregate in one JSONB row and locks it inside each write transaction; relational normalization and scale work remain measured follow-ups. Preserve multivalue identities, import batches and source records keyed by source namespace + stable id; keep explicit per-value provenance and normalized matching values. Suggest duplicates for review; never auto merge on name alone. Execute merge, relation moves, redirect retargeting and persisted before/after undo snapshots in one transaction. Refuse undo after conflicting edits. Support atomic, idempotent re-import. The current file importer commits a validated JSON document; import preview is a future UX step and is not claimed as implemented.

900CRM is a useful architectural reference for transactions, audit and snapshot conflict checks. Direct Rust adoption would require a maintained C ABI/Swift bridge, error and lifetime contracts, and substantial personal-contact schema changes. Orbit provides useful import/redirect UX concepts but has unresolved repository licensing and concrete data-integrity risks. Neither reference justifies introducing Rust into this small SwiftUI project now.

## Validation

Both clones were pinned with `git -C .references/<repo> rev-parse HEAD`. XERJ was invoked using documented CLI options with loopback URL, isolated prefixes/state dirs, `--no-graph --no-semantic --workers 2 --yes`. Commands, raw log paths, exit codes, coverage and real query outcomes are recorded in [local report](../.local/crm-index-report.json). Initial indexing attempts failed because the node had not started; subsequent outcomes are recorded separately. Application builds/import tests were not run: this slice is source research only.

Final local index results: 900CRM exit 3 (completed-with-junk), 431 indexed files of 487 discovered, 56 junk files, including six Svelte sources misclassified as XML; all 237 files classified as code were indexed. Orbit exit 3, 77 indexed files of 83 discovered, 6 junk; all 65 files classified as code indexed. Real searches returned 853 and 97 total hits respectively, and retrieved source files were read directly. Exact exclusions are retained in the local JSON report.


## Supplementary Svelte coverage correction

The main 900CRM index's `code_files=237/code_files_indexed=237` does **not** prove complete source coverage. Six `.svelte` sources were classified as XML and rejected with “no records extracted”: Dashboard, ActivityFeed, +page, KanbanBoard, EntityNotesPanel and EntityLinksPanel. The original 56 junk entries remain in the report, including binary assets.

Only those six rejected sources were copied verbatim after a provenance header into `.local/xerj-svelte-source/<original-path>.txt`. [Local map](../.local/xerj-svelte-source-map.json) records the pinned upstream commit, original path, original SHA256, copy SHA256 and original rejection. Source trees were untouched.

Supplementary command: `xerj autoindex .local/xerj-svelte-source --prefix mk-crm-900-svelte --state-dir .local/xerj-state/900-svelte --url http://127.0.0.1:19320 --no-graph --no-semantic --workers 2 --yes --json`.

Actual process exit **0**, terminal `reason=completed`, **6 indexed files, 68 records, 0 junk**. A match-all readback returned all six distinct copied paths: **6/6 previously rejected Svelte originals recovered**. `code_files=0` here is expected because these are explicit text copies; the supplementary record count/path readback is the relevant evidence.

`xerj search` against the text corpus exited 1 because its fixed code query references `name/defs/code/body/title`, whereas the actual searchable field is `text`. The raw error is retained. A real XERJ HTTP search on `text` for `createNote listNotesForEntity editingNoteId EntityNotesPanel` exited 0 and returned 6 hits, including EntityNotesPanel passages. The original [EntityNotesPanel.svelte](../.references/900CRM/apps/desktop/src/lib/components/EntityNotesPanel.svelte) was read directly to confirm the matched note create/list/edit symbols. Query/readback outputs and exact payload are retained in `.local/crm-index-report.json` under `supplementary_svelte`.

This closes the identified Svelte parser gap. It does not conceal the remaining 50 original junk entries or claim binary assets have searchable content.
