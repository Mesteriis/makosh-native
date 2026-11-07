import Foundation

/// Cursor and selection over the visible list, as the reference keeps them:
/// the cursor is a row index, the selection a set of ids, the anchor the row a
/// shift-range extends from. Pure; the model owns one and clamps it to the list.
public struct TaskSelection: Equatable, Sendable {
    public var cursor: Int?
    public var selected: Set<UUID> = []
    public var anchor: Int?

    public init() {}

    /// A plain click selects one row; shift extends from the anchor; command toggles the row.
    public mutating func click(index: Int, id: UUID, shift: Bool, command: Bool, visible: [UUID]) {
        cursor = index
        if shift, let anchor {
            selected = Set(visible[range(anchor, index, count: visible.count)])
        } else if command {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = index
        } else {
            selected = [id]
            anchor = index
        }
    }

    public mutating func move(by delta: Int, extend: Bool, visible: [UUID]) {
        guard !visible.isEmpty else { return }
        let next = min(max((cursor.map { $0 + delta } ?? 0), 0), visible.count - 1)
        place(at: next, extend: extend, visible: visible)
    }

    public mutating func jump(toStart: Bool, extend: Bool, visible: [UUID]) {
        guard !visible.isEmpty else { return }
        place(at: toStart ? 0 : visible.count - 1, extend: extend, visible: visible)
    }

    private mutating func place(at next: Int, extend: Bool, visible: [UUID]) {
        if extend {
            let from = anchor ?? cursor ?? next
            anchor = from
            selected = Set(visible[range(from, next, count: visible.count)])
        } else {
            selected = [visible[next]]
            anchor = next
        }
        cursor = next
    }

    public mutating func selectAll(visible: [UUID]) { selected = Set(visible) }

    public mutating func clear() { selected = [] }

    /// Hidden rows leave the selection; the cursor stays within the list.
    public mutating func clamp(to visible: [UUID]) {
        selected = selected.filter { visible.contains($0) }
        if visible.isEmpty {
            cursor = nil
            anchor = nil
        } else {
            cursor = cursor.map { min($0, visible.count - 1) }
            anchor = anchor.map { min($0, visible.count - 1) }
        }
    }

    /// What an action applies to: the selection in visible order, else the cursor row.
    public func targets(visible: [UUID]) -> [UUID] {
        if !selected.isEmpty { return visible.filter { selected.contains($0) } }
        if let cursor, visible.indices.contains(cursor) { return [visible[cursor]] }
        return []
    }

    private func range(_ a: Int, _ b: Int, count: Int) -> ClosedRange<Int> {
        let lo = max(0, min(a, b)), hi = min(count - 1, max(a, b))
        return lo...hi
    }
}
