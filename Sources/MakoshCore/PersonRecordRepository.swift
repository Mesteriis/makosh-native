import Foundation

/// Row-level persistence for `PersonStore`: one JSONB row per contact and per
/// merge, plus per-identity import watermarks. Writers hold a schema-scoped
/// transaction advisory lock, so mutations stay serialized across connections
/// while each write touches only the contacts it changes.
final class PersonRecordRepository {
    static let schemaVersion = 3
    /// The only earlier version that upgrades in place: its JSONB rows decode with version-3 defaults.
    static let upgradableVersion = 2

    private let connection: PostgresConnection
    private let schema: String
    private let contacts: String
    private let fetches: String
    private let merges: String
    private let meta: String
    let memberships: String
    let values: String
    let noMerge: String
    let mailEvidence: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(connectionString: String, schema: String) throws {
        guard PostgresConnection.isValidSchemaName(schema) else {
            throw StoreError.invalid("Недопустимое имя схемы PostgreSQL.")
        }
        guard !connectionString.utf8.contains(0) else {
            throw StoreError.invalid("Недопустимая строка подключения PostgreSQL.")
        }
        do { connection = try PostgresConnection(connectionString: connectionString) } catch {
            throw StoreError.database("PostgreSQL connection failed.")
        }
        self.schema = schema
        let prefix = "\"\(schema)\"."
        contacts = prefix + "contact_records"
        fetches = prefix + "contact_source_fetches"
        merges = prefix + "contact_merges"
        meta = prefix + "contact_store_meta"
        memberships = prefix + "person_memberships"
        values = prefix + "person_values"
        noMerge = prefix + "person_no_merge"
        mailEvidence = prefix + "person_mail_evidence"
        do {
            try connection.transaction {
                // Serialize initial creation for two connections opening the same schema.
                try connection.execute("SELECT pg_advisory_xact_lock(hashtext('makosh-schema'), hashtext($1))", [schema])
                try connection.execute("CREATE SCHEMA IF NOT EXISTS \"\(schema)\"")
                try connection.execute(
                    "CREATE TABLE IF NOT EXISTS \(meta) (id SMALLINT PRIMARY KEY CHECK (id=1), schema_version INTEGER NOT NULL)")
                try connection.execute(
                    "INSERT INTO \(meta) (id, schema_version) VALUES (1, $1) ON CONFLICT (id) DO NOTHING",
                    [String(Self.schemaVersion)])
                try connection.execute("CREATE TABLE IF NOT EXISTS \(contacts) (id UUID PRIMARY KEY, payload JSONB NOT NULL)")
                try connection.execute(
                    "CREATE INDEX IF NOT EXISTS contact_records_identities ON \(contacts) USING gin ((payload->'identities') jsonb_path_ops)"
                )
                try connection.execute(
                    "CREATE INDEX IF NOT EXISTS contact_records_notes ON \(contacts) USING gin ((payload->'notes') jsonb_path_ops)")
                try connection.execute(
                    "CREATE TABLE IF NOT EXISTS \(fetches) (identity_key TEXT PRIMARY KEY, fetched_at DOUBLE PRECISION NOT NULL)")
                try connection.execute("CREATE TABLE IF NOT EXISTS \(merges) (id UUID PRIMARY KEY, payload JSONB NOT NULL)")
                try connection.execute(
                    "CREATE TABLE IF NOT EXISTS \(memberships) (id UUID PRIMARY KEY, organization_id UUID NOT NULL, person_id UUID NOT NULL, payload JSONB NOT NULL)"
                )
                try connection.execute("CREATE INDEX IF NOT EXISTS person_memberships_organization ON \(memberships) (organization_id)")
                try connection.execute("CREATE INDEX IF NOT EXISTS person_memberships_person ON \(memberships) (person_id)")
                try connection.execute(
                    "CREATE TABLE IF NOT EXISTS \(values) (person_id UUID NOT NULL, field TEXT NOT NULL, normalized TEXT NOT NULL, raw TEXT NOT NULL, PRIMARY KEY (person_id, field, normalized))"
                )
                try connection.execute("CREATE INDEX IF NOT EXISTS person_values_lookup ON \(values) (field, normalized)")
                try connection.execute(
                    "CREATE TABLE IF NOT EXISTS \(noMerge) (first_id UUID NOT NULL, second_id UUID NOT NULL, PRIMARY KEY (first_id, second_id))"
                )
                try connection.execute(
                    "CREATE TABLE IF NOT EXISTS \(mailEvidence) (account_id TEXT NOT NULL, address TEXT NOT NULL, clean_count INTEGER NOT NULL, spam_count INTEGER NOT NULL, PRIMARY KEY (account_id, address))"
                )
                try upgradeIfNeeded()
                try checkVersion()
            }
        } catch {
            connection.close()
            throw Self.storeError(error)
        }
    }

