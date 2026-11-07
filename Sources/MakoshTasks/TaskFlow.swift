import CoreGraphics
import Foundation

/// A named flow's card: description, colour and deadline. The flow itself is
/// the set of tasks naming it; the card may outlive them.
public struct TaskFlow: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var description: String
    public var color: String?
    public var deadline: Date?
    public var id: String { name }

    public init(name: String, description: String = "", color: String? = nil, deadline: Date? = nil) {
        self.name = name
        self.description = description
        self.color = color
        self.deadline = deadline
    }

    /// The reference's ten choices; the last is «no colour».
    public static let palette = [
        "#f472b6", "#fb923c", "#60a5fa", "#34d399", "#a78bfa", "#f87171", "#fbbf24", "#2dd4bf", "#e879f9", "",
    ]
    public static let defaultColor = "#f472b6"
}

public struct TaskFlowProgress: Equatable, Sendable {
    public let total: Int
    public let done: Int
    public var percent: Int { total > 0 ? Int((Double(done) / Double(total) * 100).rounded()) : 0 }
}

public enum TaskFlowRules {
    public static func progress(_ tasks: [Task]) -> TaskFlowProgress {
        TaskFlowProgress(total: tasks.count, done: tasks.filter { $0.status == .done }.count)
    }

    /// An inbox task whose blockers are all closed: the one «Запустить следующую» starts.
    public static func isReady(_ task: Task, resolve: (UUID) -> Task?) -> Bool {
        task.status == .inbox && task.deletedAt == nil && !TaskDomain.isBlocked(task, resolve: resolve)
    }

    public static func nextReady(_ tasks: [Task], resolve: (UUID) -> Task?) -> Task? {
        tasks.first { isReady($0, resolve: resolve) }
    }
}

/// Positions for the flow graph: ranks by the longest path from the sources,
/// left to right; within a rank, by the parents' average position, then title.
public struct TaskFlowLayout: Equatable, Sendable {
    public struct Node: Equatable, Sendable {
        public let id: UUID
        public let x: CGFloat
        public let y: CGFloat
    }
    public struct Edge: Equatable, Sendable {
        public let from: UUID
        public let to: UUID
    }

    public let nodes: [Node]
    public let edges: [Edge]
    public let size: CGSize

    public static func make(
        _ tasks: [Task], nodeSize: CGSize = CGSize(width: 200, height: 76), gap: CGSize = CGSize(width: 80, height: 20)
    ) -> TaskFlowLayout {
        guard !tasks.isEmpty else { return TaskFlowLayout(nodes: [], edges: [], size: .zero) }
        let ids = Set(tasks.map(\.id))
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parents: [UUID: [UUID]] = [:]
        var children: [UUID: [UUID]] = [:]
        var edges: [Edge] = []
        for task in tasks {
            for dependency in task.dependsOn where ids.contains(dependency) {
                parents[task.id, default: []].append(dependency)
                children[dependency, default: []].append(task.id)
                edges.append(Edge(from: dependency, to: task.id))
            }
        }
        // Longest path from the sources (Kahn's order); a cycle, which the domain forbids, leaves rank 0.
        var remaining = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, parents[$0.id]?.count ?? 0) })
        var rank: [UUID: Int] = [:]
        var queue = tasks.filter { remaining[$0.id] == 0 }.map(\.id)
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let own = rank[current] ?? 0
            for child in children[current] ?? [] {
                rank[child] = max(rank[child] ?? 0, own + 1)
                remaining[child, default: 0] -= 1
                if remaining[child] == 0 { queue.append(child) }
            }
        }
        let maxRank = rank.values.max() ?? 0
        var columns: [[UUID]] = Array(repeating: [], count: maxRank + 1)
        for task in tasks { columns[rank[task.id] ?? 0].append(task.id) }
        var y: [UUID: CGFloat] = [:]
        var nodes: [Node] = []
        var height: CGFloat = 0
        for (index, column) in columns.enumerated() {
            let ordered = column.sorted { lhs, rhs in
                let l = barycenter(lhs, parents: parents, y: y), r = barycenter(rhs, parents: parents, y: y)
                if l != r { return l < r }
                return (byID[lhs]?.title ?? "").localizedCaseInsensitiveCompare(byID[rhs]?.title ?? "") == .orderedAscending
            }
            for (row, id) in ordered.enumerated() {
                let position = CGFloat(row) * (nodeSize.height + gap.height)
                y[id] = position
                nodes.append(Node(id: id, x: CGFloat(index) * (nodeSize.width + gap.width), y: position))
                height = max(height, position + nodeSize.height)
            }
        }
        let width = CGFloat(columns.count) * nodeSize.width + CGFloat(max(0, columns.count - 1)) * gap.width
        return TaskFlowLayout(nodes: nodes, edges: edges, size: CGSize(width: width, height: height))
    }

    private static func barycenter(_ id: UUID, parents: [UUID: [UUID]], y: [UUID: CGFloat]) -> CGFloat {
        let positions = (parents[id] ?? []).compactMap { y[$0] }
        guard !positions.isEmpty else { return 0 }
        return positions.reduce(0, +) / CGFloat(positions.count)
    }
}

extension TaskStore {
    public func flows() throws -> [TaskFlow] {
        try query("SELECT data FROM \(t("tasks_flows")) ORDER BY name").map { try decode(TaskFlow.self, $0[0]) }
    }

    public func saveFlow(_ flow: TaskFlow) throws {
        try execute(
            "INSERT INTO \(t("tasks_flows"))(name, data) VALUES($1, $2::jsonb) ON CONFLICT (name) DO UPDATE SET data = EXCLUDED.data",
            [flow.name, try encode(flow)])
    }

    /// Drops the card and takes the name off its tasks; the tasks stay.
    public func removeFlow(name: String) throws {
        try transaction {
            for var task in try self.tasks() where task.flowID == name {
                task.flowID = nil
                try self.update(task, expectedRevision: task.revision, actor: .user)
            }
            try self.execute("DELETE FROM \(self.t("tasks_flows")) WHERE name = $1", [name])
        }
    }
}
