import Foundation
import MakoshGoogle

/// REST client for flowsint behind the SSH tunnel. Failures carry a status code and a stage
/// name only: never the body, the URL or the token. A stale token is renewed once.
public final class FlowsintClient: FlowsintAPI, Sendable {
    public typealias Credentials = @Sendable () async throws -> (email: String, password: String)?

    private let baseURL: URL
    private let http: ServiceHTTP
    private let credentials: Credentials
    private let token = TokenBox()

    public init(baseURL: URL, http: ServiceHTTP = ServiceHTTP(), credentials: @escaping Credentials) {
        self.baseURL = baseURL
        self.http = http
        self.credentials = credentials
    }

    // MARK: FlowsintAPI

    public func health() async throws -> Bool {
        let (data, response) = try await perform(.get, "/health", stage: "health", authorized: false)
        guard response.statusCode == 200 else { return false }
        return (try? Self.decode([String: JSONValue].self, data, stage: "health"))?["status"]?.stringValue == "ok"
    }

    public func register(email: String, password: String) async throws -> Bool {
        let (_, response) = try await perform(
            .post, "/api/auth/register", json: ["email": .string(email), "password": .string(password)], stage: "register",
            authorized: false, accepting: [400, 409])
        return response.statusCode == 201 || response.statusCode == 200
    }

    public func login(email: String, password: String) async throws {
        try await obtainToken(email: email, password: password)
    }

    public func investigations() async throws -> [FlowsintInvestigation] {
        let (data, _) = try await perform(.get, "/api/investigations", stage: "investigations")
        return try Self.decode([Wire.Investigation].self, data, stage: "investigations").map(\.value)
    }

    public func createInvestigation(name: String) async throws -> FlowsintInvestigation {
        let (data, _) = try await perform(
            .post, "/api/investigations/create", json: ["name": .string(name), "description": .string("Makosh")],
            stage: "createInvestigation")
        return try Self.decode(Wire.Investigation.self, data, stage: "createInvestigation").value
    }

    public func sketches(investigationID: String) async throws -> [FlowsintSketch] {
        let (data, _) = try await perform(.get, "/api/investigations/\(investigationID)/sketches", stage: "sketches")
        return try Self.decode([Wire.Sketch].self, data, stage: "sketches").map(\.value)
    }

    public func sketch(id: String) async throws -> FlowsintSketch? {
        let (data, response) = try await perform(.get, "/api/sketches/\(id)", stage: "sketch", accepting: [404])
        if response.statusCode == 404 { return nil }
        return try Self.decode(Wire.Sketch.self, data, stage: "sketch").value
    }

    public func createSketch(title: String, investigationID: String) async throws -> FlowsintSketch {
        let (data, _) = try await perform(
            .post, "/api/sketches/create",
            json: ["title": .string(title), "description": .string("Makosh"), "investigation_id": .string(investigationID)],
            stage: "createSketch")
        return try Self.decode(Wire.Sketch.self, data, stage: "createSketch").value
    }

    public func deleteSketch(id: String) async throws {
        _ = try await perform(.delete, "/api/sketches/\(id)", stage: "deleteSketch", accepting: [404])
    }

    public func graph(sketchID: String) async throws -> FlowsintGraph {
        let (data, _) = try await perform(.get, "/api/sketches/\(sketchID)/graph", stage: "graph")
        let wire = try Self.decode(Wire.Graph.self, data, stage: "graph")
        return FlowsintGraph(nodes: wire.nodes.map(\.value), edges: wire.edges.map(\.value))
    }

    public func addNode(sketchID: String, type: FlowsintNodeType, value: String) async throws -> String {
        let node: [String: JSONValue] = [
            "id": .string(""), "nodeType": .string(type.rawValue), "nodeLabel": .string(value),
            "nodeProperties": .object([type.primaryField: .string(value)]), "nodeSize": .number(1), "nodeColor": .null,
            "nodeIcon": .null, "nodeImage": .null, "nodeFlag": .null, "nodeShape": .null, "nodeMetadata": .object([:]),
            "x": .number(0), "y": .number(0),
        ]
        let (data, _) = try await perform(.post, "/api/sketches/\(sketchID)/nodes/add", json: node, stage: "addNode")
        let reply = try Self.decode([String: JSONValue].self, data, stage: "addNode")
        guard let id = (reply["id"] ?? reply["node_id"] ?? reply["elementId"])?.stringValue, !id.isEmpty else {
            throw OSINTFailure.invalidResponse(stage: "addNode")
        }
        return id
    }

    public func enrichers() async throws -> [String] {
        let (data, _) = try await perform(.get, "/api/enrichers", stage: "enrichers")
        return try Self.decode([[String: JSONValue]].self, data, stage: "enrichers").compactMap { $0["name"]?.stringValue }
    }

    public func launch(enricher: OSINTEnricher, sketchID: String, nodeIDs: [String]) async throws -> String {
        let (data, _) = try await perform(
            .post, "/api/enrichers/\(enricher.rawValue)/launch",
            json: ["node_ids": .array(nodeIDs.map(JSONValue.string)), "sketch_id": .string(sketchID), "params": .object([:])],
            stage: "launch")
        guard let id = try Self.decode([String: JSONValue].self, data, stage: "launch")["id"]?.stringValue, !id.isEmpty else {
            throw OSINTFailure.invalidResponse(stage: "launch")
        }
        return id
    }

