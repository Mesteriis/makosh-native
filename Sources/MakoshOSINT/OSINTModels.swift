import Foundation
import MakoshCore

/// Node types of flowsint that the module sends or reads; the raw value is the upstream class name.
public enum FlowsintNodeType: String, Codable, Sendable, CaseIterable {
    case email = "Email"
    case phone = "Phone"
    case username = "Username"
    case individual = "Individual"
    case organization = "Organization"
    case socialAccount = "SocialAccount"
    case gravatar = "Gravatar"
    case breach = "Breach"
    case device = "Device"
    case domain = "Domain"

    /// The field flowsint derives the node identity from.
    public var primaryField: String {
        switch self {
        case .email: "email"
        case .phone: "number"
        case .username: "value"
        case .individual: "full_name"
        case .organization: "name"
        case .socialAccount: "id"
        case .gravatar: "hash"
        case .breach: "name"
        case .device: "device_id"
        case .domain: "domain"
        }
    }
}

/// The enrichers of the first stage; the raw value is the upstream enricher name.
public enum OSINTEnricher: String, Codable, Sendable, CaseIterable {
    case emailToGravatar = "email_to_gravatar"
    case emailToHudsonRock = "email_to_device_hudsonrock"
    case emailToBreaches = "email_to_breaches"
    case phoneToInfos = "phone_to_infos"
    case phoneToCarrier = "phone_to_carrier"
    case usernameToMaigret = "username_to_socials_maigret"
    case individualToUsernameCandidates = "individual_to_username_candidates"
    case orgToDomains = "org_to_domains"

    public var inputType: FlowsintNodeType {
        switch self {
        case .emailToGravatar, .emailToHudsonRock, .emailToBreaches: .email
        case .phoneToInfos, .phoneToCarrier: .phone
        case .usernameToMaigret: .username
        case .individualToUsernameCandidates: .individual
        case .orgToDomains: .organization
        }
    }

    /// The flowsint vault key the enricher needs, by parameter name.
    public var requiredKey: String? {
        switch self {
        case .emailToBreaches: "HIBP_API_KEY"
        case .phoneToCarrier: "VERIPHONE_API_KEY"
        case .orgToDomains: "WHOXY_API_KEY"
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .emailToGravatar: "Аватар Gravatar по адресу"
        case .emailToHudsonRock: "Заражённые устройства (HudsonRock) по адресу"
        case .emailToBreaches: "Утечки (Have I Been Pwned) по адресу"
        case .phoneToInfos: "Страна и оператор телефона"
        case .phoneToCarrier: "Оператор и тип номера (Veriphone)"
        case .usernameToMaigret: "Аккаунты в соцсетях по username (Maigret)"
        case .individualToUsernameCandidates: "Кандидаты username по имени"
        case .orgToDomains: "Домены организации (Whoxy)"
        }
    }

    /// Node types the enricher produces: what a graph read looks for to settle an unknown launch.
    public var outputTypes: Set<FlowsintNodeType> {
        switch self {
        case .emailToGravatar: [.gravatar]
        case .emailToHudsonRock: [.device]
        case .emailToBreaches: [.breach]
        case .phoneToInfos, .phoneToCarrier: [.phone]
        case .usernameToMaigret: [.socialAccount]
        case .individualToUsernameCandidates: [.username]
        case .orgToDomains: [.domain]
        }
    }

    public var isSlow: Bool { self == .usernameToMaigret }

    /// Everything that needs no key.
    public static let manualDefault: Set<OSINTEnricher> = Set(allCases.filter { $0.requiredKey == nil })
    /// Free and quick: what a flagged book may run without asking.
    public static let automaticDefault: Set<OSINTEnricher> = [
        .emailToGravatar, .emailToHudsonRock, .phoneToInfos, .individualToUsernameCandidates,
    ]
    public static let knownKeys = ["HIBP_API_KEY", "VERIPHONE_API_KEY", "WHOXY_API_KEY"]
}

/// Non-secret settings of the module; secrets live in the Keychain.
public struct OSINTSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var host = ""
    public var port = 22
    public var login = ""
    /// `SHA256:<base64>` of the server host key the user trusted; nil until the first check.
    public var hostKeyFingerprint: String?
    /// Identifies this server in identities `osint/<serverID>/<sketch>`.
    public var serverID: UUID
    public var serviceEmail = "makosh-osint@sh-inc.dev"
    public var investigationID: String?
    public var installedTag: String?
    public var installedSHA: String?
    public var installedAt: Date?
    public var imageIDs: [String: String] = [:]
    /// False when `.env` existed before this Makosh and its secrets are not in the Keychain.
    public var envBackupAvailable = true
    public var manualEnrichers = OSINTEnricher.manualDefault
    public var automaticEnrichers = OSINTEnricher.automaticDefault
    public var automaticRunsPerHour = 20
    public var hmacKeyAvailable = true

    public init(serverID: UUID = UUID()) { self.serverID = serverID }
}

public enum OSINTRunTrigger: Codable, Equatable, Sendable {
    case manual
    case book(ImportSource)

    public var key: String {
        switch self {
        case .manual: "manual"
        case .book(let source): "book:\(source.service)/\(source.accountID)"
        }
    }
    public var isAutomatic: Bool {
        if case .book = self { return true }
        return false
    }
}

public enum OSINTRunState: String, Codable, Sendable {
    case queued, running, completed, failed, unknown
    public var isOpen: Bool { self == .queued || self == .running || self == .unknown }
}

