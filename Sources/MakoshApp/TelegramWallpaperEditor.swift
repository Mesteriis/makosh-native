import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MakoshTelegram

struct TelegramWallpaperBackground: View {
    let wallpaper: TelegramLocalWallpaper
    let fallback: Color
    var preparedPattern: Data? = nil
    @State private var image: CGImage?
    private var renderID: String { (try? String(data:JSONEncoder().encode(wallpaper),encoding:.utf8)) ?? "" }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image { Image(decorative:image,scale:1).resizable().scaledToFill().frame(width:geometry.size.width,height:geometry.size.height).clipped() }
                else { fallback }
            }.task(id:renderID) {
                image = nil
                let wallpaper = wallpaper, mask = preparedPattern
                let loaded = await Task.detached(priority:.utility) { () -> CGImage? in
                    switch wallpaper {
                    case .automatic: return nil
                    case let .solid(color): return try? TelegramWallpaperRenderer.render(colors:.init(colors:[color]))
                    case let .gradient(a,b): return try? TelegramWallpaperRenderer.render(colors:.init(colors:[a,b],rotation:45))
                    case let .colors(value): return try? TelegramWallpaperRenderer.render(colors:value)
                    case let .pattern(value):
                        guard let bytes = mask ?? (try? TelegramWallpaperFiles.loadPattern(value.name)) else { return nil }
                        return try? TelegramWallpaperRenderer.render(colors:value.colors,pattern:bytes,intensity:value.intensity)
                    case let .image(name):
                        guard let data = try? TelegramWallpaperFiles.load(name),
                              let source = CGImageSourceCreateWithData(data as CFData,nil),
                              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                              let width = properties[kCGImagePropertyPixelWidth] as? Int,
                              let height = properties[kCGImagePropertyPixelHeight] as? Int,
                              (1...2560).contains(width),(1...2560).contains(height) else { return nil }
                        return CGImageSourceCreateImageAtIndex(source,0,nil)
                    }
                }.value
                guard !Task.isCancelled else { return }; image = loaded
            }
        }.accessibilityHidden(true)
    }
}
func telegramRGBColor(_ rgb: UInt32) -> Color {
    .init(red:Double((rgb >> 16) & 255)/255,green:Double((rgb >> 8) & 255)/255,blue:Double(rgb & 255)/255)
}
func telegramPaletteColor(_ palette:TelegramCloudPalette,_ field:String,_ rgb:UInt32) -> Color { Color(cgColor:palette.color(field,rgb:rgb)) }

