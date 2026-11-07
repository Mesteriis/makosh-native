import Foundation
import MakoshCore

/// The local status cycle, in cycle order.
public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case inbox
    case active
    case done
    case cancelled
}

/// Why a provider's issue is in «Мои»: assigned, mentioned, kept by the
/// user after it left the provider's selection, or not shown there at all.
public enum TaskMembership: String, Codable, Sendable {
    case assigned
    case mentioned
    case kept
    case none
}

/// A provider identity (service, connection, external id) with its membership.
public struct TaskSource: Codable, Hashable, Sendable {
    public var identity: ServiceIdentity
    public var membership: TaskMembership
    public init(identity: ServiceIdentity, membership: TaskMembership) {
        self.identity = identity
        self.membership = membership
    }
}

/// A local task; a provider's issue carries one as well, with its local layer here.
public struct Task: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let code: String
    public var title: String
    public var status: TaskStatus
    /// 1 is the highest; 4 means no priority.
    public var priority: Int
    public var list: String?
    public var tags: [String]
    public var due: Date?
    public var start: Date?
    public var estimateMinutes: Int?
    public var url: URL?
    public var postponed: Int
    public var dependsOn: [UUID]
    public var notes: String
    public var source: TaskSource?
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var deletedAt: Date?
    public var revision: Int64

    public init(
        id: UUID = UUID(), code: String? = nil, title: String, status: TaskStatus = .inbox, priority: Int = 4, list: String? = nil,
        tags: [String] = [], due: Date? = nil, start: Date? = nil, estimateMinutes: Int? = nil, url: URL? = nil, postponed: Int = 0,
        dependsOn: [UUID] = [], notes: String = "", source: TaskSource? = nil, createdAt: Date = Date(), updatedAt: Date? = nil,
        completedAt: Date? = nil, deletedAt: Date? = nil, revision: Int64 = 0
    ) {
        self.id = id
        self.code = code ?? TaskCode.make(from: id)
        self.title = title
        self.status = status
        self.priority = priority
        self.list = list
        self.tags = tags
        self.due = due
        self.start = start
        self.estimateMinutes = estimateMinutes
        self.url = url
        self.postponed = postponed
        self.dependsOn = dependsOn
        self.notes = notes
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.deletedAt = deletedAt
        self.revision = revision
    }
}

extension Task {
    /// The same task with a new code or creation time; both are `let` so the
    /// store builds a copy rather than mutating them.
    func replacing(code: String? = nil, createdAt: Date? = nil) -> Task {
        Task(
            id: id, code: code ?? self.code, title: title, status: status, priority: priority, list: list, tags: tags, due: due,
            start: start, estimateMinutes: estimateMinutes, url: url, postponed: postponed, dependsOn: dependsOn, notes: notes,
            source: source, createdAt: createdAt ?? self.createdAt, updatedAt: updatedAt, completedAt: completedAt, deletedAt: deletedAt,
            revision: revision)
    }
}

/// Short codes like `7K3MZ`: five Crockford Base32 characters from the id's leading bits.
public enum TaskCode {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func make(from id: UUID) -> String {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0.prefix(4)) }
        var bits = UInt32(0)
        for byte in bytes { bits = bits << 8 | UInt32(byte) }
        var code = ""
        for index in 0..<5 {
            let shift = 32 - 5 * (index + 1)
            code.append(alphabet[Int((bits >> UInt32(shift)) & 0x1F)])
        }
        return code
    }
}