/// One enrichment of one person: the inputs stay in memory, the row keeps only counts.
public struct OSINTRun: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var personID: UUID
    public var trigger: OSINTRunTrigger
    public var enrichers: Set<OSINTEnricher>
    public var state: OSINTRunState
    public var failure: OSINTFailure?
    public var found = 0
    public var truncated = false
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(), personID: UUID, trigger: OSINTRunTrigger, enrichers: Set<OSINTEnricher>, state: OSINTRunState = .queued,
        failure: OSINTFailure? = nil, found: Int = 0, truncated: Bool = false, createdAt: Date = Date(), startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.personID = personID
        self.trigger = trigger
        self.enrichers = enrichers
        self.state = state
        self.failure = failure
        self.found = found
        self.truncated = truncated
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public enum OSINTAttemptKind: String, Codable, Sendable { case createSketch, addNode, launch, createKey, deleteKey, deleteSketch }

public enum OSINTAttemptState: String, Codable, Sendable {
    case queued, sent, confirmed, rejected, unknown
    public var isOpen: Bool { self == .queued || self == .sent || self == .unknown }
}

/// What a check needs to find the write again. Values appear only as a keyed HMAC.
public struct OSINTAttemptPayload: Codable, Equatable, Sendable {
    public var sketchID: String?
    public var nodeType: FlowsintNodeType?
    public var valueHMAC: String?
    public var enricher: OSINTEnricher?
    public var inputNodeID: String?
    public var keyName: String?

    public init(
        sketchID: String? = nil, nodeType: FlowsintNodeType? = nil, valueHMAC: String? = nil, enricher: OSINTEnricher? = nil,
        inputNodeID: String? = nil, keyName: String? = nil
    ) {
        self.sketchID = sketchID
        self.nodeType = nodeType
        self.valueHMAC = valueHMAC
        self.enricher = enricher
        self.inputNodeID = inputNodeID
        self.keyName = keyName
    }
}

public struct OSINTAttemptResponse: Codable, Equatable, Sendable {
    public var sketchID: String?
    public var nodeID: String?
    public var scanID: String?
    public var keyID: String?

    public init(sketchID: String? = nil, nodeID: String? = nil, scanID: String? = nil, keyID: String? = nil) {
        self.sketchID = sketchID
        self.nodeID = nodeID
        self.scanID = scanID
        self.keyID = keyID
    }
}

/// One write to the flowsint server. An `unknown` outcome is never retried by itself:
/// a read settles it, or the user dismisses it.
public struct OSINTAttempt: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var runID: UUID?
    public var personID: UUID?
    public var kind: OSINTAttemptKind
    public var state: OSINTAttemptState
    public var payload: OSINTAttemptPayload
    public var response: OSINTAttemptResponse?
    public var failure: OSINTFailure?
    public var createdAt: Date
    public var updatedAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(), runID: UUID? = nil, personID: UUID? = nil, kind: OSINTAttemptKind, state: OSINTAttemptState = .queued,
        payload: OSINTAttemptPayload, response: OSINTAttemptResponse? = nil, failure: OSINTFailure? = nil, createdAt: Date = Date(),
        updatedAt: Date? = nil, resolvedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.personID = personID
        self.kind = kind
        self.state = state
        self.payload = payload
        self.response = response
        self.failure = failure
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.resolvedAt = resolvedAt
    }

    public static func allows(_ from: OSINTAttemptState, _ to: OSINTAttemptState) -> Bool {
        switch (from, to) {
        case (.queued, .sent), (.queued, .rejected): true
        case (.sent, .confirmed), (.sent, .rejected), (.sent, .unknown): true
        case (.unknown, .confirmed), (.unknown, .rejected): true
        default: false
        }
    }
}

public enum OSINTInstallStepKind: String, Codable, Sendable, CaseIterable {
    case connect, docker, checkout, env, override, build, up, register, investigation, record
}

public enum OSINTInstallStepState: String, Codable, Sendable { case pending, running, done, skipped, failed }

public struct OSINTInstallStep: Codable, Equatable, Sendable {
    public var kind: OSINTInstallStepKind
    public var state: OSINTInstallStepState
    /// Progress text without secrets, for the interface.
    public var message: String?
    public var failure: OSINTFailure?
    public var finishedAt: Date?

    public init(
        kind: OSINTInstallStepKind, state: OSINTInstallStepState = .pending, message: String? = nil, failure: OSINTFailure? = nil,
        finishedAt: Date? = nil
    ) {
        self.kind = kind
        self.state = state
        self.message = message
        self.failure = failure
        self.finishedAt = finishedAt
    }
}

public enum OSINTInstallState: String, Codable, Sendable { case running, completed, failed }

/// One installer run: the steps it took and where it stopped.
public struct OSINTInstall: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var state: OSINTInstallState
    public var targetTag: String
    public var targetSHA: String
    public var steps: [OSINTInstallStep]
    public var createdAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(), state: OSINTInstallState = .running, targetTag: String, targetSHA: String, steps: [OSINTInstallStep] = [],
        createdAt: Date = Date(), finishedAt: Date? = nil
    ) {
        self.id = id
        self.state = state
        self.targetTag = targetTag
        self.targetSHA = targetSHA
        self.steps = steps
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
}

/// The sketch flowsint holds for one person; a deleted sketch keeps its row with `deletedAt`.
public struct OSINTSketchLink: Codable, Equatable, Sendable {
    public var personID: UUID
    public var sketchID: String
    public var createdAt: Date
    public var deletedAt: Date?

    public init(personID: UUID, sketchID: String, createdAt: Date = Date(), deletedAt: Date? = nil) {
        self.personID = personID
        self.sketchID = sketchID
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}
