import Foundation

/// Every table of the section, in the application schema with a `calendar_` prefix.
enum CalendarStoreSchema {
    static func statements(schema: String) -> [String] {
        let s = "\"\(schema)\"."
        return [
            "CREATE SCHEMA IF NOT EXISTS \"\(schema)\"",
            "CREATE TABLE IF NOT EXISTS \(s)calendar_metadata(id SMALLINT PRIMARY KEY CHECK(id = 1), version INTEGER NOT NULL, vault UUID NOT NULL)",
            "CREATE TABLE IF NOT EXISTS \(s)calendar_accounts(id UUID PRIMARY KEY, data JSONB NOT NULL)",
            "CREATE TABLE IF NOT EXISTS \(s)calendar_collections(id UUID PRIMARY KEY, account_id UUID NOT NULL, data JSONB NOT NULL)",
            "CREATE TABLE IF NOT EXISTS \(s)calendar_groups(id UUID PRIMARY KEY, data JSONB NOT NULL)",
            """
            CREATE TABLE IF NOT EXISTS \(s)calendar_events(
                id UUID PRIMARY KEY, collection_id UUID NOT NULL, uid TEXT NOT NULL, external_id TEXT, master_id UUID,
                recurrence_id TIMESTAMPTZ, starts_at TIMESTAMPTZ NOT NULL, ends_at TIMESTAMPTZ NOT NULL, recurring BOOLEAN NOT NULL,
                busy_source UUID, task_id UUID, deleted_at TIMESTAMPTZ, revision BIGINT NOT NULL, data JSONB NOT NULL, sealed TEXT NOT NULL)
            """,
            "CREATE INDEX IF NOT EXISTS calendar_events_window ON \(s)calendar_events(collection_id, starts_at)",
            """
            CREATE UNIQUE INDEX IF NOT EXISTS calendar_events_external ON \(s)calendar_events(collection_id, external_id)
                WHERE external_id IS NOT NULL
            """,
            "CREATE INDEX IF NOT EXISTS calendar_events_uid ON \(s)calendar_events(collection_id, uid)",
            """
            CREATE TABLE IF NOT EXISTS \(s)calendar_event_versions(
                seq BIGSERIAL PRIMARY KEY, event_id UUID NOT NULL, revision BIGINT NOT NULL, actor TEXT NOT NULL, data JSONB NOT NULL,
                sealed TEXT NOT NULL, at TIMESTAMPTZ NOT NULL)
            """,
            "CREATE INDEX IF NOT EXISTS calendar_event_versions_event ON \(s)calendar_event_versions(event_id, seq)",
            "CREATE TABLE IF NOT EXISTS \(s)calendar_cursors(collection_id UUID PRIMARY KEY, data TEXT NOT NULL)",
            """
            CREATE TABLE IF NOT EXISTS \(s)calendar_busy_copies(
                id UUID PRIMARY KEY, source_event_id UUID NOT NULL, occurrence_key TIMESTAMPTZ NOT NULL, target_collection_id UUID NOT NULL,
                data JSONB NOT NULL, UNIQUE(source_event_id, occurrence_key, target_collection_id))
            """,
            """
            CREATE TABLE IF NOT EXISTS \(s)calendar_attempts(
                id UUID PRIMARY KEY, event_id UUID, copy_id UUID, collection_id UUID NOT NULL, kind TEXT NOT NULL, state TEXT NOT NULL,
                data JSONB NOT NULL, created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL, resolved_at TIMESTAMPTZ)
            """,
            "CREATE INDEX IF NOT EXISTS calendar_attempts_event ON \(s)calendar_attempts(event_id, created_at)",
            "CREATE TABLE IF NOT EXISTS \(s)calendar_preferences(id SMALLINT PRIMARY KEY CHECK(id = 1), data JSONB NOT NULL)",
        ]
    }
}
