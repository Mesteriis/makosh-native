# JSON import, schema 1

Choose **Импорт JSON** in Contacts and open `Examples/contacts.synthetic.json`. The sample contains only fictional people and reserved example addresses. Nothing is imported on first launch automatically.

```json
{
  "schemaVersion": 1,
  "source": {"service": "demo-json", "accountID": "synthetic-work"},
  "fetchedAt": "2026-10-10T10:00:00Z",
  "contacts": [
    {"externalID": "demo-1", "displayName": "Вымышленный контакт",
     "organization": "Пример", "jobTitle": "Дизайнер",
     "phones": ["+1 202 555 0101"], "emails": ["person@example.invalid"],
     "tags": ["Синтетические данные"], "notes": ["Синтетическая заметка"]}
  ]
}
```

Top-level `schemaVersion`, `source`, `fetchedAt` and `contacts` are required. `source.service` and `source.accountID` are nonempty opaque strings. The date is ISO 8601 UTC (e.g. the sample's whole-second form). Every record requires nonempty `externalID` and `displayName`. Optional `organization`/`jobTitle` are strings or null; omitted values do not clear existing fields. `phones`, `emails`, `tags`, `notes` are arrays of strings, defaulting to empty. Malformed JSON, unsupported version, empty name/identity, or a duplicate external ID in the same document rejects the complete import before any contact changes.

Identity equality uses exact UTF-8 bytes of the service/account/external-ID tuple, case-sensitively. Canonical-equivalent Unicode spellings remain different opaque identifiers; raw source strings are preserved. Use stable source IDs and account IDs. Do not use an access token as an account ID. Reimport with the same identity updates the same contact; merge moves both sets of identities to the survivor, so subsequent imports route there. Distinct source accounts with equal external IDs remain distinct cards until explicitly merged.

Imports are additive for phones/email/tags/notes, retaining existing values and evidence. They are not deletion instructions. Manual changes lock the affected field, including an intentionally emptied array. Later imports retain their observations in the dossier without replacing those overrides. Editing and saving an unchanged field does not lock an imported field. A manual-created contact starts with manual fields under user control. There is no override-reset UI in this first stage.

Every observation retains its source identity and fetched time. Reimporting the identical document is a no-op for contact content, notes and events. A newer timestamp updates provenance and therefore counts as a change; this can legitimately block merge undo. Older source timestamps cannot replace newer values. Equal timestamps with different values are treated as an updated source snapshot in import order, not assumed trustworthy conflict resolution.

The duplicate queue offers shared normalized email/phone matches and explains the reason. It never merges automatically and never equates people by name alone. Open **Объединения**, review both cards, choose the survivor and confirm. Differing name/company/role fields become a manual merge choice: reimport preserves the survivor's chosen scalar while retaining both source observations. Identical already-seen imports remain a no-op, so undo still works. **История объединений** can restore both snapshots; if the survivor was edited, changed by import or merged later, cancellation stops explicitly to preserve subsequent data. Manual review is then required.

Imports commit atomically to the configured PostgreSQL database. The first store schema keeps contacts, source observations, import watermarks and merge snapshots together in one JSONB state row; row locking serializes changes across connections. This is not a standalone file import database: PostgreSQL must be available. Configure a separate schema/database for synthetic acceptance tests rather than replacing production data. The schema-1 JSON import contract is independent of the internal storage schema.
