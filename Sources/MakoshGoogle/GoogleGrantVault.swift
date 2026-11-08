import Foundation

/// Google consents shared by every section that signs in to Google (calendar today, contacts and
/// Gmail later): one Keychain item per account, plus an index of the accounts that signed in.
public actor GoogleGrantVault {
    public enum Failure: Error, Equatable, Sendable { case keyUnavailable }
    public static let service = "org.makosh.google.grants.v1"
    static let indexAccount = "index"
    private static let limit = 16 * 1024
    private let access: KeychainAccess

    public init(access: KeychainAccess = .system) { self.access = access }

    public func saveGrant(_ grant: GoogleGrant) throws {
        let data = try JSONEncoder().encode(grant)
        guard data.count <= Self.limit, access.write(Self.service, grant.subject, data) == errSecSuccess else {
            throw Failure.keyUnavailable
        }
        var subjects = try subjects()
        if !subjects.contains(grant.subject) {
            subjects.append(grant.subject)
            try saveSubjects(subjects)
        }
    }

    public func grant(subject: String) throws -> GoogleGrant? {
        let (status, data) = access.read(Self.service, subject)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= Self.limit,
            let grant = try? JSONDecoder().decode(GoogleGrant.self, from: data)
        else { throw Failure.keyUnavailable }
        return grant
    }

    public func removeGrant(subject: String) throws {
        let status = access.remove(Self.service, subject)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keyUnavailable }
        let subjects = try subjects().filter { $0 != subject }
        try saveSubjects(subjects)
    }

    /// Every saved grant, in the order the accounts first signed in.
    public func grants() throws -> [GoogleGrant] {
        try subjects().compactMap { try grant(subject: $0) }
    }

    private func subjects() throws -> [String] {
        let (status, data) = access.read(Self.service, Self.indexAccount)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data, let subjects = try? JSONDecoder().decode([String].self, from: data) else {
            throw Failure.keyUnavailable
        }
        return subjects
    }

    private func saveSubjects(_ subjects: [String]) throws {
        let data = try JSONEncoder().encode(subjects)
        guard data.count <= Self.limit, access.write(Self.service, Self.indexAccount, data) == errSecSuccess else {
            throw Failure.keyUnavailable
        }
    }
}

extension GoogleGrant {
    public func has(scope: String) -> Bool { scopes.contains(scope) }
}
