import SwiftUI
import AppKit

func telegramWorkspaceScheme(theme: String, telegramSelected: Bool, system: ColorScheme) -> ColorScheme {
    telegramSelected ? TelegramLocalTheme(preference: theme).scheme ?? system : system
}

@MainActor final class TelegramSystemAppearance: ObservableObject {
    @Published private(set) var scheme: ColorScheme
    private var observation: NSKeyValueObservation?
    init() {
        scheme = Self.currentScheme
        observation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheme = Self.currentScheme }
        }
    }
    isolated deinit { observation?.invalidate() }
    private static var currentScheme: ColorScheme {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

enum TelegramLocalTheme: String, CaseIterable, Identifiable {
    case system, classic, day, night
    static let preferenceKey = "Makosh.Telegram.Theme"
    var id: String { rawValue }
    var title: String { switch self { case .system: "Системная"; case .classic: "Классическая"; case .day: "Дневная"; case .night: "Ночная" } }
    var scheme: ColorScheme? { switch self { case .system: nil; case .classic, .day: .light; case .night: .dark } }
    init(preference: String) { self = Self(rawValue: preference) ?? .system }
    var chatBackground: Color {
        self == .classic ? Color(red: 0.88, green: 0.92, blue: 0.87) : Color(nsColor: .windowBackgroundColor)
    }
}
enum TelegramAccent: String, CaseIterable, Identifiable {
    case blue, purple, green, orange
    static let preferenceKey = "Makosh.Telegram.Accent"
    var id: String { rawValue }
    var title: String { switch self { case .blue: "Синий"; case .purple: "Фиолетовый"; case .green: "Зелёный"; case .orange: "Оранжевый" } }
    var color: Color { switch self { case .blue: .blue; case .purple: .purple; case .green: .green; case .orange: .orange } }
    init(preference: String) { self = Self(rawValue: preference) ?? .blue }
}

struct TelegramAppearanceView: View {
    var systemScheme: ColorScheme = .light
    @AppStorage(TelegramLocalTheme.preferenceKey) private var theme = TelegramLocalTheme.system.rawValue
    @AppStorage(TelegramAccent.preferenceKey) private var accent = TelegramAccent.blue.rawValue
    var body: some View {
        Form {
            Section("Цветовая тема") {
                HStack(spacing: 12) {
                    ForEach(TelegramLocalTheme.allCases) { item in
                        Button { theme = item.rawValue } label: {
                            VStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 8) {
                                    RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.2)).frame(width: 50, height: 15)
                                    HStack { Spacer(); RoundedRectangle(cornerRadius: 6).fill(TelegramAccent(preference: accent).color.opacity(0.6)).frame(width: 55, height: 15) }
                                }.padding(10).frame(width: 95, height: 70).background(item.chatBackground, in: RoundedRectangle(cornerRadius: 10))
                                    .environment(\.colorScheme, item.scheme ?? systemScheme)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme == item.rawValue ? Color.accentColor : .secondary.opacity(0.3), lineWidth: theme == item.rawValue ? 2 : 1))
                                Text(item.title).font(.caption)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("telegram.settings.theme.\(item.rawValue)")
                            .accessibilityAddTraits(theme == item.rawValue ? .isSelected : [])
                    }
                }.padding(.vertical, 8)
            }
            Section("Цвет акцента") {
                HStack(spacing: 18) {
                    ForEach(TelegramAccent.allCases) { item in
                        Button { accent = item.rawValue } label: {
                            Image(systemName: accent == item.rawValue ? "checkmark.circle.fill" : "circle.fill")
                                .font(.system(size: 30)).foregroundStyle(item.color)
                        }.buttonStyle(.plain).accessibilityLabel(item.title)
                            .accessibilityIdentifier("telegram.settings.accent.\(item.rawValue)")
                            .accessibilityAddTraits(accent == item.rawValue ? .isSelected : [])
                    }
                }.padding(.vertical, 8)
            }
            Section("Предпросмотр") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Привет! Это пример оформления.").padding(10).background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    HStack { Spacer(); Text("Хорошо, до встречи!").padding(10).background(TelegramAccent(preference: accent).color.opacity(0.18), in: RoundedRectangle(cornerRadius: 12)) }
                }.padding().background(TelegramLocalTheme(preference: theme).chatBackground)
                    .accessibilityIdentifier("telegram.settings.appearancePreview")
            }
        }.formStyle(.grouped)
    }
}