    // MARK: Transactions

    func read<T>(_ body: () throws -> T) throws -> T {
        try wrap {
            try connection.transaction {
                try checkVersion()
                return try body()
            }
        }
    }

    func write<T>(_ body: () throws -> T) throws -> T {
        try wrap {
            try connection.transaction {
                try connection.execute("SELECT pg_advisory_xact_lock(hashtext('makosh-contacts'), hashtext($1))", [schema])
                try checkVersion()
                return try body()
            }
        }
    }

    // MARK: Persons

    func allPersons() throws -> [Person] {
        try connection.query("SELECT payload::text FROM \(contacts)").map { try decode(Person.self, $0[0]) }
    }

    /// Persons that are neither deleted nor hidden as spam.
    func activePersons() throws -> [Person] {
        try connection.query(
            "SELECT payload::text FROM \(contacts) WHERE payload->>'deletedAt' IS NULL AND COALESCE((payload->>'hiddenAsSpam')::boolean, false) = false"
        ).map { try decode(Person.self, $0[0]) }
    }

    func person(id: UUID) throws -> Person? {
        try connection.query("SELECT payload::text FROM \(contacts) WHERE id=$1::uuid", [id.uuidString])
            .first.map { try decode(Person.self, $0[0]) }
    }

    /// Every contact whose identities contain `identity`; more than one is corruption.
    func persons(owning identity: ServiceIdentity) throws -> [Person] {
        try connection.query(
            "SELECT payload::text FROM \(contacts) WHERE payload->'identities' @> $1::jsonb ORDER BY id",
            [try encode([identity])]
        ).map { try decode(Person.self, $0[0]) }
    }

    func persons(owningNote id: UUID) throws -> [Person] {
        try connection.query(
            "SELECT payload::text FROM \(contacts) WHERE payload->'notes' @> $1::jsonb ORDER BY id",
            [try encode([["id": id]])]
        ).map { try decode(Person.self, $0[0]) }
    }

    func insert(_ contact: Person) throws {
        try connection.execute(
            "INSERT INTO \(contacts) (id, payload) VALUES ($1::uuid, $2::jsonb)",
            [contact.id.uuidString, try encode(contact)])
        try reindexValues(contact)
    }

    func update(_ contact: Person) throws {
        let rows = try connection.query(
            "UPDATE \(contacts) SET payload=$2::jsonb WHERE id=$1::uuid RETURNING id",
            [contact.id.uuidString, try encode(contact)])
        guard rows.count == 1 else { throw StoreError.database("PostgreSQL contact update did not affect exactly one row.") }
        try reindexValues(contact)
    }

    func delete(contactID: UUID) throws {
        let rows = try connection.query("DELETE FROM \(contacts) WHERE id=$1::uuid RETURNING id", [contactID.uuidString])
        guard rows.count == 1 else { throw StoreError.database("PostgreSQL contact delete did not affect exactly one row.") }
        try connection.execute("DELETE FROM \(values) WHERE person_id=$1::uuid", [contactID.uuidString])
    }

    // MARK: Value index

    private func reindexValues(_ contact: Person) throws {
        try connection.execute("DELETE FROM \(values) WHERE person_id=$1::uuid", [contact.id.uuidString])
        for row in PersonMatching.indexRows(contact) {
            try connection.execute(
                "INSERT INTO \(values) (person_id, field, normalized, raw) VALUES ($1::uuid, $2, $3, $4)",
                [contact.id.uuidString, row.field, row.normalized, row.raw])
        }
    }

    func personCount(emailDomain domain: String) throws -> Int {
        let row = try connection.query(
            "SELECT count(DISTINCT person_id)::text FROM \(values) WHERE field='emails' AND split_part(normalized, '@', 2)=$1",
            [domain.lowercased()]
        ).first
        return Int(row?[0] ?? "0") ?? 0
    }

