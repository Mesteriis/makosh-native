import MakoshWhatsApp
import SwiftUI

/// Native Zen PhotoSendSheet layout; state/persistence belong to the conductor.
struct WhatsAppPhotoEditorView: View {
  @ObservedObject var model: WhatsAppPhotoEditorModel
  @Binding var caption: String
  @Binding var mode: WhatsAppPhotoMode
  let cancel: () -> Void, send: () -> Void
  @State private var tool: WhatsAppPhotoMark?
  @State private var colorIndex = 0
  @State private var points: [WhatsAppPhotoPoint] = []
  @State private var cropping = false
  @State private var crop = WhatsAppPhotoRect(x: 0, y: 0, width: 1, height: 1)
  private static let palette: [(String, Color, WhatsAppPhotoRGBA)] = [
    ("Красный", .red, .init(r: 1, g: 0, b: 0, a: 1)),
    ("Жёлтый", .yellow, .init(r: 1, g: 1, b: 0, a: 1)),
    ("Зелёный", .green, .init(r: 0, g: 0.75, b: 0, a: 1)),
    ("Синий", .blue, .init(r: 0, g: 0.4, b: 1, a: 1)),
    ("Белый", .white, .init(r: 1, g: 1, b: 1, a: 1)),
    ("Чёрный", .black, .init(r: 0, g: 0, b: 0, a: 1)),
  ]
  var body: some View {
    VStack(spacing: 12) {
      toolbar
      canvas
      if model.drafts.count > 1 { strip }
      if let error = model.error {
        Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
      }
      HStack(spacing: 8) {
        TextField("Добавить подпись", text: $caption).textFieldStyle(.roundedBorder)
          .onSubmit { if !model.busy { send() } }.accessibilityIdentifier("whatsapp.photo.caption")
        Toggle("HD", isOn: Binding(get: { mode == .hd }, set: { mode = $0 ? .hd : .standard }))
          .toggleStyle(.button).help("1600 пикселей · HD до 4096, без увеличения исходника")
          .accessibilityIdentifier("whatsapp.photo.hd").disabled(model.busy)
        Button("Отмена", action: cancel).keyboardShortcut(.cancelAction)
        Button(
          model.drafts.count > 1 ? "Отправить \(model.drafts.count)" : "Отправить", action: send
        )
        .buttonStyle(.borderedProminent).tint(.green).keyboardShortcut(.defaultAction)
        .disabled(model.busy || model.drafts.isEmpty || model.image == nil)
        .accessibilityIdentifier("whatsapp.photo.send")
      }
    }.padding(16).frame(width: 692).accessibilityIdentifier("whatsapp.photo.editor")
      .onChange(of: model.selectedID) { _, _ in
        points = []
        cropping = false
      }
  }
  private var toolbar: some View {
    HStack(spacing: 6) {
      toolButton(.pen, "pencil.tip", "Рисовать")
      toolButton(.arrow, "arrow.up.right", "Стрелка")
      toolButton(.rect, "rectangle", "Прямоугольник")
      Divider().frame(height: 18)
      ForEach(Self.palette.indices, id: \.self) { i in
        Button {
          colorIndex = i
        } label: {
          Circle().fill(Self.palette[i].1).frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.secondary, lineWidth: 0.5))
            .overlay(
              Circle().strokeBorder(.primary, lineWidth: colorIndex == i ? 2 : 0).padding(-3))
        }.buttonStyle(.plain).accessibilityLabel(Self.palette[i].0)
      }
      Divider().frame(height: 18).padding(.leading, 4)
      if cropping {
        Button("Применить") {
          let value = crop
          cropping = false
          Task { await model.apply(.crop(value)) }
        }.labelStyle(.titleOnly)
        Button("Отмена") { cropping = false }.labelStyle(.titleOnly)
      } else {
        Button("Кадрировать", systemImage: "crop") {
          tool = nil
          crop = .init(x: 0, y: 0, width: 1, height: 1)
          cropping = true
        }
        .help("Кадрировать").accessibilityIdentifier("whatsapp.photo.crop")
        Button("Повернуть", systemImage: "rotate.right") { Task { await model.apply(.rotate90) } }
          .help("Повернуть").accessibilityIdentifier("whatsapp.photo.rotate")
      }
      Spacer()
      Button("Отменить правку", systemImage: "arrow.uturn.backward") { Task { await model.undo() } }
        .keyboardShortcut("z").disabled(model.selectedDraft?.recipe.operations.isEmpty != false)
        .help("Отменить правку").accessibilityIdentifier("whatsapp.photo.undo")
      Button("Сбросить") { Task { await model.reset() } }.labelStyle(.titleOnly)
        .accessibilityIdentifier("whatsapp.photo.reset")
    }.labelStyle(.iconOnly).buttonStyle(.bordered).disabled(model.busy)
  }
  private func toolButton(_ kind: WhatsAppPhotoMark, _ icon: String, _ label: String) -> some View {
    Button(label, systemImage: icon) {
      cropping = false
      tool = tool == kind ? nil : kind
    }
    .tint(tool == kind ? .green : .accentColor).help(label).accessibilityIdentifier(
      "whatsapp.photo.tool.\(kind.rawValue)")
  }
  private var strip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(model.drafts) { draft in
          ZStack(alignment: .topTrailing) {
            Button {
              Task { await model.select(draft.id) }
            } label: {
              Group {
                if let image = model.thumbnails[draft.id] {
                  Image(nsImage: image).resizable().scaledToFill()
                } else {
                  Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
              }.frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                  RoundedRectangle(cornerRadius: 8).strokeBorder(
                    .green, lineWidth: draft.id == model.selectedID ? 2.5 : 0))
            }.buttonStyle(.plain).accessibilityLabel("Выбрать фотографию")
            Button {
              Task { await model.remove(draft.id) }
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain).padding(2).accessibilityLabel("Убрать фотографию из черновика")
          }
        }
      }
    }.frame(height: 56).disabled(model.busy)
  }
  private var canvas: some View {
    ZStack {
      if let image = model.image, let preview = model.preview {
        WhatsAppPhotoCanvas(
          image: image, width: preview.width, height: preview.height, tool: tool,
          color: Self.palette[colorIndex].1,
          points: $points, cropping: cropping, crop: $crop
        ) { points in
          guard let tool else { return }
          let op = WhatsAppPhotoOperation.mark(tool, points, Self.palette[colorIndex].2, 0.006)
          self.points = []
          Task { await model.apply(op) }
        }.id(model.selectedID)
      } else if model.busy {
        ProgressView("Предпросмотр…")
      } else {
        ContentUnavailableView("Фото недоступно", systemImage: "photo")
      }
    }.frame(width: 660, height: 440).background(
      .black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)
    )
    .allowsHitTesting(!model.busy)
  }
}