struct TelegramWallpaperEditor: View {
    let expectedRaw: String
    @AppStorage(TelegramAppearancePreferences.preferenceKey) private var appearanceRaw = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode = "automatic"
    @State private var colors = TelegramWallpaperColors(colors:[0xdce8df,0xc6d5ed])
    @State private var originalName: String?
    @State private var patternName: String?
    @State private var selectedData: Data?
    @State private var selectedPattern: Data?
    @State private var intensity = 50.0
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
                        Text("По умолчанию").tag("automatic"); Text("Цвета и узор").tag("colors"); Text("Изображение").tag("image")
                    }.accessibilityIdentifier("telegram.wallpaper.mode")
                    if mode == "colors" {
                        ForEach(colors.colors.indices,id:\.self) { index in
                            HStack {
                                ColorPicker("Цвет \(index+1)",selection:color(index),supportsOpacity:false).accessibilityIdentifier("telegram.wallpaper.color.\(index)")
                                if colors.colors.count > 1 { Button { colors.colors.remove(at:index); resetGeometry() } label:{ Image(systemName:"minus.circle") }.accessibilityLabel("Удалить цвет \(index+1)") }
                            }
                        }
                        if colors.colors.count < 4 { Button("Добавить цвет") { colors.colors.append(0xc6d5ed); resetGeometry() }.accessibilityIdentifier("telegram.wallpaper.addColor") }
                        if colors.colors.count == 2 {
                            Button("Повернуть на45°") { colors.rotation = (colors.rotation+45)%360 }.accessibilityIdentifier("telegram.wallpaper.rotate")
                        } else if colors.colors.count > 2 {
                            Button("Изменить расположение цветов") { withAnimation(reduceMotion ? nil : .easeInOut(duration:0.3)) { colors.phase = (colors.phase+1)%4 } }.accessibilityIdentifier("telegram.wallpaper.advance")
                        }
                        HStack {
                            Button("Выбрать узор…") { pick(pattern:true) }.disabled(busy).accessibilityIdentifier("telegram.wallpaper.pattern.pick")
                            if patternName != nil { Button("Без узора") { patternName = nil; selectedPattern = nil }.accessibilityIdentifier("telegram.wallpaper.pattern.none") }
                        }
                        if patternName != nil {
                            Slider(value:$intensity,in:-100...100,step:1) { Text("Интенсивность узора") }.accessibilityIdentifier("telegram.wallpaper.pattern.intensity")
                            Text("Интенсивность: \(Int(intensity))%").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if mode == "image" {
                        Button("Выбрать изображение…") { pick(pattern:false) }.disabled(busy).accessibilityIdentifier("telegram.wallpaper.pick")
                        Text("Статичное изображение до32МБ. Фон сохраняется локально без исходных метаданных.").font(.caption).foregroundStyle(.secondary)
                    }
                    if busy { ProgressView("Подготовка…") }
                }
                Section("Предпросмотр") {
                    VStack(alignment:.leading,spacing:12) {
                        Text("Привет! Как дела?").padding(10).background(.background,in:RoundedRectangle(cornerRadius:12))
                        HStack { Spacer(); Text("Всё хорошо!").padding(10).background(Color.accentColor.opacity(0.25),in:RoundedRectangle(cornerRadius:12)) }
                    }.padding().frame(height:190).background {
                        if mode == "image",let selectedData,let image = NSImage(data:selectedData) { Image(nsImage:image).resizable().scaledToFill().clipped() }
                        else { TelegramWallpaperBackground(wallpaper:draft,fallback:Color(nsColor:.windowBackgroundColor),preparedPattern:selectedPattern) }
                    }.clipped().accessibilityIdentifier("telegram.wallpaper.preview")
                }
                if appearanceRaw != expectedRaw { Text("Оформление изменено в другом окне. Закройте редактор и откройте его заново.").foregroundStyle(.red) }
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
        }.frame(width:520,height:680)
            .onAppear {
                guard let preferences = try? TelegramAppearancePreferences.decode(expectedRaw) else { error = "Настройки оформления повреждены."; return }
                switch preferences.wallpaper {
                case .automatic: mode = "automatic"
                case let .solid(value): mode = "colors"; colors = .init(colors:[value])
                case let .gradient(a,b): mode = "colors"; colors = .init(colors:[a,b],rotation:45)
                case let .colors(value): mode = "colors"; colors = value
                case let .pattern(value): mode = "colors"; colors = value.colors; patternName = value.name; intensity = Double(value.intensity)
                case let .image(name): mode = "image"; originalName = name
                }
            }.onDisappear { preparationID = UUID() }
    }
    private var draft: TelegramLocalWallpaper {
        switch mode {
        case "colors": if let patternName { return .pattern(.init(name:patternName,colors:colors,intensity:Int(intensity))) }; return .colors(colors)
        case "image": return originalName.map(TelegramLocalWallpaper.image) ?? .automatic
        default: return .automatic
        }
    }
    private func resetGeometry() { colors.rotation = 0; colors.phase = 0 }
    private func color(_ index:Int) -> Binding<Color> {
        .init(get:{ telegramRGBColor(colors.colors.indices.contains(index) ? colors.colors[index] : 0) },set:{ color in
            guard colors.colors.indices.contains(index),let value = NSColor(color).usingColorSpace(.deviceRGB) else { return }
            let components = [value.redComponent,value.greenComponent,value.blueComponent]
            guard components.allSatisfy(\.isFinite) else { return }
            let bytes = components.map { UInt32((min(1,max(0,$0)) * 255).rounded()) }
            colors.colors[index] = bytes[0]<<16 | bytes[1]<<8 | bytes[2]
        })
    }
    private func pick(pattern:Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = pattern ? [.png,.webP,.svg,.gzip] : [.image]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK,let url = panel.url else { return }
            let id = UUID(); preparationID = id; busy = true; error = nil
            let scoped = url.startAccessingSecurityScopedResource()
            Task { @MainActor in
                let result = await Task.detached(priority:.utility) { () -> Result<Data,Error> in
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return Result { let bytes = try TelegramWallpaperFiles.readSelection(url); return try pattern ? TelegramWallpaperPattern.prepare(bytes) : TelegramWallpaperImage.prepare(bytes) }
                }.value
                guard preparationID == id else { return }; busy = false
                switch result {
                case let .success(data):
                    if pattern { selectedPattern = data; patternName = UUID().uuidString.lowercased()+".png" } else { selectedData = data }
                case .failure: error = pattern ? "Не удалось подготовить узор. Поддерживаются статичные PNG/WebP и простые SVG, в том числе gzip, до2МБ." : "Не удалось подготовить изображение. Выберите статичный файл до32МБ."
                }
            }
        }
    }
    private func save() {
        guard appearanceRaw == expectedRaw,!busy else { error = "Оформление изменилось. Откройте редактор заново."; return }
        do {
            var preferences = try TelegramAppearancePreferences.decode(expectedRaw)
            if mode == "image",let selectedData { preferences.wallpaper = .image(try TelegramWallpaperFiles.install(selectedData)) }
            else if mode == "colors",let selectedPattern,patternName != nil { preferences.wallpaper = .pattern(.init(name:try TelegramWallpaperFiles.installPattern(selectedPattern),colors:colors,intensity:Int(intensity))) }
            else { preferences.wallpaper = draft }
            appearanceRaw = try preferences.encoded(); dismiss()
        } catch { self.error = "Не удалось сохранить фон. Проверьте выбранное изображение и локальную папку приложения." }
    }
}
