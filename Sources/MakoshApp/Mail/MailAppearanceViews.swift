import SwiftUI

/// Visual constraints from the pinned Aether reference; no account data or IO.
struct MailSenderAvatar: View {
    let name: String
    let address: String
    let size: CGFloat
    private var initials: String {
        let label = name.isEmpty ? address : name
        return String(label.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)).uppercased()
    }
    private var color: Color {
        let colors: [Color] = [.purple, .blue, .pink, .orange, .teal, .indigo]
        let index = address.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return colors[index]
    }
    var body: some View {
        Circle().fill(color.gradient)
            .overlay(Text(initials.isEmpty ? "?" : initials).font(.system(size: size < 30 ? 9 : 13, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct MailPaperSheet: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(WorkspaceStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(14)
    }
}
