import Foundation

/// A flowsint server in memory for tests and QA: sketches, a graph per sketch, tasks that
/// complete on their first status read and append scripted findings, keys stored by name only.
public actor FlowsintSynthetic: FlowsintAPI {
    /// What an enricher "finds" for one input value.
    public struct Finding: Equatable, Sendable {
        public var enricher: OSINTEnricher
        public var inputType: FlowsintNodeType
        public var inputValue: String
        public var outputType: FlowsintNodeType
        public var outputValue: String
        public var properties: [String: JSONValue]
        public var edgeLabel: String
        public init(
            enricher: OSINTEnricher, inputType: FlowsintNodeType, inputValue: String, outputType: FlowsintNodeType, outputValue: String,
            properties: [String: JSONValue] = [:], edgeLabel: String = "IS_RELATED_TO"
        ) {
            self.enricher = enricher
            self.inputType = inputType
            self.inputValue = inputValue
            self.outputType = outputType
            self.outputValue = outputValue
            self.properties = properties
            self.edgeLabel = edgeLabel
        }
    }

    public struct LaunchRecord: Equatable, Sendable {
        public var enricher: OSINTEnricher
        public var sketchID: String
        public var nodeIDs: [String]
    }

    private struct Task {
        var sketchID: String
        var enricher: OSINTEnricher
        var nodeIDs: [String]
        var status: FlowsintScanStatus
    }

    private let findings: [Finding]
    public private(set) var isInstalled: Bool
    private var accounts: [String: String] = [:]
    private var investigationList: [FlowsintInvestigation] = []
    private var sketchMap: [String: FlowsintSketch] = [:]
    private var graphs: [String: FlowsintGraph] = [:]
    private var tasks: [String: Task] = [:]
    private var hung: Set<String> = []
    private var keyList: [FlowsintKey] = []
    private var armed: [String: OSINTFailure] = [:]
    public private(set) var recordedLaunches: [LaunchRecord] = []
    private var counter = 0

    public init(findings: [Finding] = [], installed: Bool = true) {
        self.findings = findings
        isInstalled = installed
    }

    // MARK: Test controls

    public func setInstalled(_ value: Bool) { isInstalled = value }

    /// The next call of `stage` throws `failure`; the write still applies when the failure is an unknown outcome.
    public func failNext(_ failure: OSINTFailure, stage: String) { armed[stage] = failure }

    /// The task never completes: every status read says running.
    public func hangScan(id: String) { hung.insert(id) }

    public var users: [String] { accounts.keys.sorted() }

    // MARK: FlowsintAPI

    public func health() async throws -> Bool {
        try arm("health", applies: { false })
        return isInstalled
    }

    public func register(email: String, password: String) async throws -> Bool {
        try arm("register") {
            if accounts[email] != nil { return false }
            accounts[email] = password
            return true
        }
    }

    public func login(email: String, password: String) async throws {
        try arm("token") {
            guard accounts[email] == password else { throw OSINTFailure.serviceAuthFailed }
        }
    }

    public func investigations() async throws -> [FlowsintInvestigation] { try arm("investigations") { investigationList } }

    public func createInvestigation(name: String) async throws -> FlowsintInvestigation {
        try arm("createInvestigation") {
            let value = FlowsintInvestigation(id: nextID("inv"), name: name)
            investigationList.append(value)
            return value
        }
    }

    public func sketches(investigationID: String) async throws -> [FlowsintSketch] {
        try arm("sketches") { sketchMap.values.filter { $0.investigationID == investigationID }.sorted { $0.id < $1.id } }
    }

    public func sketch(id: String) async throws -> FlowsintSketch? { try arm("sketch") { sketchMap[id] } }

    public func createSketch(title: String, investigationID: String) async throws -> FlowsintSketch {
        try arm("createSketch") {
            let value = FlowsintSketch(id: nextID("sk"), title: title, investigationID: investigationID)
            sketchMap[value.id] = value
            graphs[value.id] = FlowsintGraph()
            return value
        }
    }

    public func deleteSketch(id: String) async throws {
        try arm("deleteSketch") {
            sketchMap[id] = nil
            graphs[id] = nil
        }
    }

    public func graph(sketchID: String) async throws -> FlowsintGraph {
        try arm("graph") {
            guard let graph = graphs[sketchID] else { throw OSINTFailure.apiRejected(code: 404, stage: "graph") }
            return graph
        }
    }

    public func addNode(sketchID: String, type: FlowsintNodeType, value: String) async throws -> String {
        try arm("addNode") {
            guard graphs[sketchID] != nil else { throw OSINTFailure.apiRejected(code: 404, stage: "addNode") }
            return merge(
                FlowsintNode(id: "", type: type.rawValue, label: value, properties: [type.primaryField: .string(value)]), into: sketchID)
        }
    }

    public func enrichers() async throws -> [String] { try arm("enrichers") { OSINTEnricher.allCases.map(\.rawValue) } }

    public func launch(enricher: OSINTEnricher, sketchID: String, nodeIDs: [String]) async throws -> String {
        try arm("launch") {
            guard graphs[sketchID] != nil else { throw OSINTFailure.apiRejected(code: 404, stage: "launch") }
            let id = nextID("task")
            tasks[id] = Task(sketchID: sketchID, enricher: enricher, nodeIDs: nodeIDs, status: .pending)
            recordedLaunches.append(LaunchRecord(enricher: enricher, sketchID: sketchID, nodeIDs: nodeIDs))
            return id
        }
    }

    public func scan(id: String) async throws -> FlowsintScanStatus {
        try arm("scan") {
            guard var task = tasks[id] else { throw OSINTFailure.apiRejected(code: 404, stage: "scan") }
            if hung.contains(id) { return .running }
            if task.status != .completed {
                apply(task)
                task.status = .completed
                tasks[id] = task
            }
            return task.status
        }
    }

    public func keys() async throws -> [FlowsintKey] { try arm("keys") { keyList } }

    public func createKey(name: String, value: String) async throws -> FlowsintKey {
        try arm("createKey") {
            guard !value.isEmpty else { throw OSINTFailure.apiRejected(code: 422, stage: "createKey") }
            let key = FlowsintKey(id: nextID("key"), name: name)
            keyList.append(key)
            return key
        }
    }

    public func deleteKey(id: String) async throws { try arm("deleteKey") { keyList.removeAll { $0.id == id } } }

    // MARK: Plumbing

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    /// Runs the write, then throws an armed failure. A rejection fires before the write.
    private func arm<T>(_ stage: String, applies body: () throws -> T) throws -> T {
        guard let failure = armed.removeValue(forKey: stage) else { return try body() }
        if case .unknownOutcome = failure {
            _ = try body()
        }
        throw failure
    }

    private static func key(_ node: FlowsintNode) -> String {
        "\(node.type)|\((node.primaryValue ?? node.label).trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    /// Adds the node or returns the id of the node with the same type and primary value.
    private func merge(_ node: FlowsintNode, into sketchID: String) -> String {
        var graph = graphs[sketchID] ?? FlowsintGraph()
        let key = Self.key(node)
        if let existing = graph.nodes.first(where: { Self.key($0) == key }) { return existing.id }
        var stored = node
        stored.id = nextID("n")
        graph.nodes.append(stored)
        graphs[sketchID] = graph
        return stored.id
    }

    private func apply(_ task: Task) {
        guard var graph = graphs[task.sketchID] else { return }
        for inputID in task.nodeIDs {
            guard let input = graph.nodes.first(where: { $0.id == inputID }) else { continue }
            let inputValue = (input.primaryValue ?? input.label).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for finding in findings
            where finding.enricher == task.enricher && finding.inputType.rawValue == input.type
                && finding.inputValue.lowercased() == inputValue
            {
                var properties = finding.properties
                properties[finding.outputType.primaryField] = .string(finding.outputValue)
                let output = FlowsintNode(
                    id: "", type: finding.outputType.rawValue, label: finding.outputValue, properties: properties,
                    metadata: ["enricher": .string(task.enricher.rawValue)])
                graphs[task.sketchID] = graph
                let outputID = merge(output, into: task.sketchID)
                graph = graphs[task.sketchID] ?? graph
                let edge = FlowsintEdge(source: inputID, target: outputID, label: finding.edgeLabel)
                if !graph.edges.contains(edge) { graph.edges.append(edge) }
            }
        }
        graphs[task.sketchID] = graph
    }
}