private struct WhatsAppPhotoCanvas: View {
  let image: NSImage
  let width: Int, height: Int
  let tool: WhatsAppPhotoMark?, color: Color
  @Binding var points: [WhatsAppPhotoPoint]
  let cropping: Bool
  @Binding var crop: WhatsAppPhotoRect
  let complete: ([WhatsAppPhotoPoint]) -> Void
  @State private var cropStart: WhatsAppPhotoRect?
  private var fitted: CGSize {
    let scale = min(660 / Double(width), 440 / Double(height))
    return .init(width: Double(width) * scale, height: Double(height) * scale)
  }
  var body: some View {
    let size = fitted
    ZStack(alignment: .topLeading) {
      Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
      Canvas { ctx, _ in
        guard let first = points.first else { return }
        func px(_ p: WhatsAppPhotoPoint) -> CGPoint {
          .init(x: p.x * size.width, y: p.y * size.height)
        }
        let a = px(first)
        let b = px(points.last!)
        var path = Path()
        if tool == .rect {
          path.addRect(
            .init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
          )
        } else {
          path.move(to: a)
          for p in points.dropFirst() { path.addLine(to: px(p)) }
          if tool == .arrow {
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(max(size.width, size.height) * 0.024, 10)
            for delta in [-0.5, 0.5] {
              path.move(to: b)
              path.addLine(
                to: .init(x: b.x - head * cos(angle + delta), y: b.y - head * sin(angle + delta)))
            }
          }
        }
        ctx.stroke(
          path, with: .color(color),
          style: .init(
            lineWidth: 0.006 * max(size.width, size.height), lineCap: .round, lineJoin: .round))
      }.frame(width: size.width, height: size.height).contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { value in
            guard tool != nil else { return }
            let p = unit(value.location, size)
            if tool == .pen {
              if points.count < 32768 { points.append(p) }
            } else {
              points = points.first.map { [$0, p] } ?? [p, p]
            }
          }.onEnded { value in
            guard tool != nil else { return }
            if points.isEmpty { points = [unit(value.location, size)] }
            if tool != .pen, points.count == 1 { points.append(points[0]) }
            complete(points)
          }
        ).allowsHitTesting(!cropping)
      if cropping { cropOverlay(size) }
    }.frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 6))
  }
  private func unit(_ p: CGPoint, _ s: CGSize) -> WhatsAppPhotoPoint {
    .init(x: min(max(p.x / s.width, 0), 1), y: min(max(p.y / s.height, 0), 1))
  }
  private func cropOverlay(_ size: CGSize) -> some View {
    let box = CGRect(
      x: crop.x * size.width, y: crop.y * size.height, width: crop.width * size.width,
      height: crop.height * size.height)
    return ZStack(alignment: .topLeading) {
      Path {
        $0.addRect(.init(origin: .zero, size: size))
        $0.addRect(box)
      }.fill(.black.opacity(0.55), style: .init(eoFill: true)).allowsHitTesting(false)
      Rectangle().strokeBorder(.white, lineWidth: 1.5).frame(width: box.width, height: box.height)
        .contentShape(Rectangle()).offset(x: box.minX, y: box.minY)
        .gesture(
          cropGesture(size) { start, dx, dy in
            .init(
              x: min(max(start.x + dx, 0), 1 - start.width),
              y: min(max(start.y + dy, 0), 1 - start.height), width: start.width,
              height: start.height)
          })
      ForEach(0..<4, id: \.self) { corner in
        let left = corner % 2 == 0
        let top = corner < 2
        Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 1).position(
          x: left ? box.minX : box.maxX, y: top ? box.minY : box.maxY
        )
        .gesture(
          cropGesture(size) { start, dx, dy in
            var x = start.x
            var y = start.y
            var right = x + start.width
            var bottom = y + start.height
            if left {
              x = min(max(x + dx, 0), right - 0.08)
            } else {
              right = max(min(right + dx, 1), x + 0.08)
            }
            if top {
              y = min(max(y + dy, 0), bottom - 0.08)
            } else {
              bottom = max(min(bottom + dy, 1), y + 0.08)
            }
            return .init(x: x, y: y, width: right - x, height: bottom - y)
          })
      }
    }
  }
  private func cropGesture(
    _ size: CGSize, _ update: @escaping (WhatsAppPhotoRect, Double, Double) -> WhatsAppPhotoRect
  ) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
      if cropStart == nil { cropStart = crop }
      crop = update(
        cropStart!, value.translation.width / size.width, value.translation.height / size.height)
    }.onEnded { value in
      crop = update(
        cropStart ?? crop, value.translation.width / size.width,
        value.translation.height / size.height)
      cropStart = nil
    }
  }
}
