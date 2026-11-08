import MakoshCalendar
import SwiftUI

/// Calendar section tokens on top of the shared workspace style.
enum CalendarStyle {
    static let hourHeight: CGFloat = 44
    static let gutterWidth: CGFloat = 48
    static let headerHeight: CGFloat = WorkspaceStyle.mailPaneHeaderHeight
    static let dayHeaderHeight: CGFloat = 30
    static let allDayRowHeight: CGFloat = 20
    static let taskColumnWidth: CGFloat = 250
    static let blockRadius: CGFloat = 5
    static let workingShade = Color.white.opacity(0.045)
    static let hourLine = Color.white.opacity(0.07)
    static let todayTint = WorkspaceStyle.accent.opacity(0.10)
    static let snapMinutes = 15

    static func color(_ hex: String) -> Color {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count >= 6, let value = UInt32(text.prefix(6), radix: 16) else { return WorkspaceStyle.accent }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static let palette = ["#8b5cf6", "#3b82f6", "#10b981", "#f59e0b", "#ef4444", "#ec4899", "#14b8a6", "#64748b"]
}

/// Diagonal stripes for busy copies.
struct CalendarHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 7
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += step
        }
        return path
    }
}

extension DateFormatter {
    static func calendar(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter
    }
}
