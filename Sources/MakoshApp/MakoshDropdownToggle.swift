import SwiftUI

/// Checked menu actions share the same focus/activation path as ordinary rows.
/// Native context menus keep their native Toggle representation.
struct MakoshDropdownToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isInMakoshDropdown) private var inDropdown

    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }

    var body: some View {
        if inDropdown {
            MakoshMenuItem { isOn.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").opacity(isOn ? 1 : 0).frame(width: 14)
                    Text(title)
                }
            }.buttonStyle(MakoshDropdownActionStyle())
                .accessibilityValue(isOn ? "Включено" : "Выключено")
        } else { Toggle(title, isOn: $isOn) }
    }
}
