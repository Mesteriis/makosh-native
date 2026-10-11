import SwiftUI
import AppKit
import MakoshTelegram

struct TelegramAlbumHistoryRow<MenuContent: View>: View {
    let item: TelegramHistoryItem
    @ObservedObject var model: TelegramModel
    @ObservedObject var selection: TelegramMessageSelectionController
    @ObservedObject var media: TelegramMediaController
    @ObservedObject var actions: TelegramAttachmentActions
    @ObservedObject var playback: TelegramPlaybackController
    @ViewBuilder let menu: (TelegramMessage) -> MenuContent

    var body: some View {
        let context = model.messageActionContextID, window = model.historyWindowID
        let session = selection.session
        let sources = item.messages.compactMap { model.actionSource(for: $0) }
        let allSelected = sources.count == item.messages.count && sources.allSatisfy(selection.contains)
        let toggleGroup = {
            guard let window else { return }
            _ = model.toggleMessageGroupSelection(group: item, sessionID: session?.id, expectedRevision: session?.revision,
                contextID: context, windowID: window, extendingRange: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        }
        HStack(alignment: .center, spacing: 8) {
            if session != nil {
                Button(action: toggleGroup) {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(allSelected ? Color.accentColor : Color.secondary).frame(width: 24)
                }.buttonStyle(.plain).help("Выбрать или снять весь альбом")
                    .accessibilityLabel("Альбом, \(item.messages.count) сообщений")
                    .accessibilityValue(allSelected ? "Выбрано полностью" : "Не выбрано полностью")
                    .accessibilityIdentifier("telegram.selection.album." + item.id)
            }
            if item.messages.last?.isOutgoing == true { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 7) {
                if let first = item.messages.first {
                    if session != nil {
                        Button(action: toggleGroup) {
                            Text(first.author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel("Выбрать альбом, \(item.messages.count) сообщений")
                            .accessibilityIdentifier("telegram.album.author." + item.id)
                    } else {
                        Text(first.author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if item.isVisualAlbum {
                    if item.visualCaptionAboveMedia { caption(context: context, selecting: session != nil, toggle: toggleGroup) }
                    TelegramAlbumMosaicLayout(aspects: item.messages.map { $0.attachments[0].dimensions?.aspectRatio ?? 1 }) {
                        ForEach(item.messages) { message in
                            let source = model.actionSource(for: message)
                            let selected = source.map(selection.contains) ?? false
                            Group {
                                if let session, let window {
                                    Button {
                                        _ = model.toggleMessageSelection(messageID: message.id, sessionID: session.id,
                                            contextID: context, windowID: window,
                                            extendingRange: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                                    } label: {
                                        ZStack(alignment: .bottomTrailing) {
                                            tile(message, context: context).allowsHitTesting(false).accessibilityHidden(true)
                                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                                .font(.title2).foregroundStyle(selected ? Color.accentColor : Color.white)
                                                .shadow(radius: 2).padding(7).accessibilityHidden(true)
                                        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .disabled(!selected && (source.map { !TelegramComposerForwardSource(source: $0).isValid } ?? true))
                                        .accessibilityLabel(TelegramMessagePresentation.selectionLabel(for: message))
                                        .accessibilityValue(selected ? "Выбрано" : "Не выбрано")
                                        .accessibilityIdentifier("telegram.selection.message." + message.id)
                                        .contextMenu { menu(message) }
                                } else {
                                    tile(message, context: context)
                                }
                            }.background(TelegramHistoryReadRow(id: message.id, context: model.historyReadContext))
                                .id(message.id)
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 8))
                    if !item.visualCaptionAboveMedia { caption(context: context, selecting: session != nil, toggle: toggleGroup) }
                } else {
                    ForEach(item.messages) { message in
                        TelegramSelectableHistoryRow(selection: selection, message: message, source: model.actionSource(for: message)) {
                            if let session, let window {
                                _ = model.toggleMessageSelection(messageID: message.id, sessionID: session.id,
                                    contextID: context, windowID: window,
                                    extendingRange: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                            }
                        } content: {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(message.attachments) { attachment in
                                    TelegramAttachmentRow(attachment: attachment, contextID: context, hasCaption: !message.text.isEmpty,
                                        media: media, actions: actions, playback: playback) { menu(message) }
                                }
                                if !message.text.isEmpty {
                                    TelegramMessageTextView(value: message.formattedTextForDisplay, identity: context.uuidString + message.id,
                                        canCopy: message.actionMetadata?.canCopy == true) { menu(message) }
                                }
                            }.contextMenu { menu(message) }
                                .background(TelegramHistoryReadRow(id: message.id, context: model.historyReadContext))
                        }.id(message.id)
                    }
                }
                if let last = item.messages.last {
                    HStack {
                        Spacer(minLength: 0)
                        Button(action: toggleGroup) { TelegramMessageMetadataView(message: last) }.buttonStyle(.plain)
                            .help("Выбрать альбом").accessibilityLabel("Выбрать альбом, \(item.messages.count) сообщений")
                            .accessibilityIdentifier("telegram.album.select." + item.id)
                    }
                }
            }.frame(maxWidth: 420, alignment: .leading).padding(11)
                .background(item.messages.last?.isOutgoing == true ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12))
            if item.messages.last?.isOutgoing != true { Spacer(minLength: 44) }
        }.background {
            if session != nil {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: toggleGroup)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("telegram.album." + item.id)
    }

    @ViewBuilder private func caption(context: UUID, selecting: Bool, toggle: @escaping () -> Void) -> some View {
        if let message = item.visualCaption {
            if selecting {
                Button(action: toggle) {
                    TelegramMessageTextView(value: message.formattedTextForDisplay, identity: context.uuidString + message.id,
                        canCopy: message.actionMetadata?.canCopy == true) { menu(message) }
                        .allowsHitTesting(false).accessibilityHidden(true)
                }.buttonStyle(.plain).accessibilityLabel("Выбрать альбом, \(item.messages.count) сообщений")
                    .accessibilityIdentifier("telegram.album.caption." + item.id)
                    .contextMenu { menu(message) }
            } else {
                TelegramMessageTextView(value: message.formattedTextForDisplay, identity: context.uuidString + message.id,
                    canCopy: message.actionMetadata?.canCopy == true) { menu(message) }
            }
        }
    }

    private func tile(_ message: TelegramMessage, context: UUID) -> some View {
        TelegramVisualMediaView(attachment: message.attachments[0], contextID: context, media: media, actions: actions, playback: playback) {
            menu(message)
        }
    }
}

struct TelegramAlbumMosaicLayout: Layout {
    let aspects: [Double]
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(420, max(16, proposal.width ?? 360))
        let frames = TelegramAlbumMosaic.frames(aspects: aspects, width: width)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = TelegramAlbumMosaic.frames(aspects: aspects, width: bounds.width)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
