import SwiftUI
import AppKit
import MakoshTelegram
import MakoshCore
import ImageIO

struct TelegramAppearanceCatalogView: View {
    @ObservedObject var controller: TelegramAppearanceCatalogController
    @AppStorage(TelegramAppearancePreferences.preferenceKey) private var appearanceRaw = ""
    @Environment(\.dismiss) private var dismiss
    private struct Preview: Identifiable {
        let prepared: TelegramAppearanceCatalogController.Prepared
        let expectedRaw: String
        var id: UUID { prepared.id }
    }
    @State private var preview: Preview?
    var body: some View {
        VStack(spacing:0) {
            HStack { Text("Темы и обои Telegram").font(.headline); Spacer(); Button("Готово") { dismiss() } }.padding()
            HStack {
                if controller.phase == .loading || controller.phase == .preparing { ProgressView().controlSize(.small) }
                Text(controller.phase == .preparing ? "Подготовка выбранного оформления…" : "Оформление применяется в Макоше на этом Mac.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if controller.phase == .preparing { Button("Отменить") { controller.cancelSelection() }.accessibilityIdentifier("telegram.catalog.cancel") }
                Button("Обновить") { controller.open() }.disabled(controller.phase == .preparing).accessibilityIdentifier("telegram.catalog.refresh")
            }.padding(.horizontal).padding(.bottom,8)
            if controller.phase == .failed { Text("Не удалось загрузить каталог или выбранный файл. Обновите каталог и повторите выбор.").foregroundStyle(.red).font(.caption).padding().accessibilityIdentifier("telegram.catalog.failure") }
            if let snapshot = controller.snapshot {
                Form {
                    if snapshot.choices.isEmpty { Text("Нет сохранённых тем или обоев").accessibilityIdentifier("telegram.catalog.empty") }
                    Section("Темы") { ForEach(snapshot.choices.filter { $0.id.hasPrefix("theme:") }) { row($0) } }
                    Section("Обои") { ForEach(snapshot.choices.filter { $0.id.hasPrefix("wallpaper:") }) { row($0) } }
                }.formStyle(.grouped)
            } else { Spacer(); if controller.phase == .loading { ProgressView("Загрузка каталога…") }; Spacer() }
        }.frame(width:560,height:620)
            .onAppear { controller.open() }.onDisappear { controller.close() }
            .onReceive(controller.$prepared) { value in if let value { preview = .init(prepared:value,expectedRaw:appearanceRaw) } }
            .onChange(of:controller.contextID) { _, value in if preview?.prepared.contextID != value { preview = nil } }
            .sheet(item:$preview) { value in TelegramCloudAppearancePreview(controller:controller,prepared:value.prepared,expectedRaw:value.expectedRaw) }
    }
    private func row(_ choice: TelegramCloudAppearanceChoice) -> some View {
        let unavailable: Bool = { if case .unavailable = choice.kind { return true }; return false }()
        return Button { _ = controller.select(choice,contextID:controller.contextID) } label: {
            HStack {
                Image(systemName:choice.id.hasPrefix("theme:") ? "paintpalette" : "photo")
                VStack(alignment:.leading,spacing:4) {
                    Text(choice.title)
                    if case let .unavailable(reason) = choice.kind { Text(reason).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(); Image(systemName:"chevron.right").foregroundStyle(.secondary)
            }.frame(minHeight:40).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(controller.phase != .ready || unavailable).accessibilityIdentifier("telegram.catalog.\(choice.id)")
    }
}

private struct TelegramCloudAppearancePreview: View {
    @ObservedObject var controller: TelegramAppearanceCatalogController
    let prepared: TelegramAppearanceCatalogController.Prepared
    let expectedRaw: String
    @AppStorage(TelegramAppearancePreferences.preferenceKey) private var appearanceRaw = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var error: String?
    @State private var applying = false
    @State private var applyTask: Task<Void, Never>?
    private var palette: TelegramCloudPalette? { if case let .theme(value) = prepared.kind { return value }; return nil }
    private var previewScheme: ColorScheme { palette.map { $0.isDark ? .dark : .light } ?? colorScheme }
    private var current: Bool { controller.contextID == prepared.contextID && controller.prepared?.id == prepared.id && appearanceRaw == expectedRaw }
    var body: some View {
        VStack(spacing:16) {
            HStack { Button("Отмена") { dismiss() }; Spacer(); Text("Предпросмотр").font(.headline); Spacer()
                Button("Применить",action:apply).disabled(!current || applying).accessibilityIdentifier("telegram.catalog.apply")
            }
            Text(prepared.choice.title).font(.title3)
            VStack(alignment:.leading,spacing:18) {
                Text("Привет! Как дела?").padding(12).background(palette.flatMap { p in p.incoming.map { telegramPaletteColor(p,"incoming",$0) } } ?? telegramDefaultBubbleColor(outgoing:false,scheme:previewScheme),in:RoundedRectangle(cornerRadius:12))
                HStack { Spacer(); Text("Всё хорошо!").padding(12).background(outgoingStyle,in:RoundedRectangle(cornerRadius:12)) }
            }.padding(24).frame(height:280).frame(maxWidth:.infinity).background { background }.clipped()
                .foregroundStyle(palette.flatMap { p in p.text.map { telegramPaletteColor(p,"text",$0) } } ?? .primary).accessibilityIdentifier("telegram.catalog.preview")
            Text("Сохранится только оформление Макоша на этом Mac.").font(.caption).foregroundStyle(.secondary)
            if !current { Text("Аккаунт или оформление изменилось. Откройте предпросмотр заново.").foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red) }
        }.padding().frame(width:520,height:460)
            .tint(palette.map { telegramPaletteColor($0,"accent",$0.accent) } ?? .accentColor)
            .preferredColorScheme(palette.map { $0.isDark ? .dark : .light })
            .onDisappear { applyTask?.cancel(); if controller.prepared?.id == prepared.id { controller.cancelSelection() } }
    }
    private var outgoingStyle: AnyShapeStyle {
        guard let palette,!palette.outgoing.isEmpty else { return AnyShapeStyle(telegramDefaultBubbleColor(outgoing:true,scheme:previewScheme)) }
        return AnyShapeStyle(LinearGradient(colors:palette.outgoing.enumerated().map { telegramPaletteColor(palette,"outgoing.\($0.offset)",$0.element) },startPoint:.top,endPoint:.bottom))
    }
    @ViewBuilder private var background: some View {
        switch prepared.kind {
        case let .theme(value): value.background.map { telegramPaletteColor(value,"background",$0) } ?? Color(nsColor:.windowBackgroundColor)
        case let .wallpaper(value): TelegramWallpaperBackground(wallpaper:value,fallback:Color(nsColor:.windowBackgroundColor))
        case let .pattern(value): TelegramWallpaperBackground(wallpaper:.pattern(.init(name:prepared.id.uuidString.lowercased()+".png",colors:value.colors,intensity:value.intensity)),fallback:Color(nsColor:.windowBackgroundColor),preparedPattern:value.data)
        case let .image(data): TelegramPreparedWallpaperImage(data: data, id: prepared.id)
        default: Color(nsColor:.windowBackgroundColor)
        }
    }
    private func apply() {
        guard current, !applying else { error = "Оформление изменилось. Откройте предпросмотр заново."; return }
        applying = true
        applyTask = Task { @MainActor in
            defer { applying = false; applyTask = nil }
            var installed: String?
            do {
                var preferences = try TelegramAppearancePreferences.decode(expectedRaw)
                switch prepared.kind {
                case let .theme(value): preferences.cloudPalette = value; preferences.wallpaper = .automatic
                case let .wallpaper(value): preferences.wallpaper = value
                case let .image(data):
                    let name = try await TelegramWallpaperFiles.installInBackground(data); installed = name
                    preferences.wallpaper = .image(name)
                case let .pattern(value):
                    let name = try await TelegramWallpaperFiles.installInBackground(value.data, pattern: true); installed = name
                    preferences.wallpaper = .pattern(.init(name: name, colors: value.colors, intensity: value.intensity))
                default: throw TelegramAppearanceError.invalid
                }
                guard !Task.isCancelled, current else {
                    if let installed { try? await TelegramWallpaperFiles.discardInstalled(installed) }; return
                }
                appearanceRaw = try preferences.encoded(); dismiss()
            } catch {
                if let installed { try? await TelegramWallpaperFiles.discardInstalled(installed) }
                if !Task.isCancelled { self.error = "Не удалось сохранить оформление. Обновите каталог и повторите выбор." }
            }
        }
    }
}

private struct TelegramPreparedWallpaperImage: View {
    let data: Data
    let id: UUID
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Color(nsColor: .windowBackgroundColor) }
        }.task(id: id) {
            image = nil
            let value = try? await BackgroundWork.run {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw TelegramAppearanceError.image }
                return image
            }
            guard !Task.isCancelled else { return }; image = value
        }
    }
}
