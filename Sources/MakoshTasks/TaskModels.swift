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

/// One note of a task, as in the reference: its own id and creation time.
public struct TaskNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var content: String
    public let createdAt: Date
    public init(id: UUID = UUID(), content: String, createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
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
    public var personas: [String]
    public var due: Date?
    public var start: Date?
    public var estimateMinutes: Int?
    public var url: URL?
    public var postponed: Int
    public var dependsOn: [UUID]
    /// `daily`, `weekly`, `biweekly`, `monthly`, `yearly` or an RRULE body; see `TaskRecurrence`.
    public var recurrence: String?
    /// The named flow this task belongs to.
    public var flowID: String?
    public var notes: [TaskNote]
    public var source: TaskSource?
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var deletedAt: Date?
    public var revision: Int64

    public init(
        id: UUID = UUID(), code: String? = nil, title: String, status: TaskStatus = .inbox, priority: Int = 4, list: String? = nil,
        tags: [String] = [], personas: [String] = [], due: Date? = nil, start: Date? = nil, estimateMinutes: Int? = nil, url: URL? = nil,
        postponed: Int = 0, dependsOn: [UUID] = [], recurrence: String? = nil, flowID: String? = nil, notes: [TaskNote] = [],
        source: TaskSource? = nil, createdAt: Date = Date(), updatedAt: Date? = nil, completedAt: Date? = nil, deletedAt: Date? = nil,
        revision: Int64 = 0
    ) {
        self.id = id
        self.code = code ?? TaskCode.make(from: id)
        self.title = title
        self.status = status
        self.priority = priority
        self.list = list
        self.tags = tags
        self.personas = personas
        self.due = due
        self.start = start
        self.estimateMinutes = estimateMinutes
        self.url = url
        self.postponed = postponed
        self.dependsOn = dependsOn
        self.recurrence = recurrence
        self.flowID = flowID
        self.notes = notes
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.deletedAt = deletedAt
        self.revision = revision
    }

    /// Rows written by the first part carry `notes` as one string and none of
    /// the newer fields; they read as one note and the defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        code = try c.decode(String.self, forKey: .code)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(TaskStatus.self, forKey: .status)
        priority = try c.decode(Int.self, forKey: .priority)
        list = try c.decodeIfPresent(String.self, forKey: .list)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        personas = try c.decodeIfPresent([String].self, forKey: .personas) ?? []
        due = try c.decodeIfPresent(Date.self, forKey: .due)
        start = try c.decodeIfPresent(Date.self, forKey: .start)
        estimateMinutes = try c.decodeIfPresent(Int.self, forKey: .estimateMinutes)
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        postponed = try c.decodeIfPresent(Int.self, forKey: .postponed) ?? 0
        dependsOn = try c.decodeIfPresent([UUID].self, forKey: .dependsOn) ?? []
        recurrence = try c.decodeIfPresent(String.self, forKey: .recurrence)
        flowID = try c.decodeIfPresent(String.self, forKey: .flowID)
        source = try c.decodeIfPresent(TaskSource.self, forKey: .source)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        revision = try c.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        if let list = try? c.decodeIfPresent([TaskNote].self, forKey: .notes) {
            notes = list
        } else if let text = try c.decodeIfPresent(String.self, forKey: .notes), !text.isEmpty {
            notes = [TaskNote(id: TaskNote.legacyID(for: id), content: text, createdAt: createdAt)]
        } else {
            notes = []
        }
    }

    /// Every note as one text, paragraphs apart; for display, search and the AI card.
    public var notesText: String { notes.map(\.content).joined(separator: "\n\n") }
}

extension TaskNote {
    /// A legacy notes string gets a stable id derived from its task, so two reads agree.
    static func legacyID(for taskID: UUID) -> UUID {
        var bytes = taskID.uuid
        bytes.0 ^= 0x5A
        bytes.15 ^= 0xA5
        return UUID(uuid: bytes)
    }
}

extension Task {
    /// The same task with a new code or creation time; both are `let` so the
    /// store builds a copy rather than mutating them.
    func replacing(code: String? = nil, createdAt: Date? = nil) -> Task {
        Task(
            id: id, code: code ?? self.code, title: title, status: status, priority: priority, list: list, tags: tags, personas: personas,
            due: due, start: start, estimateMinutes: estimateMinutes, url: url, postponed: postponed, dependsOn: dependsOn,
            recurrence: recurrence, flowID: flowID, notes: notes, source: source, createdAt: createdAt ?? self.createdAt,
            updatedAt: updatedAt, completedAt: completedAt, deletedAt: deletedAt, revision: revision)
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
