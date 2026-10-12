import SwiftUI
import MakoshTelegram

struct TelegramVideoCoverPaintedImage: View {
    let preview: TelegramImagePreview
    let painting: TelegramUploadVideoCoverPainting
    var body: some View {
        ZStack {
            Image(preview.image, scale: 1, label: Text("Изображение для обложки")).resizable()
            Canvas { context, size in
                context.withCGContext { painting.draw(in: $0, imageSize: size) }
            }.allowsHitTesting(false)
        }.accessibilityHidden(true)
    }
}

struct TelegramVideoCoverPaintingView: View {
    let preview: TelegramImagePreview
    let transform: TelegramUploadVideoCoverTransform
    let save: (TelegramUploadVideoCoverPainting) -> Void
    let close: () -> Void
    @State private var painting: TelegramUploadVideoCoverPainting
    @State private var tool: TelegramUploadVideoCoverPainting.Tool = .draw
    @State private var drawing = false
    @State private var error: String?
    @AppStorage("telegram.coverPainter.colorLocation") private var colorLocation = Double.random(in: 0...1)
    @AppStorage("telegram.coverPainter.brushWeight") private var weight = 0.22
    init(preview: TelegramImagePreview, transform: TelegramUploadVideoCoverTransform,
         painting: TelegramUploadVideoCoverPainting, save: @escaping (TelegramUploadVideoCoverPainting) -> Void,
         close: @escaping () -> Void) {
        self.preview = preview; self.transform = transform; self.save = save; self.close = close
        _painting = State(initialValue: painting.editingCopy())
    }
    private var brush: TelegramUploadVideoCoverBrush { .init(colorLocation: colorLocation, weight: weight) }
    var body: some View {
        VStack(spacing: 20) {
            ZStack(alignment: .bottom) {
                TelegramVideoCoverDrawingCanvas(preview: preview, transform: transform, painting: $painting,
                    tool: tool, brush: brush, drawing: $drawing, error: $error)
                    .frame(height: 360).padding(.bottom, 60)
                TelegramVideoCoverBrushPicker(brush: Binding(get: { brush }, set: {
                    colorLocation = $0.colorLocation; weight = $0.weight
                })).frame(width: 348, height: 200)
            }.frame(height: 420)
            if let error { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("telegram.upload.videoCoverPainter.error") }
            HStack {
                Button("Отмена", action: close).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("telegram.upload.videoCoverPainter.cancel")
                Spacer()
                Button { painting.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command).disabled(!painting.canUndo)
                    .help("Отменить штрих (⌘Z)").accessibilityLabel("Отменить штрих")
                    .accessibilityIdentifier("telegram.upload.videoCoverPainter.undo")
                Button { painting.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!painting.canRedo)
                    .help("Вернуть штрих (⇧⌘Z)").accessibilityLabel("Вернуть штрих")
                    .accessibilityIdentifier("telegram.upload.videoCoverPainter.redo")
                Button { tool = tool == .draw ? .arrow : .draw } label: {
                    Image(systemName: tool == .arrow ? "arrow.up.right" : "pencil.tip")
                }.help("Кисть / стрелка (L); стрелка — A")
                    .tint(tool == .erase ? Color.secondary : Color.accentColor)
                    .accessibilityLabel("Кисть или стрелка")
                    .accessibilityValue(tool == .arrow ? "Стрелка" : tool == .draw ? "Кисть" : "Не выбрано")
                    .accessibilityIdentifier("telegram.upload.videoCoverPainter.draw")
                Button { tool = .erase } label: { Image(systemName: "eraser") }
                    .help("Ластик (E)")
                    .tint(tool == .erase ? Color.accentColor : Color.secondary)
                    .accessibilityLabel("Ластик").accessibilityValue(tool == .erase ? "Выбран" : "Не выбран")
                    .accessibilityIdentifier("telegram.upload.videoCoverPainter.erase")
                Spacer()
                Button("Готово") { save(painting); close() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("telegram.upload.videoCoverPainter.done")
            }.disabled(drawing)
        }.padding(20).frame(width: 600)
            .accessibilityElement(children: .contain).accessibilityIdentifier("telegram.upload.videoCoverPainter")
            .background(TelegramVideoCoverPaintingKeyboard { keyCode in
                guard !drawing, let next = tool.selectingShortcut(keyCode: keyCode) else { return false }
                tool = next; return true
            }.frame(width: 0, height: 0))
            .onAppear { colorLocation = brush.colorLocation }
            .interactiveDismissDisabled(drawing)
    }
}

private struct TelegramVideoCoverDrawingCanvas: View {
    let preview: TelegramImagePreview
    let transform: TelegramUploadVideoCoverTransform
    @Binding var painting: TelegramUploadVideoCoverPainting
    let tool: TelegramUploadVideoCoverPainting.Tool
    let brush: TelegramUploadVideoCoverBrush
    @Binding var drawing: Bool
    @Binding var error: String?
    @State private var active: ActiveStroke?
    private struct ActiveStroke {
        let tool: TelegramUploadVideoCoverPainting.Tool
        let brush: TelegramUploadVideoCoverBrush
        let canvasSize: CGSize
        var points: [CGPoint]
        func stroke() throws -> TelegramUploadVideoCoverPainting.Stroke {
            try .init(tool: tool, points: points, rgb: brush.rgb, width: brush.lineWidth, canvasSize: canvasSize)
        }
    }
    private var visiblePainting: TelegramUploadVideoCoverPainting {
        var result = painting
        if let active, let stroke = try? active.stroke() { result.append(stroke) }
        return result
    }
    var body: some View {
        GeometryReader { geometry in
            let original = CGSize(width: preview.image.width, height: preview.image.height)
            let size = transform.imageSize(original)
            let fitted = TelegramUploadVideoCoverCrop.fittedImageSize(size,
                in: CGSize(width: geometry.size.width - 8, height: geometry.size.height - 8))
            let originalFitted = transform.imageSize(fitted)
            ZStack {
                TelegramVideoCoverPaintedImage(preview: preview, painting: visiblePainting)
                    .frame(width: originalFitted.width, height: originalFitted.height)
                    .rotationEffect(.degrees(-90 * Double(transform.quarterTurns)))
                    .scaleEffect(x: transform.isHorizontallyFlipped ? -1 : 1, y: 1)
                Rectangle().fill(.clear).frame(width: fitted.width, height: fitted.height).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard fitted.width > 0, fitted.height > 0 else { return }
                        let point = transform.sourcePoint(from: CGPoint(x: value.location.x / fitted.width, y: value.location.y / fitted.height))
                        if active == nil {
                            active = ActiveStroke(tool: tool, brush: brush, canvasSize: transform.imageSize(fitted), points: [])
                            drawing = true; error = nil
                        }
                        active?.points.append(point)
                    }.onEnded { _ in
                        defer { active = nil; drawing = false }
                        guard let active else { return }
                        do { painting.append(try active.stroke()) }
                        catch { self.error = "Не удалось добавить штрих. Повторите рисование." }
                    })
                    .accessibilityLabel("Холст рисования на обложке")
                    .accessibilityValue("Штрихов: \(painting.strokes.count)")
                    .accessibilityIdentifier("telegram.upload.videoCoverPainter.canvas")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        }
    }
}

