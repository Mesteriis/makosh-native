import SwiftUI

/// Shared application chrome. Content colors (media, status, explicit chat themes)
/// remain owned by their views rather than being recolored by the shell.
enum WorkspaceStyle {
    static let controlHeight: CGFloat = 30
    static let compactControlHeight: CGFloat = 24
    static let largeControlHeight: CGFloat = 36
    static let segmentHeight: CGFloat = 36
    static let controlInset: CGFloat = 10
    static let cardInset: CGFloat = 18
    static let sectionGap: CGFloat = 20
    static let cardRadius: CGFloat = 14
    static let disabledOpacity = 0.45
    static let border = Color(red: 0.56, green: 0.52, blue: 0.72).opacity(0.22)
    static let highlight = Color(red: 0.72, green: 0.66, blue: 0.92).opacity(0.055)
    static let settingsContentWidth: CGFloat = 760
    static let sectionTitleWidth: CGFloat = 110
    static let railWidth: CGFloat = 64
    static let railInset: CGFloat = 8
    static let railButtonSize: CGFloat = 44
    static let railIconSize: CGFloat = 20
    static let settingsSidebarWidth: CGFloat = 220
    static let controlRadius: CGFloat = 8
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
            .toggleStyle(WorkspaceToggleStyle())
            .buttonStyle(WorkspaceButtonStyle())
            .textFieldStyle(WorkspaceTextFieldStyle())
            .formStyle(WorkspaceFormStyle())
            .tint(WorkspaceStyle.accent)
            .accentColor(WorkspaceStyle.accent)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func makoshAppearance() -> some View { modifier(MakoshAppearance()) }
}

private struct WorkspaceSettingsContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var workspaceSettingsContentWidth: CGFloat? {
        get { self[WorkspaceSettingsContentWidthKey.self] }
        set { self[WorkspaceSettingsContentWidthKey.self] = newValue }
    }
}