    struct SharedValue {
        let field: String
        let normalized: String
        let personIDs: [UUID]
    }

    /// Every (field, value) held by two or more persons, with their ids in insertion order.
    func sharedValues() throws -> [SharedValue] {
        try connection.query(
            "SELECT field, normalized, string_agg(person_id::text, ',' ORDER BY person_id) FROM \(values) GROUP BY field, normalized HAVING count(*) > 1 ORDER BY field, normalized"
        ).map { row in
            SharedValue(
                field: row[0], normalized: row[1], personIDs: row[2].split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        }
    }

    /// Persons sharing a value with `personID`, with the value and how many persons hold it in all.
    func valueMatches(personID: UUID) throws -> [(field: String, normalized: String, raw: String, otherID: UUID, holders: Int)] {
        try connection.query(
            "SELECT mine.field, mine.normalized, mine.raw, other.person_id::text, "
                + "(SELECT count(*) FROM \(values) all_rows WHERE all_rows.field=mine.field AND all_rows.normalized=mine.normalized) "
                + "FROM \(values) mine JOIN \(values) other ON other.field=mine.field AND other.normalized=mine.normalized AND other.person_id<>mine.person_id "
                + "WHERE mine.person_id=$1::uuid ORDER BY mine.field, mine.normalized, other.person_id",
            [personID.uuidString]
        ).compactMap { row in
            guard let other = UUID(uuidString: row[3]), let holders = Int(row[4]) else { return nil }
            return (row[0], row[1], row[2], other, holders)
        }
    }

    // MARK: Import watermarks

    func fetchedAt(_ identity: ServiceIdentity) throws -> Date? {
        guard let text = try connection.query("SELECT fetched_at::text FROM \(fetches) WHERE identity_key=$1", [identity.id]).first?[0]
        else { return nil }
        guard let interval = Double(text), interval.isFinite else { throw StoreError.database("PostgreSQL import watermark is invalid.") }
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    func setFetchedAt(_ date: Date, for identity: ServiceIdentity) throws {
        try connection.execute(
            "INSERT INTO \(fetches) (identity_key, fetched_at) VALUES ($1, $2::double precision) ON CONFLICT (identity_key) DO UPDATE SET fetched_at=EXCLUDED.fetched_at",
            [identity.id, String(date.timeIntervalSinceReferenceDate)])
    }

    // MARK: Memberships

    func memberships(personID: UUID) throws -> [PersonMembership] {
        try connection.query("SELECT payload::text FROM \(memberships) WHERE person_id=$1::uuid ORDER BY id", [personID.uuidString])
            .map { try decode(PersonMembership.self, $0[0]) }
    }

    func memberships(organizationID: UUID) throws -> [PersonMembership] {
        try connection.query(
            "SELECT payload::text FROM \(memberships) WHERE organization_id=$1::uuid ORDER BY id", [organizationID.uuidString]
        ).map { try decode(PersonMembership.self, $0[0]) }
    }

    func allMemberships() throws -> [PersonMembership] {
        try connection.query("SELECT payload::text FROM \(memberships) ORDER BY id").map { try decode(PersonMembership.self, $0[0]) }
    }

    func membership(id: UUID) throws -> PersonMembership? {
        try connection.query("SELECT payload::text FROM \(memberships) WHERE id=$1::uuid", [id.uuidString]).first
            .map { try decode(PersonMembership.self, $0[0]) }
    }

    func upsert(_ membership: PersonMembership) throws {
        try connection.execute(
            "INSERT INTO \(memberships) (id, organization_id, person_id, payload) VALUES ($1::uuid, $2::uuid, $3::uuid, $4::jsonb) "
                + "ON CONFLICT (id) DO UPDATE SET organization_id=EXCLUDED.organization_id, person_id=EXCLUDED.person_id, payload=EXCLUDED.payload",
            [membership.id.uuidString, membership.organizationID.uuidString, membership.personID.uuidString, try encode(membership)])
    }

    // MARK: No-merge pairs

    func noMergePairs() throws -> Set<NoMergePair> {
        Set(
            try connection.query("SELECT first_id::text, second_id::text FROM \(noMerge)").compactMap { row in
                guard let first = UUID(uuidString: row[0]), let second = UUID(uuidString: row[1]) else { return nil }
                return NoMergePair(first, second)
            })
    }

    func insert(_ pair: NoMergePair) throws {
        try connection.execute(
            "INSERT INTO \(noMerge) (first_id, second_id) VALUES ($1::uuid, $2::uuid) ON CONFLICT DO NOTHING",
            [pair.first.uuidString, pair.second.uuidString])
    }

    // MARK: Mail evidence

    func recordMailEvidence(accountID: String, address: String, spam: Bool) throws -> (clean: Int, spam: Int) {
        let row = try connection.query(
            "INSERT INTO \(mailEvidence) (account_id, address, clean_count, spam_count) VALUES ($1, $2, $3::integer, $4::integer) "
                + "ON CONFLICT (account_id, address) DO UPDATE SET clean_count=\(mailEvidence).clean_count+EXCLUDED.clean_count, "
                + "spam_count=\(mailEvidence).spam_count+EXCLUDED.spam_count RETURNING clean_count::text, spam_count::text",
            [accountID, address, spam ? "0" : "1", spam ? "1" : "0"]
        ).first
        guard let row, let clean = Int(row[0]), let spamCount = Int(row[1]) else {
            throw StoreError.database("PostgreSQL mail evidence update did not return counts.")
        }
        return (clean, spamCount)
    }

    func mailEvidence(address: String) throws -> (clean: Int, spam: Int) {
        let row = try connection.query(
            "SELECT COALESCE(sum(clean_count), 0)::text, COALESCE(sum(spam_count), 0)::text FROM \(mailEvidence) WHERE address=$1",
            [address]
        ).first
        return (Int(row?[0] ?? "0") ?? 0, Int(row?[1] ?? "0") ?? 0)
    }

    // MARK: Merges

    func allMerges() throws -> [MergeRecord] {
        try connection.query("SELECT payload::text FROM \(merges)").map { try decode(MergeRecord.self, $0[0]) }
    }

    func merge(id: UUID) throws -> MergeRecord? {
        try connection.query("SELECT payload::text FROM \(merges) WHERE id=$1::uuid", [id.uuidString])
            .first.map { try decode(MergeRecord.self, $0[0]) }
    }

    func insert(_ record: MergeRecord) throws {
        try connection.execute(
            "INSERT INTO \(merges) (id, payload) VALUES ($1::uuid, $2::jsonb)", [record.id.uuidString, try encode(record)])
    }

    func update(_ record: MergeRecord) throws {
        let rows = try connection.query(
            "UPDATE \(merges) SET payload=$2::jsonb WHERE id=$1::uuid RETURNING id",
            [record.id.uuidString, try encode(record)])
        guard rows.count == 1 else { throw StoreError.database("PostgreSQL merge update did not affect exactly one row.") }
    }

    // MARK: Helpers

    /// Version 2 rows decode with version-3 defaults; manual list fields become manual values.
    private func upgradeIfNeeded() throws {
        guard let text = try connection.query("SELECT schema_version::text FROM \(meta) WHERE id=1").first?[0], let version = Int(text),
            version == Self.upgradableVersion
        else { return }
        for var person in try allPersons() {
            for field in PersonListField.allCases where person.manualFields.contains(field.rawValue) {
                person.manualFields.remove(field.rawValue)
                for value in person.values(field) { person.manualValues.insert(ManualValue(field: field.rawValue, value: value)) }
            }
            try update(person)
        }
        try connection.execute("UPDATE \(meta) SET schema_version=$1 WHERE id=1", [String(Self.schemaVersion)])
    }

    private func checkVersion() throws {
        guard let text = try connection.query("SELECT schema_version::text FROM \(meta) WHERE id=1").first?[0],
            let version = Int(text)
        else { throw StoreError.database("PostgreSQL contact store metadata is missing or invalid.") }
        guard version == Self.schemaVersion else { throw StoreError.unsupportedSchema(version) }
    }

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw Self.storeError(error) }
    }

    private static func storeError(_ error: Error) -> Error {
        guard let failure = error as? PostgresConnection.Failure else { return error }
        if let code = failure.sqlState { return StoreError.database("PostgreSQL operation failed (SQLSTATE \(code)).") }
        return StoreError.database("PostgreSQL operation failed.")
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) } catch {
            throw StoreError.database("State encoding failed.")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        do { return try decoder.decode(type, from: Data(text.utf8)) } catch {
            throw StoreError.database("PostgreSQL state payload is invalid.")
        }
    }
}
