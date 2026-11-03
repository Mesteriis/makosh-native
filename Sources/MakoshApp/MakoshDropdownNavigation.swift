import SwiftUI

struct MakoshDropdownItem: Equatable, Sendable {
    let id: UUID
    var preferred = false
}

/// The rendered row order owns keyboard navigation, scoped to one open dropdown.
@MainActor
final class MakoshDropdownNavigation: ObservableObject {
    @Published var focusedID: UUID?
    private var items: [MakoshDropdownItem] = []
    var initialFocusID: UUID? { items.first(where: \.preferred)?.id ?? items.first?.id }

    func update(_ rows: [MakoshDropdownItem]) {
        items = rows
        if focusedID == nil || !rows.contains(where: { $0.id == focusedID }) { focusedID = initialFocusID }
    }

    func move(from id: UUID, by offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == id } ?? 0
        focusedID = items[(current + offset + items.count) % items.count].id
    }
}

struct MakoshDropdownRowsKey: PreferenceKey {
    static let defaultValue: [MakoshDropdownItem] = []
    static func reduce(value: inout [MakoshDropdownItem], nextValue: () -> [MakoshDropdownItem]) { value += nextValue() }
}
private struct DropdownFocusKey: EnvironmentKey {
    static var defaultValue: FocusState<UUID?>.Binding? { nil }
}
private struct DropdownNavigationKey: EnvironmentKey { static let defaultValue: MakoshDropdownNavigation? = nil }
private struct DropdownDismissKey: EnvironmentKey { static let defaultValue: @MainActor @Sendable () -> Void = {} }
private struct DropdownPreferredFocusKey: EnvironmentKey { static let defaultValue = false }
private struct DropdownContextKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var makoshDropdownFocus: FocusState<UUID?>.Binding? {
        get { self[DropdownFocusKey.self] }
        set { self[DropdownFocusKey.self] = newValue }
    }
    var makoshDropdownNavigation: MakoshDropdownNavigation? {
        get { self[DropdownNavigationKey.self] }
        set { self[DropdownNavigationKey.self] = newValue }
    }
    var dismissMakoshDropdown: @MainActor @Sendable () -> Void {
        get { self[DropdownDismissKey.self] }
        set { self[DropdownDismissKey.self] = newValue }
    }
    var makoshDropdownPreferredFocus: Bool {
        get { self[DropdownPreferredFocusKey.self] }
        set { self[DropdownPreferredFocusKey.self] = newValue }
    }
    var isInMakoshDropdown: Bool {
        get { self[DropdownContextKey.self] }
        set { self[DropdownContextKey.self] = newValue }
    }
}
