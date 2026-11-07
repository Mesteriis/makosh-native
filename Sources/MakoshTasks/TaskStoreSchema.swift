import Foundation

/// Every table of the section, in the application schema with a `tasks_` prefix.
/// Later tasks (attempts, connections, time) share this one definition so a
/// store opened by an older build still finds what a newer one wrote.
enum TaskStoreSchema {
    static func statements(schema: String) -> [String] {
        let s = "\"\(schema)\"."
        return [
            "CREATE SCHEMA IF NOT EXISTS \"\(schema)\"",
            """
            CREATE TABLE IF NOT EXISTS \(s)tasks_tasks(
                id UUID PRIMARY KEY, code TEXT NOT NULL UNIQUE, data JSONB NOT NULL, status TEXT NOT NULL, due DATE,
                deleted_at TIMESTAMPTZ, revision BIGINT NOT NULL, updated_at TIMESTAMPTZ NOT NULL)
            """,
            """
            CREATE TABLE IF NOT EXISTS \(s)tasks_versions(
                seq BIGSERIAL PRIMARY KEY, task_id UUID NOT NULL, revision BIGINT NOT NULL, actor TEXT NOT NULL,
                changed TEXT[] NOT NULL, data JSONB NOT NULL, at TIMESTAMPTZ NOT NULL)
            """,
            "CREATE INDEX IF NOT EXISTS tasks_versions_task ON \(s)tasks_versions(task_id, seq)",
            """
            CREATE TABLE IF NOT EXISTS \(s)tasks_sources(
                identity TEXT PRIMARY KEY, task_id UUID NOT NULL UNIQUE, membership TEXT NOT NULL,
                observed_at TIMESTAMPTZ, data JSONB)
            """,
            """
            CREATE TABLE IF NOT EXISTS \(s)tasks_source_versions(
                seq BIGSERIAL PRIMARY KEY, identity TEXT NOT NULL, observed_at TIMESTAMPTZ NOT NULL, data JSONB NOT NULL)
            """,
            "CREATE INDEX IF NOT EXISTS tasks_source_versions_identity ON \(s)tasks_source_versions(identity, seq)",
            "CREATE TABLE IF NOT EXISTS \(s)tasks_preferences(id SMALLINT PRIMARY KEY CHECK(id = 1), data JSONB NOT NULL)",
            """
            CREATE TABLE IF NOT EXISTS \(s)tasks_jira_attempts(
                id UUID PRIMARY KEY, task_id UUID NOT NULL, connection_id UUID NOT NULL, issue_id TEXT NOT NULL, kind TEXT NOT NULL,
                state TEXT NOT NULL, data JSONB NOT NULL, created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL,
                resolved_at TIMESTAMPTZ)
            """,
            "CREATE INDEX IF NOT EXISTS tasks_jira_attempts_task ON \(s)tasks_jira_attempts(task_id, created_at)",
            "CREATE TABLE IF NOT EXISTS \(s)tasks_jira_connections(id UUID PRIMARY KEY, data JSONB NOT NULL)",
            """
            CREATE TABLE IF NOT EXISTS \(s)tasks_time_entries(
                id UUID PRIMARY KEY, task_id UUID NOT NULL, started_at TIMESTAMPTZ NOT NULL, seconds INTEGER NOT NULL, data JSONB NOT NULL)
            """,
            "CREATE INDEX IF NOT EXISTS tasks_time_entries_task ON \(s)tasks_time_entries(task_id, started_at)",
            "CREATE TABLE IF NOT EXISTS \(s)tasks_timer(id SMALLINT PRIMARY KEY CHECK(id = 1), data JSONB NOT NULL)",
        ]
    }
}
