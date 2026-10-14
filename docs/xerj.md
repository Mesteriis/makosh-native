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
xerj search --url http://127.0.0.1:19320 --prefix mk-own-v13 'undoMerge expectedRevision' -k 3
```

Reference preparation is optional research work. Application build/run/test uses
`Dependencies/TelegramEngine.lock.json` and a separate bare source cache; it
neither requires this research step nor reads/creates `.references/`.

Run the index command for each of the eight lock names. Reuse the same generated `--no-graph` state directory for changes; rc.93 reconciles changed/added/removed files, but preparation still copies the complete scope (O(N)). Do not use `--fresh` as a deletion/reconciliation substitute. Check current content fingerprints and reference SHA before every reuse; a commit SHA alone does not cover uncommitted edits. The script refuses mismatched locked commits and records pre/post content fingerprints plus root and scope ignore rules outside Git. `--record-existing RESULT LOG` is for recording already-completed runs; it validates scope/terminal and records current content, but cannot reconstruct historical file edits. Original clones were checked for source changes separately.

Adding retained `.notice` license files caused the original `mk-own` frozen
dataset to refuse new text fields (actual exit 1, unsupported schema evolution).
The separate `mk-own-v2` scope then completed successfully. Adding Makosh's own
dependency lock later caused v2 to reject the new JSON fields (actual exit 1).
The subsequent S3 dependency lock also introduced new JSON fields; v3 refused the unsupported schema evolution (exit 1). The Opus dependency lock later introduced archive and manifest JSON fields; v4 also refused schema evolution (exit 1). The OpusFile lock subsequently introduced nested archive JSON fields; v5 refused schema evolution (exit1). The Mozjpeg lock then introduced per-file source hashes; v6 also refused schema evolution (exit1). The next successful project scope used a separate `mk-own-v7` prefix/state, following
the diagnostic's new-prefix instruction. These failures remain recorded locally;
old prefixes are not reused as current evidence. Reference/engine scopes are
unchanged. The block-2 Prisma/Boost dependency lock introduces nested dependency
fields; v7 also refuses unsupported schema evolution (actual exit1). The next successful project scope used `mk-own-v8`/`project-v8`.
Adding the VPX source inventory then causes v8 to refuse unsupported schema
evolution (actual exit1). The current project uses `mk-own-v12`/`project-v9`,
following that diagnostic's new-prefix instruction. The dependency lock stays within the indexed project scope.

Hidden files, `.git`, built-in build/vendor/generated directories and ignore rules are excluded. Communication reference scopes also exclude private/, databases, png/jpg/xcassets; the original TelegramSwift index excludes submodules. Its selected TelegramCore engine is now prepared, audited and indexed separately as described below. The reproducer prepares local `.xerjignore` rules without modifying tracked upstream source. The project excludes `.references`, `.local`, `.build`, databases/images and the mutable development status ledger. Index state, logs, raw query results, machine configuration and fingerprints stay in `.local/` and are ignored. Exit 3 is completed-with-junk, not a clean exit 0; examine skipped paths before claiming coverage.

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

## Telegram engine integration scope

```sh
python3 scripts/prepare-telegram.py
python3 scripts/xerj-index.py telegram-engine
python3 scripts/xerj-index.py telegram-engine --check
xerj search --url http://127.0.0.1:19320 --prefix mk-telegram-engine 'sendAuthorizationCode authorizeWithPassword' -k 3
```

This separately indexes `.local/telegram-engine/submodules/TelegramCore`, after
checking the pinned preparation recipe and exact SHA256/file-set record. The
build pin comes from Makosh's own dependency lock; reference clones are not used.
The scope includes generated FlatSerialization sources and bundled FlatBuffers;
the sibling Postbox/MtProtoKit and other packages were audited/read for build
and lifecycle integration but are not claimed as indexed by this scope.
Observed recipe20 engine refresh: **exit 0, 722 indexed files, 687/687 classified
code files**. Fingerprints cover current adapted/generated content before and
after indexing. `--check` revalidates the complete prepared engine as well as
this index fingerprint. No session cache, private API configuration or Keychain
data is indexed. Local API credentials are outside the project/index root.

Actual engine queries retrieved `sendAuthorizationCode`/`authorizeWithPassword`
from `Authorization.swift` and `tailChatListView`/history-view APIs from
`AccountViewTracker.swift`; source reads confirmed their signatures and auth
state transitions. This led to direct engine integration, explicit outbox
acknowledgement, disposal/generation guards, disabled logging and privacy/cache
adaptations. Project refresh/search also covers the new adapter and regressions.
Raw records: `.local/telegram-engine-refresh.{json,log}` and
`.local/freshness/telegram-engine.json`. The original eight reference counts
above remain historical scope-specific results, not full dependency coverage.

900CRM's classified-code metric did not count Svelte. A supplementary text index `mk-crm-900-svelte` recovered **6/6** rejected Svelte originals (exit 0, 6 files, 68 records, 0 junk), with original path/commit/SHA256 mapping. Text corpus fields differ: code CLI search failed; an actual structured XERJ query on `text` succeeded. See `research-crm.md`. Remaining binary/empty/archive skips are explicitly recorded; this is not a claim of searchable media or downloaded dependency coverage.

## How searches affected implementation

- 900CRM `ImportRollbackPlan`/snapshot conflict checks informed undo's expected revision guard. Orbit `merge_redirects`/import lookups informed keeping both source identities on the survivor. Reading Orbit's handler exposed nontransactional moves and tag/snapshot losses, so Makosh implements an independent transaction and lossless snapshots rather than adopting that algorithm.
- `RootView`/`ReadingPaneView` retrieval plus the inspected Aether screenshot informed the three-column hierarchy, dossier panel, caption metadata and expandable source details.
- WhatsApp `WACall WAFree` identified the real C/JSON memory boundary (header, Rust ffi and legacy Go source); Swift/Rust is deferred until that service needs a versioned bridge. `GraphClient BASE_SCOPES` confirmed the selected Teams crate has a public library surface but no Swift ABI.
- `TelemostClient` showed the reference itself considers endpoint mapping unconfirmed; this supports official browser handoff as the current implemented meeting capability.
- Project queries on merge/undo/import and tests are used during integration review. Results must be checked against actual source; refresh after any resulting edit.

Raw local report pointers: `.local/crm-index-report.json`, `.local/communications-index-report.json`, `.local/aether-index.json`, `.local/yandex-index.json`, `.local/freshness/`. Public lock and research documents contain only source metadata and aggregate outcomes.

Final block13 TCP adaptations add two reviewed lock entries; v11 refuses unsupported frozen JSON schema evolution (actual exit1). Current project uses a separate mk-own-v12/project-v12 scope. Prior indexes are retained; only the new successful fingerprint may be reused.

The final-parity call-key data lock adds new provenance JSON fields. The v12
refresh actually exits1 with frozen-dataset schema evolution refusal. The
current project uses separate `mk-own-v13`/`project-v13`; prior states are
retained. No lock fields or source files are excluded to disguise this failure.
Reference/engine and bounded debug-snapshot scopes remain unchanged.
