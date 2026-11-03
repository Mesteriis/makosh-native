import SwiftUI

/// Dismissal belongs to the semantic Button action, including AX activation.
/// ButtonStyle controls presentation/focus and must not own action side effects.
struct MakoshMenuItem<Label: View>: View {
    private let role: ButtonRole?
    private let action: () -> Void
    private let label: Label
    @Environment(\.isInMakoshDropdown) private var inDropdown
    @Environment(\.dismissMakoshDropdown) private var close

    init(role: ButtonRole? = nil, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.role = role; self.action = action; self.label = label()
    }
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) where Label == Text {
        self.role = role; self.action = action; label = Text(title)
    }
    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) where Label == SwiftUI.Label<Text, Image> {
        self.role = role; self.action = action; label = SwiftUI.Label(title, systemImage: systemImage)
    }
    var body: some View {
        Button(role: role) {
            if inDropdown { close() }
            action()
        } label: { label }
    }
}
