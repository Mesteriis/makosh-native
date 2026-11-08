import Foundation
import MakoshGoogle
import Security

/// CardDAV application passwords of person books; Google grants live in the shared `GoogleGrantVault`.
public actor PersonsCredentialVault {
    static let passwordService = "org.makosh.persons.carddav.v1"
    private static let limit = 16 * 1024
    private let access: KeychainAccess

    public init(access: KeychainAccess = .system) { self.access = access }

    public func savePassword(bookID: UUID, _ password: String) throws {
        guard !password.isEmpty, password.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PersonsFailure.invalidInput("password")
        }
        let data = Data(password.utf8)
        guard data.count <= Self.limit, access.write(Self.passwordService, bookID.uuidString, data) == errSecSuccess else {
            throw PersonsFailure.noAccess
        }
    }

    public func password(bookID: UUID) throws -> String? {
        let (status, data) = access.read(Self.passwordService, bookID.uuidString)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, let value = String(data: data, encoding: .utf8) else { throw PersonsFailure.noAccess }
        return value
    }

    public func removePassword(bookID: UUID) throws {
        let status = access.remove(Self.passwordService, bookID.uuidString)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PersonsFailure.noAccess }
    }
}