private struct TelegramVideoCoverBrushPicker: View {
    @Environment(\.displayScale) private var displayScale
    @Binding var brush: TelegramUploadVideoCoverBrush
    @State private var pressed = false
    @State private var pointerY: CGFloat = 200
    private func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    private var outlineOpacity: Double {
        let r = (brush.rgb >> 16) & 255, g = (brush.rgb >> 8) & 255, b = brush.rgb & 255
        let brightness = Double(b) / 255
        return r == g && g == b && brightness > 0.92 ? (brightness - 0.92) / 0.08 : 0
    }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let gesture = DragGesture(minimumDistance: 0, coordinateSpace: .named("telegram.coverPainter.picker"))
                .onChanged { value in pressed = true; pointerY = value.location.y; brush.updatePicker(point: value.location, size: size) }
                .onEnded { value in brush.updatePicker(point: value.location, size: size); pressed = false }
            let lift = min(200, max(0, size.height - pointerY - 24))
            let diameter = brush.knobDiameter(displayScale: displayScale, pressed: pressed)
            ZStack(alignment: .topLeading) {
                Capsule().fill(LinearGradient(stops: TelegramUploadVideoCoverBrush.stops.map {
                    .init(color: color($0.rgb), location: $0.location)
                }, startPoint: .leading, endPoint: .trailing))
                    .frame(width: size.width - 48, height: 20).position(x: size.width / 2, y: size.height - 14)
                    .gesture(gesture)
                Circle().fill(.white).frame(width: pressed ? 48 : 24, height: pressed ? 48 : 24)
                    .overlay(Circle().fill(color(brush.rgb))
                        .overlay(Circle().stroke(Color(white: 0.88).opacity(outlineOpacity), lineWidth: 1).padding(1))
                        .frame(width: diameter, height: diameter))
                    .position(x: CGFloat(brush.colorLocation) * (size.width - 48) + 24,
                        y: pressed ? max(24, size.height - 74 - lift) : size.height - 14)
                    .gesture(gesture)
            }.coordinateSpace(name: "telegram.coverPainter.picker")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Цвет и толщина кисти")
                .accessibilityValue("#\(String(format: "%06X", brush.rgb)), \(Int(brush.lineWidth)) пт")
                .accessibilityHint("Двигайте по палитре для выбора цвета; тяните вверх для увеличения толщины.")
                .accessibilityIdentifier("telegram.upload.videoCoverPainter.palette")
                .accessibilityAdjustableAction { direction in
                    let next = brush.colorLocation + (direction == .increment ? 0.02 : -0.02)
                    brush = .init(colorLocation: next, weight: brush.weight)
                }
        }
    }
}