    public func scan(id: String) async throws -> FlowsintScanStatus {
        let (data, _) = try await perform(.get, "/api/scans/\(id)", stage: "scan")
        guard let text = try Self.decode([String: JSONValue].self, data, stage: "scan")["status"]?.stringValue,
            let status = FlowsintScanStatus(rawValue: text.uppercased())
        else { throw OSINTFailure.invalidResponse(stage: "scan") }
        return status
    }

    public func keys() async throws -> [FlowsintKey] {
        let (data, _) = try await perform(.get, "/api/keys", stage: "keys")
        return try Self.decode([FlowsintKey].self, data, stage: "keys")
    }

    public func createKey(name: String, value: String) async throws -> FlowsintKey {
        let (data, _) = try await perform(
            .post, "/api/keys/create", json: ["name": .string(name), "key": .string(value)], stage: "createKey")
        return try Self.decode(FlowsintKey.self, data, stage: "createKey")
    }

    public func deleteKey(id: String) async throws {
        _ = try await perform(.delete, "/api/keys/\(id)", stage: "deleteKey", accepting: [404])
    }

    // MARK: Transport

    private enum Method: String { case get = "GET", post = "POST", delete = "DELETE" }

    private func perform(
        _ method: Method, _ path: String, json: [String: JSONValue]? = nil, stage: String, authorized: Bool = true, accepting: Set<Int> = []
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(json)
        }
        var renewed = false
        while true {
            if authorized {
                let bearer: String
                if let current = await token.current() { bearer = current } else { bearer = try await obtainToken() }
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await raw(request, stage: stage)
            if response.statusCode == 401, authorized {
                guard !renewed else { throw OSINTFailure.serviceAuthFailed }
                renewed = true
                await token.clear()
                continue
            }
            try Self.check(response.statusCode, stage: stage, accepting: accepting)
            return (data, response)
        }
    }

    private func raw(_ request: URLRequest, stage: String) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http.raw(request, stage: stage, limit: 10 << 20)
        } catch ServiceHTTPError.responseTooLarge {
            throw OSINTFailure.tooLarge
        } catch {
            throw OSINTFailure.unknownOutcome(stage: stage)
        }
    }

    private static func check(_ status: Int, stage: String, accepting: Set<Int>) throws {
        switch status {
        case 200..<300: return
        case _ where accepting.contains(status): return
        case 408, 429, 500...: throw OSINTFailure.unknownOutcome(stage: stage)
        default: throw OSINTFailure.apiRejected(code: status, stage: stage)
        }
    }

    @discardableResult
    private func obtainToken(email: String? = nil, password: String? = nil) async throws -> String {
        let pair: (email: String, password: String)
        if let email, let password {
            pair = (email, password)
        } else {
            guard let stored = try await credentials() else { throw OSINTFailure.serviceAuthFailed }
            pair = stored
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data("username=\(Self.formEncode(pair.email))&password=\(Self.formEncode(pair.password))".utf8)
        let (data, response) = try await raw(request, stage: "token")
        switch response.statusCode {
        case 200..<300: break
        case 400, 401, 403: throw OSINTFailure.serviceAuthFailed
        default: try Self.check(response.statusCode, stage: "token", accepting: [])
        }
        guard let value = try Self.decode([String: JSONValue].self, data, stage: "token")["access_token"]?.stringValue, !value.isEmpty
        else {
            throw OSINTFailure.invalidResponse(stage: "token")
        }
        await token.set(value)
        return value
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data, stage: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw OSINTFailure.invalidResponse(stage: stage) }
    }

    private actor TokenBox {
        private var value: String?
        func current() -> String? { value }
        func set(_ token: String) { value = token }
        func clear() { value = nil }
    }

    /// Wire shapes of flowsint answers, lenient about the field names the frontend has used over time.
    private enum Wire {
        struct Investigation: Decodable {
            var id: String
            var name: String?
            var title: String?
            var value: FlowsintInvestigation { FlowsintInvestigation(id: id, name: name ?? title ?? "") }
        }
        struct Sketch: Decodable {
            var id: String
            var title: String?
            var investigation_id: String?
            var value: FlowsintSketch { FlowsintSketch(id: id, title: title ?? "", investigationID: investigation_id ?? "") }
        }
        struct Node: Decodable {
            var id: String
            var nodeType: String?
            var type: String?
            var nodeLabel: String?
            var label: String?
            var nodeProperties: [String: JSONValue]?
            var properties: [String: JSONValue]?
            var nodeMetadata: [String: JSONValue]?
            var metadata: [String: JSONValue]?
            var value: FlowsintNode {
                FlowsintNode(
                    id: id, type: nodeType ?? type ?? "", label: nodeLabel ?? label ?? "", properties: nodeProperties ?? properties ?? [:],
                    metadata: nodeMetadata ?? metadata ?? [:])
            }
        }
        struct Edge: Decodable {
            var source: String
            var target: String
            var label: String?
            var type: String?
            var value: FlowsintEdge { FlowsintEdge(source: source, target: target, label: label ?? type ?? "IS_RELATED_TO") }
        }
        struct Graph: Decodable {
            var nodes: [Node]
            var edges: [Edge]
        }
    }
}
