import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MakoshTelegram

struct TelegramWallpaperBackground: View {
    let wallpaper: TelegramLocalWallpaper
    let fallback: Color
    @State private var image: CGImage?
    private var imageName: String? { if case let .image(name) = wallpaper { return name }; return nil }
    var body: some View {
        Group {
            switch wallpaper {
            case .automatic: fallback
            case let .solid(color): telegramRGBColor(color)
            case let .gradient(a,b): LinearGradient(colors:[telegramRGBColor(a),telegramRGBColor(b)],startPoint:.topLeading,endPoint:.bottomTrailing)
            case .image:
                GeometryReader { geometry in
                    if let image { Image(decorative:image,scale:1).resizable().scaledToFill().frame(width:geometry.size.width,height:geometry.size.height).clipped() }
                    else { fallback }
                }
            }
        }.task(id:imageName) {
            image = nil
            guard let imageName else { return }
            let loaded = await Task.detached(priority:.utility) { () -> CGImage? in
                guard let data = try? TelegramWallpaperFiles.load(imageName),
                      let source = CGImageSourceCreateWithData(data as CFData,nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (1...2560).contains(width), (1...2560).contains(height) else { return nil }
                return CGImageSourceCreateImageAtIndex(source,0,nil)
            }.value
            guard !Task.isCancelled else { return }; image = loaded
        }.accessibilityHidden(true)
    }
}
func telegramRGBColor(_ rgb: UInt32) -> Color {
    .init(red:Double((rgb >> 16) & 255)/255,green:Double((rgb >> 8) & 255)/255,blue:Double(rgb & 255)/255)
}

struct TelegramWallpaperEditor: View {
    let expectedRaw: String
    @AppStorage(TelegramAppearancePreferences.preferenceKey) private var appearanceRaw = ""
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "automatic"
    @State private var first: UInt32 = 0xdce8df
    @State private var second: UInt32 = 0xc6d5ed
    @State private var originalName: String?
    @State private var selectedData: Data?
    @State private var error: String?
    @State private var busy = false
    @State private var preparationID = UUID()
    var body: some View {
        VStack(spacing:0) {
            HStack { Button("Отмена") { dismiss() }; Spacer(); Text("Фон чата").font(.headline); Spacer()
                Button("Сохранить",action:save).disabled(busy || appearanceRaw != expectedRaw || (mode == "image" && selectedData == nil && originalName == nil)).accessibilityIdentifier("telegram.wallpaper.save")
            }.padding()
            Form {
                Section {
                    Picker("Фон",selection:$mode) {
                        Text("По умолчанию").tag("automatic"); Text("Цвет").tag("solid"); Text("Градиент").tag("gradient"); Text("Изображение").tag("image")
                    }.accessibilityIdentifier("telegram.wallpaper.mode")
                    if mode == "solid" || mode == "gradient" { ColorPicker("Цвет",selection:color($first),supportsOpacity:false).accessibilityIdentifier("telegram.wallpaper.color") }
                    if mode == "gradient" { ColorPicker("Второй цвет",selection:color($second),supportsOpacity:false).accessibilityIdentifier("telegram.wallpaper.secondColor") }
                    if mode == "image" {
                        Button("Выбрать изображение…",action:pick).disabled(busy).accessibilityIdentifier("telegram.wallpaper.pick")
                        if busy { ProgressView("Подготовка изображения…") }
                        Text("Статичное изображение до32МБ. Фон сохраняется локально без исходных метаданных.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Предпросмотр") {
                    VStack(alignment:.leading,spacing:12) {
                        Text("Привет! Как дела?").padding(10).background(.background,in:RoundedRectangle(cornerRadius:12))
                        HStack { Spacer(); Text("Всё хорошо!").padding(10).background(Color.accentColor.opacity(0.25),in:RoundedRectangle(cornerRadius:12)) }
                    }.padding().frame(height:190).background {
                        if mode == "image", let selectedData, let image = NSImage(data:selectedData) { Image(nsImage:image).resizable().scaledToFill().clipped() }
                        else { TelegramWallpaperBackground(wallpaper:draft,fallback:Color(nsColor:.windowBackgroundColor)) }
                    }.clipped().accessibilityIdentifier("telegram.wallpaper.preview")
                }
                if appearanceRaw != expectedRaw { Text("Оформление изменено в другом окне. Закройте редактор и откройте его заново.").foregroundStyle(.red) }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
        }.frame(width:520,height:580)
            .onAppear {
                guard let preferences = try? TelegramAppearancePreferences.decode(expectedRaw) else { error = "Настройки оформления повреждены."; return }
                switch preferences.wallpaper {
                case .automatic: mode = "automatic"
                case let .solid(value): mode = "solid"; first = value
                case let .gradient(a,b): mode = "gradient"; first = a; second = b
                case let .image(name): mode = "image"; originalName = name
                }
            }.onDisappear { preparationID = UUID() }
    }
    private var draft: TelegramLocalWallpaper {
        switch mode { case "solid": return .solid(first); case "gradient": return .gradient(first,second); case "image": return originalName.map(TelegramLocalWallpaper.image) ?? .automatic; default: return .automatic }
    }
    private func color(_ rgb: Binding<UInt32>) -> Binding<Color> {
        .init(get:{ telegramRGBColor(rgb.wrappedValue) },set:{ color in
            guard let value = NSColor(color).usingColorSpace(.deviceRGB) else { return }
            let components = [value.redComponent,value.greenComponent,value.blueComponent]
            guard components.allSatisfy(\.isFinite) else { return }
            let bytes = components.map { UInt32((min(1,max(0,$0)) * 255).rounded()) }
            rgb.wrappedValue = bytes[0] << 16 | bytes[1] << 8 | bytes[2]
        })
    }
    private func pick() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let id = UUID(); preparationID = id; busy = true; error = nil
            let scoped = url.startAccessingSecurityScopedResource()
            Task { @MainActor in
                let result = await Task.detached(priority:.utility) { () -> Result<Data,Error> in
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return Result { try TelegramWallpaperImage.prepare(TelegramWallpaperFiles.readSelection(url)) }
                }.value
                guard preparationID == id else { return }; busy = false
                switch result { case let .success(data): selectedData = data; case .failure: error = "Не удалось подготовить изображение. Выберите статичный файл до32МБ." }
            }
        }
    }
    private func save() {
        guard appearanceRaw == expectedRaw, !busy else { error = "Оформление изменилось. Откройте редактор заново."; return }
        do {
            var preferences = try TelegramAppearancePreferences.decode(expectedRaw)
            if mode == "image", let selectedData { preferences.wallpaper = .image(try TelegramWallpaperFiles.install(selectedData)) }
            else { preferences.wallpaper = draft }
            appearanceRaw = try preferences.encoded(); dismiss()
        } catch { self.error = "Не удалось сохранить фон. Проверьте выбранное изображение и локальную папку приложения." }
    }
}
