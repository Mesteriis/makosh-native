import Foundation

/// Every table of the OSINT module, in the application schema with a `persons_osint_` prefix.
/// Dossier records stay in the core; the persons section's own tables are not touched.
enum OSINTStoreSchema {
    static let version = 1

    static func statements(schema: String) -> [String] {
        let s = "\"\(schema)\"."
        return [
            "CREATE SCHEMA IF NOT EXISTS \"\(schema)\"",
            "CREATE TABLE IF NOT EXISTS \(s)persons_osint_meta(id SMALLINT PRIMARY KEY CHECK(id = 1), version INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS \(s)persons_osint_settings(id SMALLINT PRIMARY KEY CHECK(id = 1), data JSONB NOT NULL)",
            "CREATE TABLE IF NOT EXISTS \(s)persons_osint_sketches(person_id UUID PRIMARY KEY, data JSONB NOT NULL)",
            """
            CREATE TABLE IF NOT EXISTS \(s)persons_osint_runs(
                id UUID PRIMARY KEY, person_id UUID NOT NULL, state TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL, data JSONB NOT NULL)
            """,
            "CREATE INDEX IF NOT EXISTS persons_osint_runs_person ON \(s)persons_osint_runs(person_id, created_at)",
            """
            CREATE TABLE IF NOT EXISTS \(s)persons_osint_attempts(
                id UUID PRIMARY KEY, run_id UUID NULL, state TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL, data JSONB NOT NULL)
            """,
            "CREATE INDEX IF NOT EXISTS persons_osint_attempts_open ON \(s)persons_osint_attempts(state, created_at)",
            "CREATE TABLE IF NOT EXISTS \(s)persons_osint_installs(id UUID PRIMARY KEY, created_at TIMESTAMPTZ NOT NULL, data JSONB NOT NULL)",
        ]
    }
}
