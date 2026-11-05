import SwiftUI

/// Uses public SwiftUI container tags, including optional selections; no reflection.
struct MakoshPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    let content: Content
    @Environment(\.labelsVisibility) private var labels
    @Environment(\.isInMakoshDropdown) private var inline

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    var body: some View {
        if inline {
            options
        } else {
            HStack {
                if labels != .hidden {
                    Text(title)
                    Spacer(minLength: 8)
                }
                MakoshMenu {
                    options
                } label: {
                    Group(subviews: content) { children in
                        if let selected = children.first(where: { $0.containerValues.hasTag(selection) }) {
                            selected
                        } else {
                            Text("Выберите…").foregroundStyle(.secondary)
                        }
                    }
                }
                .makoshMenuStyle(.bordered).makoshMenuIndicator(.visible)
                // VoiceOver hears the title and the selected option, as with a native pop-up button.
                .accessibilityRepresentation { Picker(title, selection: $selection) { content } }
            }
        }
    }

    private var options: some View {
        Group(subviews: content) { children in
            ForEach(children.indices, id: \.self) { index in
                let child = children[index]
                if let value = child.containerValues.tag(for: Selection.self) {
                    MakoshMenuItem {
                        selection = value
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").opacity(selection == value ? 1 : 0).frame(width: 14)
                            child
                        }
                    }
                    .accessibilityValue(selection == value ? "Выбрано" : "")
                    .environment(\.makoshDropdownPreferredFocus, selection == value)
                }
            }
        }
    }
}
