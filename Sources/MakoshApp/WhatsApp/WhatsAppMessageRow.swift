import MakoshWhatsApp
// Layout adapted from WhatsApp Zen MainView.swift / Components.swift (MIT).
// See LICENSES/WhatsApp-Zen-MIT.txt and docs/reference-interface.md.
import SwiftUI

struct WhatsAppMessageRow: View {
    @Environment(\.colorScheme) private var scheme
    @State private var renderedMessage: WhatsAppMessage?
    @State private var rendered: WhatsAppMessagePresentation?
    let message: WhatsAppMessage
    var senderTitle: String? = nil
    var open: () -> Void = {}
    var vote: (String) -> Void = { _ in }
    private var presentation: WhatsAppMessagePresentation? {
        renderedMessage == message ? rendered : nil
    }
    private var bodyText: String? {
        if message.kind == "contact" || message.kind == "poll" { return presentation?.bodyText }
        return message.text.isEmpty ? nil : message.text
    }
    private func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255)
    }
    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 50) }
            WhatsAppCappedWidth(max: 520) {
                WhatsAppBubbleStack(spacing: 5) {
                    if let senderTitle {
                        Text(senderTitle).font(.caption.weight(.semibold)).foregroundStyle(WorkspaceStyle.accent)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let quote = message.details?.quotedText {
                        Label(quote, systemImage: "arrowshape.turn.up.left").font(.caption).lineLimit(3)
                            .padding(7).background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if ["image", "video", "audio", "sticker", "document"].contains(message.kind) {
                        Button(action: open) {
                            Label(
                                message.details?.name ?? mediaName(message.kind),
                                systemImage: message.kind == "audio" ? "play.circle" : "paperclip")
                        }.buttonStyle(WorkspaceButtonStyle())
                    }
                    if message.kind == "location", let lat = message.details?.latitude,
                        let lon = message.details?.longitude,
                        let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)")
                    {
                        Link(destination: url) {
                            Label("Геопозиция · \(lat), \(lon)", systemImage: "mappin.and.ellipse")
                        }
                    }
                    if message.kind == "contact" {
                        if let contact = presentation?.contact {
                            WhatsAppContactCard(contact: contact, rawSource: message.details?.contactVcard)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if message.kind == "poll" {
                        Text(message.details?.pollName ?? "Опрос").font(.headline)
                        ForEach(presentation?.pollOptions ?? []) { option in
                            Button(
                                "\(option.label) · \(message.details?.pollVotes?.filter{$0.options.contains(option.label)}.count ?? 0)"
                            ) { vote(option.label) }.buttonStyle(WorkspaceButtonStyle())
                        }
                    }
                    if let reactions = message.details?.reactions, !reactions.isEmpty {
                        Text(reactions.map(\.text).joined(separator: " ")).font(.callout)
                    }
                    if let bodyText {
                        Text(bodyText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if message.deleted {
                            Label("Удалено в WhatsApp · сохранено", systemImage: "archivebox")
                        } else if message.edited {
                            Text("изменено")
                        }
                        Spacer(minLength: 12)
                        if message.details?.starred == true { Image(systemName: "star.fill") }
                        if message.details?.pinned == true { Image(systemName: "pin.fill") }
                        if let rejection = message.details?.rejection {
                            Text("Отклонено сервером · \(rejection.code)").foregroundStyle(.red)
                        } else if message.outgoing {
                            Text(
                                (message.delivery ?? 0) >= 3
                                    ? "✓✓" : message.delivery == 2 ? "✓✓" : message.delivery == 1 ? "✓" : "◷"
                            ).foregroundStyle(
                                (message.delivery ?? 0) >= 3 ? Color.cyan : Color.white.opacity(0.78)
                            ).help(
                                (message.delivery ?? 0) >= 3
                                    ? "Прочитано"
                                    : message.delivery == 2
                                        ? "Доставлено" : message.delivery == 1 ? "Принято сервером" : "Передано ядру")
                        }
                        Text(Date(timeIntervalSince1970: TimeInterval(message.timestamp)), style: .time)
                    }.font(.caption2).foregroundStyle(
                        message.outgoing ? Color.white.opacity(0.78) : Color.secondary)
                }.padding(.horizontal, 11).padding(.vertical, 7)
                    .foregroundStyle(message.outgoing ? Color.white : Color.primary)
                    .background(
                        message.outgoing
                            ? WorkspaceStyle.outgoing
                            : WorkspaceStyle.surface,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 18, bottomLeadingRadius: message.outgoing ? 18 : 5,
                            bottomTrailingRadius: message.outgoing ? 5 : 18, topTrailingRadius: 18))
            }
            if !message.outgoing { Spacer(minLength: 50) }
        }.accessibilityIdentifier("whatsapp.message.\(message.stanza)")
            .task(id: message) {
                guard message.kind == "contact" || message.kind == "poll" else { return }
                guard let value = try? await WhatsAppMessagePresentation.load(message), !Task.isCancelled else { return }
                rendered = value
                renderedMessage = message
            }
    }
}
private func mediaName(_ kind: String) -> String {
    switch kind {
    case "image": "Фото"
    case "video": "Видео"
    case "audio": "Аудио"
    case "sticker": "Стикер"
    default: "Документ"
    }
}
// Adapted from Zen CappedWidth and BubbleStack. Cap intrinsic width rather than
// expanding the bubble; timestamps must not stretch short messages to a card.
private struct WhatsAppCappedWidth: Layout {
    let max: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(
            .init(width: min(proposal.width ?? max, max), height: proposal.height)) ?? .zero
    }
    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin, proposal: .init(width: bounds.width, height: bounds.height))
    }
}
private struct WhatsAppBubbleStack: Layout {
    var spacing: CGFloat = 5
    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return min(ideal, proposal.width ?? ideal)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = width(proposal, subviews)
        return .init(
            width: w,
            height: subviews.map { $0.sizeThatFits(.init(width: w, height: nil)).height }.reduce(0, +)
                + spacing * CGFloat(max(0, subviews.count - 1)))
    }
    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for view in subviews {
            let fit = ProposedViewSize(width: bounds.width, height: nil)
            view.place(at: .init(x: bounds.minX, y: y), anchor: .topLeading, proposal: fit)
            y += view.sizeThatFits(fit).height + spacing
        }
    }
}
