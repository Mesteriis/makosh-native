import Foundation

/// A JSON value as flowsint returns it in node properties and metadata.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Strings as they are; numbers and booleans rendered; nothing for arrays, objects and null.
    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }
}

public struct FlowsintInvestigation: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct FlowsintSketch: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var investigationID: String
    public init(id: String, title: String, investigationID: String) {
        self.id = id
        self.title = title
        self.investigationID = investigationID
    }
}

public struct FlowsintNode: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var label: String
    public var properties: [String: JSONValue]
    public var metadata: [String: JSONValue]
    public init(id: String, type: String, label: String, properties: [String: JSONValue] = [:], metadata: [String: JSONValue] = [:]) {
        self.id = id
        self.type = type
        self.label = label
        self.properties = properties
        self.metadata = metadata
    }
    /// The value of the type's primary field, when the type is one the module knows.
    public var primaryValue: String? {
        FlowsintNodeType(rawValue: type).flatMap { properties[$0.primaryField]?.stringValue }
    }
}

public struct FlowsintEdge: Codable, Equatable, Sendable {
    public var source: String
    public var target: String
    public var label: String
    public init(source: String, target: String, label: String) {
        self.source = source
        self.target = target
        self.label = label
    }
}

public struct FlowsintGraph: Codable, Equatable, Sendable {
    public var nodes: [FlowsintNode]
    public var edges: [FlowsintEdge]
    public init(nodes: [FlowsintNode] = [], edges: [FlowsintEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }
}

public enum FlowsintScanStatus: String, Codable, Sendable {
    case pending = "PENDING"
    case running = "RUNNING"
    case completed = "COMPLETED"
    case failed = "FAILED"
}

public struct FlowsintKey: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the module needs from a flowsint server. `FlowsintClient` speaks REST through the tunnel;
/// `FlowsintSynthetic` answers from memory for tests and QA.
public protocol FlowsintAPI: Sendable {
    func health() async throws -> Bool
    /// False when the address is already registered.
    func register(email: String, password: String) async throws -> Bool
    func login(email: String, password: String) async throws
    func investigations() async throws -> [FlowsintInvestigation]
    func createInvestigation(name: String) async throws -> FlowsintInvestigation
    func sketches(investigationID: String) async throws -> [FlowsintSketch]
    /// Nil when the server answers 404.
    func sketch(id: String) async throws -> FlowsintSketch?
    func createSketch(title: String, investigationID: String) async throws -> FlowsintSketch
    func deleteSketch(id: String) async throws
    func graph(sketchID: String) async throws -> FlowsintGraph
    /// The server's node id (Neo4j element id).
    func addNode(sketchID: String, type: FlowsintNodeType, value: String) async throws -> String
    func enrichers() async throws -> [String]
    /// The Celery task id.
    func launch(enricher: OSINTEnricher, sketchID: String, nodeIDs: [String]) async throws -> String
    func scan(id: String) async throws -> FlowsintScanStatus
    func keys() async throws -> [FlowsintKey]
    func createKey(name: String, value: String) async throws -> FlowsintKey
    func deleteKey(id: String) async throws
}
