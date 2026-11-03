import SwiftUI

enum MakoshMenuAppearance: Sendable { case plain, bordered }
private struct MenuAppearanceKey: EnvironmentKey { static let defaultValue = MakoshMenuAppearance.plain }
private struct MenuWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 300 }
private struct MenuIndicatorKey: EnvironmentKey { static let defaultValue = Visibility.automatic }

extension View {
    func makoshMenuWidth(_ width: CGFloat) -> some View { environment(\.makoshMenuWidth, width) }
    func makoshMenuStyle(_ style: MakoshMenuAppearance) -> some View { environment(\.makoshMenuAppearance, style) }
    func makoshMenuIndicator(_ visibility: Visibility) -> some View { environment(\.makoshMenuIndicator, visibility) }
}
private extension EnvironmentValues {
    var makoshMenuWidth: CGFloat {
        get { self[MenuWidthKey.self] }
        set { self[MenuWidthKey.self] = newValue }
    }
    var makoshMenuAppearance: MakoshMenuAppearance {
        get { self[MenuAppearanceKey.self] }
        set { self[MenuAppearanceKey.self] = newValue }
    }
    var makoshMenuIndicator: Visibility {
        get { self[MenuIndicatorKey.self] }
        set { self[MenuIndicatorKey.self] = newValue }
    }
}

/// App-owned dropdown surface. Existing Button/Toggle actions remain at call sites.
struct MakoshMenu<Label: View, Content: View>: View {
    private let label: Label
    private let content: Content
    private let titled: Bool
    private var primaryAction: (() -> Void)? = nil
    @State private var presented = false
    @State private var expanded = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.makoshMenuWidth) private var width
    @Environment(\.isInMakoshDropdown) private var nested
    @Environment(\.makoshMenuAppearance) private var appearance
    @Environment(\.makoshMenuIndicator) private var indicator

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content(); self.label = label(); titled = false
    }
    init(_ title: String, @ViewBuilder content: () -> Content) where Label == Text {
        self.content = content(); label = Text(title); titled = true
    }

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label, primaryAction: @escaping () -> Void) {
        self.content = content(); self.label = label(); titled = false; self.primaryAction = primaryAction
    }

    var body: some View {
        if nested {
            VStack(alignment: .leading, spacing: 2) {
                Button { expanded.toggle() } label: {
                    HStack { label; Spacer(minLength: 8); Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(MakoshDropdownActionStyle())
                    .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
                if expanded {
                    VStack(alignment: .leading, spacing: 2) { content }.padding(.leading, 12)
                }
            }
        } else {
            HStack(spacing: 3) {
                if let primaryAction { Button(action: primaryAction) { label }.buttonStyle(.borderedProminent) }
                Button { presented.toggle() } label: {
                HStack(spacing: 7) {
                    if primaryAction == nil { label }
                    if primaryAction != nil || indicator == .visible || (indicator == .automatic && (titled || appearance == .bordered)) {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, appearance == .bordered ? 11 : 3)
                .padding(.vertical, appearance == .bordered ? 8 : 5)
                .background(appearance == .bordered ? Color.white.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
                .buttonStyle(.plain).foregroundStyle(enabled ? .primary : .secondary)
                .focusable(enabled)
                .onKeyPress(.downArrow) { presented = true; return .handled }
            }
            .accessibilityValue(presented ? "Открыто" : "Закрыто")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                MakoshDropdownPanel(content: content, width: width) { presented = false }
                    .presentationBackground(WorkspaceStyle.base)
            }
        }
    }
}

private struct MakoshDropdownPanel<Content: View>: View {
    let content: Content
    let width: CGFloat
    let close: @MainActor @Sendable () -> Void
    @StateObject private var navigation = MakoshDropdownNavigation()
    @State private var height: CGFloat = 40
    @FocusState private var focusedRow: UUID?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) { content }
            .padding(7)
            .onPreferenceChange(MakoshDropdownRowsKey.self) { navigation.update($0) }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(width: width, height: min(max(height, 36), 440))
        .font(.system(size: 13)).foregroundStyle(.primary).tint(WorkspaceStyle.accent)
        .background { WorkspaceBackdrop(intensity: 0.25) }
        .buttonStyle(MakoshDropdownActionStyle())
        .environment(\.isInMakoshDropdown, true)
        .environment(\.makoshDropdownNavigation, navigation)
        .environment(\.makoshDropdownFocus, $focusedRow)
        .environment(\.dismissMakoshDropdown, close)
        .preferredColorScheme(.dark)
        .defaultFocus($focusedRow, navigation.initialFocusID)
        .task { await Task.yield(); focusedRow = navigation.initialFocusID }
        .onChange(of: navigation.focusedID) { _, value in focusedRow = value }
        .onChange(of: focusedRow) { _, value in if let value { navigation.focusedID = value } }
        .onMoveCommand { direction in
            guard let id = navigation.focusedID ?? navigation.initialFocusID else { return }
            if direction == .down { navigation.move(from: id, by: 1) }
            else if direction == .up { navigation.move(from: id, by: -1) }
        }
        .onKeyPress(.escape) { close(); return .handled }
        .accessibilityElement(children: .contain)
    }
}

struct MakoshDropdownActionStyle: PrimitiveButtonStyle {
    @Environment(\.makoshDropdownNavigation) private var navigation
    @Environment(\.makoshDropdownFocus) private var focus
    @Environment(\.makoshDropdownPreferredFocus) private var preferredFocus
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        if let navigation, let focus { MakoshDropdownActionRow(configuration: configuration, navigation: navigation, focus: focus, preferredFocus: preferredFocus, enabled: enabled) }
        else { Button(configuration).buttonStyle(.plain) }
    }
}

private struct MakoshDropdownActionRow: View {
    let configuration: PrimitiveButtonStyleConfiguration
    @ObservedObject var navigation: MakoshDropdownNavigation
    let focus: FocusState<UUID?>.Binding
    let preferredFocus: Bool
    let enabled: Bool
    @State private var id = UUID()
    @State private var hovered = false
    private var focused: Bool { focus.wrappedValue == id }
    var body: some View {
        Button(role: configuration.role) { activate() } label: {
            configuration.label
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .foregroundStyle(configuration.role == .destructive ? Color.red : enabled ? Color.primary : Color.secondary)
                .background(hovered || focused ? WorkspaceStyle.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(enabled).focused(focus, equals: id).focusEffectDisabled()
        .onHover { hovered = $0 && enabled }
        .preference(key: MakoshDropdownRowsKey.self, value: enabled ? [.init(id: id, preferred: preferredFocus)] : [])
        .onKeyPress(.downArrow) { navigation.move(from: id, by: 1); return .handled }
        .onKeyPress(.upArrow) { navigation.move(from: id, by: -1); return .handled }
        .onKeyPress(.return) { activate(); return .handled }
        .onKeyPress(.space) { activate(); return .handled }
    }
    private func activate() {
        guard enabled else { return }
        configuration.trigger()
    }
}
