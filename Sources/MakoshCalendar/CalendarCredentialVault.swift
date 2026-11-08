import Foundation
import MakoshCore
import Security

/// How credentials reach the Keychain: the shared Makosh item by default, memory for tests and QA.
public struct CalendarKeychainAccess: Sendable {
    public let read: @Sendable (String, String) -> (OSStatus, Data?)
    public let write: @Sendable (String, String, Data) -> OSStatus
    public let remove: @Sendable (String, String) -> OSStatus

    public init(
        read: @escaping @Sendable (String, String) -> (OSStatus, Data?), write: @escaping @Sendable (String, String, Data) -> OSStatus,
        remove: @escaping @Sendable (String, String) -> OSStatus
    ) {
        self.read = read
        self.write = write
        self.remove = remove
    }

    public static var system: Self {
        @Sendable func query(_ service: String, _ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }
        return Self(
            read: { service, account in MakoshSecretStore.shared.copyData(query(service, account)) },
            write: { service, account, data in
                let attributes: [String: Any] = [kSecValueData as String: data]
                let status = MakoshSecretStore.shared.updateItem(query(service, account), attributes)
                if status != errSecItemNotFound { return status }
                return MakoshSecretStore.shared.addItem(query(service, account).merging(attributes) { _, new in new })
            }, remove: { service, account in MakoshSecretStore.shared.deleteItem(query(service, account)) })
    }

    public static func memory() -> Self {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var items: [String: Data] = [:]
        }
        let box = Box()
        return Self(
            read: { s, a in box.lock.withLock { box.items[s + "/" + a].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) } },
            write: { s, a, data in
                box.lock.withLock { box.items[s + "/" + a] = data }
                return errSecSuccess
            },
            remove: { s, a in box.lock.withLock { box.items.removeValue(forKey: s + "/" + a) == nil ? errSecItemNotFound : errSecSuccess } }
        )
    }
}

/// Google grants are shared with the future Gmail sign-in; CalDAV passwords belong to calendar accounts.
public actor CalendarCredentialVault {
    static let grantService = "org.makosh.google.grants.v1"
    static let passwordService = "org.makosh.calendar.caldav.v1"
    private static let limit = 16 * 1024
    private let access: CalendarKeychainAccess

    public init(access: CalendarKeychainAccess = .system) { self.access = access }

    public func saveGrant(_ grant: GoogleGrant) throws {
        let data = try JSONEncoder().encode(grant)
        guard data.count <= Self.limit, access.write(Self.grantService, grant.subject, data) == errSecSuccess else {
            throw CalendarFailure.keyUnavailable
        }
    }

    public func grant(subject: String) throws -> GoogleGrant? {
        let (status, data) = access.read(Self.grantService, subject)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= Self.limit,
            let grant = try? JSONDecoder().decode(GoogleGrant.self, from: data)
        else { throw CalendarFailure.keyUnavailable }
        return grant
    }

    public func removeGrant(subject: String) throws {
        let status = access.remove(Self.grantService, subject)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CalendarFailure.keyUnavailable }
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
