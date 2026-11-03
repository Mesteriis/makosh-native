import SwiftUI

/// Shared application chrome. Content colors (media, status, explicit chat themes)
/// remain owned by their views rather than being recolored by the shell.
enum WorkspaceStyle {
    static let mailPaneHeaderHeight: CGFloat = 54
    static let accent = Color(red: 0.70, green: 0.48, blue: 0.98)
    static let base = Color(red: 0.075, green: 0.078, blue: 0.115)
    static let surface = Color(red: 0.13, green: 0.13, blue: 0.18)
    static let outgoing = Color(red: 0.31, green: 0.23, blue: 0.46)
}

private struct MakoshAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { WorkspaceBackdrop(intensity: 0.6) }
            .tint(WorkspaceStyle.accent)
            .accentColor(WorkspaceStyle.accent)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func makoshAppearance() -> some View { modifier(MakoshAppearance()) }
}
