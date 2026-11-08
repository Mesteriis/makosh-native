import Foundation

/// Every table of the section, in the application schema with a `persons_` prefix.
/// Person records themselves stay in the core's `contact_records`.
enum PersonsStoreSchema {
    static let version = 1

    static func statements(schema: String) -> [String] {
        let s = "\"\(schema)\"."
        return [
            "CREATE SCHEMA IF NOT EXISTS \"\(schema)\"",
            "CREATE TABLE IF NOT EXISTS \(s)persons_meta(id SMALLINT PRIMARY KEY CHECK(id = 1), version INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS \(s)persons_books(id UUID PRIMARY KEY, data JSONB NOT NULL)",
            """
            CREATE TABLE IF NOT EXISTS \(s)persons_book_entries(
                id UUID PRIMARY KEY, person_id UUID NOT NULL, book_id UUID NOT NULL, external_id TEXT NOT NULL, state TEXT NOT NULL,
                data JSONB NOT NULL, UNIQUE(book_id, external_id))
            """,
            "CREATE INDEX IF NOT EXISTS persons_book_entries_person ON \(s)persons_book_entries(person_id)",
            """
            CREATE UNIQUE INDEX IF NOT EXISTS persons_book_entries_managed ON \(s)persons_book_entries(person_id, book_id)
                WHERE state = 'managed'
            """,
            """
            CREATE TABLE IF NOT EXISTS \(s)persons_attempts(
                id UUID PRIMARY KEY, person_id UUID NOT NULL, book_id UUID NOT NULL, state TEXT NOT NULL, data JSONB NOT NULL,
                created_at TIMESTAMPTZ NOT NULL)
            """,
            "CREATE INDEX IF NOT EXISTS persons_attempts_open ON \(s)persons_attempts(state, created_at)",
            "CREATE TABLE IF NOT EXISTS \(s)persons_cursors(source_key TEXT NOT NULL, scope TEXT NOT NULL, data JSONB NOT NULL, PRIMARY KEY(source_key, scope))",
            "CREATE TABLE IF NOT EXISTS \(s)persons_preferences(id SMALLINT PRIMARY KEY CHECK(id = 1), data JSONB NOT NULL)",
        ]
    }
}
