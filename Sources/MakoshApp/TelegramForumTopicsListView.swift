import SwiftUI
import AppKit
import MakoshTelegram

struct TelegramForumTopicsListView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject var topics: TelegramForumTopicsController

    var body: some View {
        List {
            Button(action: model.showForumAllMessages) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right").frame(width: 50, height: 50)
                        .foregroundStyle(.secondary)
                    Text("Все сообщения").font(.headline)
                    Spacer()
                    if model.selectedThreadID == nil { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }.frame(height: 70).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("telegram.forum.allMessages")
            ForEach(topics.snapshot?.topics.filter { !$0.isHidden } ?? []) { topic in
                Button { model.selectForumTopic(topic, contextID: model.messageActionContextID) } label: {
                    HStack(spacing: 10) {
                        TelegramForumTopicIcon(topic: topic,
                            descriptor: topic.iconFileID.flatMap { model.customEmojiDescriptors[$0] },
                            context: model.customEmojiPlaybackContext, color: iconColor(topic.iconColor))
                            .frame(width: 50)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text(topic.title).font(.headline).lineLimit(1)
                                if topic.isClosed { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                                if topic.isMuted { Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary) }
                                Spacer(minLength: 2)
                                if topic.pinnedIndex != nil { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                            }
                            HStack {
                                if let draft = topic.draft, !draft.text.isEmpty {
                                    Text("\(Text("Черновик: ").foregroundColor(.red))\(Text(draft.text).foregroundColor(.secondary))")
                                        .font(.callout).lineLimit(2)
                                } else {
                                    Text(topic.lastMessage?.text ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                if topic.unreadCount > 0 || topic.isMarkedUnread {
                                    Text(topic.unreadCount > 0 ? "\(topic.unreadCount)" : " ")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(topic.isMuted ? Color.secondary : Color.accentColor, in: Capsule())
                                }
                            }
                        }
                    }.frame(height: 70).frame(maxWidth: .infinity).contentShape(Rectangle())
                        .background(model.selectedThreadID == topic.threadID ? Color.accentColor.opacity(0.12) : .clear)
                }.buttonStyle(.plain).accessibilityIdentifier("telegram.forum.topic.\(topic.threadID)")
            }
            if topics.phase == .loading { ProgressView("Загрузка тем…") }
        }.listStyle(.inset).accessibilityIdentifier("telegram.forum.topics")
    }

    private func iconColor(_ value: Int32) -> Color {
        let rgb = UInt32(bitPattern: value)
        return rgb == 0 ? .accentColor : Color(red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

@MainActor private struct TelegramForumTopicIcon: View {
    let topic: TelegramForumTopic
    let descriptor: TelegramCustomEmojiDescriptor?
    let context: TelegramCustomEmojiPlaybackContext?
    let color: Color
    @StateObject private var playback = TelegramCustomEmojiPlaybackController()
    @State private var visible = false
    var body: some View {
        ZStack {
            Text(topic.threadID == 1 ? "#" : descriptor?.fallbackText ?? String(topic.title.prefix(1)).uppercased())
                .font(.title3.weight(.semibold)).foregroundStyle(.white).opacity(playback.frame == nil ? 1 : 0)
            if let frame = playback.frame, let image = image(frame) {
                Image(nsImage: image).renderingMode(descriptor?.isSingleColor == true ? .template : .original)
                    .resizable().aspectRatio(contentMode: .fit).frame(width: 30, height: 30).accessibilityHidden(true)
            }
        }.frame(width: 36, height: 36).background(color, in: RoundedRectangle(cornerRadius: 10))
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0; refresh() }
        .onChange(of: context?.id) { _, _ in refresh() }
        .onChange(of: descriptor) { _, _ in refresh() }
        .onDisappear { visible = false; playback.stop() }
    }
    private func refresh() {
        playback.bind(context: context)
        if visible, let descriptor { playback.play(descriptor: descriptor, width: 72, height: 72) }
        else { playback.stop() }
    }
    private func image(_ frame: TelegramCustomEmojiFrame) -> NSImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: .init(width: frame.width, height: frame.height))
    }
}
