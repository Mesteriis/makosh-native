import Foundation
import MakoshCore
import MakoshGoogle
import Security

public typealias CalendarKeychainAccess = KeychainAccess

/// CalDAV passwords belong to calendar accounts; Google grants live in the shared `GoogleGrantVault`.
public actor CalendarCredentialVault {
    static let passwordService = "org.makosh.calendar.caldav.v1"
    private static let limit = 16 * 1024
    private let access: KeychainAccess
    private let grants: GoogleGrantVault

    public init(access: KeychainAccess = .system) {
        self.access = access
        grants = GoogleGrantVault(access: access)
    }

    public func saveGrant(_ grant: GoogleGrant) async throws {
        do { try await grants.saveGrant(grant) } catch { throw CalendarFailure.keyUnavailable }
    }

    public func grant(subject: String) async throws -> GoogleGrant? {
        do { return try await grants.grant(subject: subject) } catch { throw CalendarFailure.keyUnavailable }
    }

    public func removeGrant(subject: String) async throws {
        do { try await grants.removeGrant(subject: subject) } catch { throw CalendarFailure.keyUnavailable }
    }

    public func savePassword(_ password: String, accountID: UUID) throws {
        guard !password.isEmpty, password.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CalendarFailure.invalidInput("password")
        }
        let data = Data(password.utf8)
        guard data.count <= Self.limit, access.write(Self.passwordService, accountID.uuidString, data) == errSecSuccess else {
            throw CalendarFailure.keyUnavailable
        }
    }

    public func password(accountID: UUID) throws -> String? {
        let (status, data) = access.read(Self.passwordService, accountID.uuidString)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, let value = String(data: data, encoding: .utf8) else {
            throw CalendarFailure.keyUnavailable
        }
        return value
    }

    public func removePassword(accountID: UUID) throws {
        let status = access.remove(Self.passwordService, accountID.uuidString)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CalendarFailure.keyUnavailable }
    }
}
