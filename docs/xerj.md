# Reproducible XERJ research

The installed provider is XERJ CLI `v1.0.0-rc.93`; `--help`, `autoindex --help`, `search --help` and `index --help` were inspected. Session MCP exposes map/search over its existing node, but that node contains historical Makosh indexes unrelated to this new tree. They were not reused as current evidence. A separate local node isolates this project's source indexes.

```sh
mkdir -p .local
# Run in a separate terminal; startup may print a private console link: keep this log local.
xerj --insecure --port 19320 --data-dir .local/xerj-data --embed-mode lexical --disable-feedback > .local/xerj-server.log 2>&1
```

The node binds loopback by default. Do not expose an insecure node to a network. No account data, secrets, external embeddings or rerank are used. There is no claim of neural semantic search or a compiler-grade call graph: used capabilities are lexical retrieval, source-definition passages when supported, and structured field queries. `--no-graph` was deliberately selected for reproducible source refresh/reconciliation; graph/call relationships were not inferred.

```sh
python3 scripts/prepare-references.py  # clone exact locked commits; never run upstream installers
python3 scripts/xerj-index.py MMail
python3 scripts/xerj-index.py MMail --check
xerj search --url http://127.0.0.1:19320 --prefix mk-com-mail 'IMAPSession connectAndLogin' -k 3
python3 scripts/xerj-index.py project
python3 scripts/xerj-index.py project --check
xerj search --url http://127.0.0.1:19320 --prefix mk-own 'undoMerge expectedRevision' -k 3
```

Run the index command for each of the eight lock names. Reuse the same generated `--no-graph` state directory for changes; rc.93 reconciles changed/added/removed files, but preparation still copies the complete scope (O(N)). Do not use `--fresh` as a deletion/reconciliation substitute. Check current content fingerprints and reference SHA before every reuse; a commit SHA alone does not cover uncommitted edits. The script refuses mismatched locked commits and records pre/post content fingerprints plus root and scope ignore rules outside Git. `--record-existing RESULT LOG` is for recording already-completed runs; it validates scope/terminal and records current content, but cannot reconstruct historical file edits. Original clones were checked for source changes separately.

Hidden files, `.git`, built-in build/vendor/generated directories and ignore rules are excluded. Communication scopes also exclude private/, databases, png/jpg/xcassets; Telegram submodules were not initialized/indexed and are an explicit integration-audit gap. The reproducer prepares local `.xerjignore` rules without modifying tracked upstream source. The project excludes `.references`, `.local`, `.build`, databases/images and the mutable development status ledger. Index state, logs, raw query results, machine configuration and fingerprints stay in `.local/` and are ignored. Exit 3 is completed-with-junk, not a clean exit 0; examine skipped paths before claiming coverage.

## Observed reference coverage

| Reference | Exit | Indexed files | Records | Classified code | Skips / limitation |
| --- | ---: | ---: | ---: | ---: | --- |
| TelegramSwift | 3 | 3,017 | 59,656 | 2,412/2,412 | 70 non-code; submodules excluded |
| MMail | 0 | 45 | 647 | 39/39 | none in selected scope |
| Aether Courier | 3 | 70 | 923 | 57/57 | 11 PNGs; screenshot inspected visually |
| WhatsApp Zen | 3 | 85 | 4,664 | 66/66 | one ICNS |
| teams-cli | 0 | 25 | 285 | 14/14 | none in selected scope |
| Yandex Messenger | 3 | 132 | 2,206 | 73/73 | 10 PNGs, 2 duplicate-content files |
| 900CRM | 3 | 431 | 4,259 | 237/237 | 56 initial skips, including 6 Svelte sources |
| Orbit | 3 | 77 | 433 | 65/65 | 6 PNGs |

900CRM's classified-code metric did not count Svelte. A supplementary text index `mk-crm-900-svelte` recovered **6/6** rejected Svelte originals (exit 0, 6 files, 68 records, 0 junk), with original path/commit/SHA256 mapping. Text corpus fields differ: code CLI search failed; an actual structured XERJ query on `text` succeeded. See `research-crm.md`. Remaining binary/empty/archive skips are explicitly recorded; this is not a claim of searchable media or downloaded dependency coverage.

## How searches affected implementation

- 900CRM `ImportRollbackPlan`/snapshot conflict checks informed undo's expected revision guard. Orbit `merge_redirects`/import lookups informed keeping both source identities on the survivor. Reading Orbit's handler exposed nontransactional moves and tag/snapshot losses, so Makosh implements an independent transaction and lossless snapshots rather than adopting that algorithm.
- `RootView`/`ReadingPaneView` retrieval plus the inspected Aether screenshot informed the three-column hierarchy, dossier panel, caption metadata and expandable source details.
- WhatsApp `WACall WAFree` identified the real C/JSON memory boundary (header, Rust ffi and legacy Go source); Swift/Rust is deferred until that service needs a versioned bridge. `GraphClient BASE_SCOPES` confirmed the selected Teams crate has a public library surface but no Swift ABI.
- `TelemostClient` showed the reference itself considers endpoint mapping unconfirmed; this supports official browser handoff as the current implemented meeting capability.
- Project queries on merge/undo/import and tests are used during integration review. Results must be checked against actual source; refresh after any resulting edit.

Raw local report pointers: `.local/crm-index-report.json`, `.local/communications-index-report.json`, `.local/aether-index.json`, `.local/yandex-index.json`, `.local/freshness/`. Public lock and research documents contain only source metadata and aggregate outcomes.
