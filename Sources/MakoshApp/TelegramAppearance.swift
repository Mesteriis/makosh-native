import SwiftUI
import AppKit
import MakoshTelegram

func telegramWorkspaceScheme(theme: String, telegramSelected: Bool, system: ColorScheme, night: TelegramNightSchedule = .init(), date: Date = Date(), cloudDark: Bool? = nil) -> ColorScheme {
    guard telegramSelected else { return system }
    if night.enabled { return night.isNight(at: date) ? .dark : .light }
    if let cloudDark { return cloudDark ? .dark : .light }
    return TelegramLocalTheme(preference: theme).scheme ?? system
}

@MainActor final class TelegramSystemAppearance: ObservableObject {
    @Published private(set) var scheme: ColorScheme
    @Published private(set) var now = Date()
    private var clock: Task<Void, Never>?
    private var observation: NSKeyValueObservation?
    init() {
        scheme = Self.currentScheme
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.now = Date()
            }
        }
        observation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheme = Self.currentScheme }
        }
    }
    isolated deinit { observation?.invalidate(); clock?.cancel() }
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
    @AppStorage(TelegramAppearancePreferences.preferenceKey) private var appearanceRaw = ""
    @State private var wallpaperPresented = false
    @State private var wallpaperExpectedRaw = ""
    @State private var error: String?
    private var preferences: TelegramAppearancePreferences { (try? .decode(appearanceRaw)) ?? .init() }
    var systemScheme: ColorScheme = .light
    var catalog: TelegramAppearanceCatalogController? = nil
    @State private var catalogPresented = false
    @AppStorage(TelegramLocalTheme.preferenceKey) private var theme = TelegramLocalTheme.system.rawValue
    @AppStorage(TelegramAccent.preferenceKey) private var accent = TelegramAccent.blue.rawValue
    var body: some View {
        Form {
            if (try? TelegramAppearancePreferences.decode(appearanceRaw)) == nil {
                Section { Text("Настройки оформления повреждены. Сбросьте их перед изменением.").foregroundStyle(.red)
                    Button("Сбросить локальное оформление") { appearanceRaw = "" } }
            }
            Section("Размер текста") {
                Picker("Размер сообщений", selection: Binding(get: { preferences.fontSize }, set: { size in update { $0.fontSize = size } })) {
                    ForEach(11...18,id: \.self) { Text("\($0)").tag($0) }
                }.accessibilityIdentifier("telegram.settings.fontSize")
            }
            Section("Фон чата") {
                Button("Изменить фон…") { wallpaperExpectedRaw = appearanceRaw; wallpaperPresented = true }.accessibilityIdentifier("telegram.settings.wallpaper")
            }
            Section("Автоматическая ночная тема") {
                Toggle("По расписанию", isOn: Binding(get: { preferences.night.enabled }, set: { enabled in update { $0.night.enabled = enabled } }))
                    .accessibilityIdentifier("telegram.settings.night.enabled")
                if preferences.night.enabled {
                    DatePicker("С",selection: timeBinding(start: true),displayedComponents: .hourAndMinute).accessibilityIdentifier("telegram.settings.night.start")
                    DatePicker("До",selection: timeBinding(start: false),displayedComponents: .hourAndMinute).accessibilityIdentifier("telegram.settings.night.end")
                    Text("Вне выбранного времени используется дневная тема. Время следует часовому поясу Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if catalog != nil {
                Section("Темы и обои Telegram") {
                    Button("Открыть каталог…") { catalogPresented = true }.accessibilityIdentifier("telegram.settings.cloudCatalog")
                    if let palette = preferences.cloudPalette { Text(palette.name).foregroundStyle(.secondary) }
                }
            }
            Section("Цветовая тема") {
                HStack(spacing: 12) {
                    ForEach(TelegramLocalTheme.allCases) { item in
                        Button { update { $0.cloudPalette = nil }; theme = item.rawValue } label: {
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
                }.padding().background { TelegramWallpaperBackground(wallpaper: preferences.wallpaper, fallback: TelegramLocalTheme(preference: theme).chatBackground) }
                    .accessibilityIdentifier("telegram.settings.appearancePreview")
            }
        }.formStyle(.grouped)
            .sheet(isPresented: $wallpaperPresented) { TelegramWallpaperEditor(expectedRaw: wallpaperExpectedRaw) }
            .sheet(isPresented: $catalogPresented) { if let catalog { TelegramAppearanceCatalogView(controller: catalog) } }
    }
    private func update(_ change: (inout TelegramAppearancePreferences) -> Void) {
        do { var value = try TelegramAppearancePreferences.decode(appearanceRaw); change(&value); appearanceRaw = try value.encoded(); error = nil }
        catch { self.error = "Не удалось сохранить настройки. Проверьте время и значения." }
    }
    private func timeBinding(start: Bool) -> Binding<Date> {
        .init(get: {
            let minute = start ? preferences.night.startMinute : preferences.night.endMinute
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let components = Calendar.current.dateComponents([.hour,.minute],from:date)
            guard let hour = components.hour, let minute = components.minute else { return }
            update { if start { $0.night.startMinute = hour * 60 + minute } else { $0.night.endMinute = hour * 60 + minute } }
        })
    }
}
