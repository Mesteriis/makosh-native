import MakoshWhatsApp
import SwiftUI

struct WhatsAppGroupCallGrid: View {
    @ObservedObject var model: WhatsAppCallController
    let call: WhatsAppCallSnapshot
    @State private var invite = ""
    private var layout: WhatsAppGroupCallLayout {
        .init(
            participants: call.group?.participants ?? [], page: model.groupPage,
            pinned: model.pinnedParticipant)
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Участники: \(call.group?.participants.count ?? 0) / 32")
                Spacer()
                Button("Назад") { model.groupPage = max(0, model.groupPage - 1) }.disabled(
                    model.groupPage <= 0)
                Text("\(min(model.groupPage+1,layout.pageCount)) / \(layout.pageCount)")
                Button("Далее") { model.groupPage = min(layout.pageCount - 1, model.groupPage + 1) }
                    .disabled(model.groupPage + 1 >= layout.pageCount)
            }
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8
                ) {
                    ForEach(layout.visibleParticipants) { p in
                        VStack(spacing: 5) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.8))
                                if let image = model.groupImages.first(where: { $0.stream.sender == p.jid })?.image {
                                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                                } else {
                                    WhatsAppAvatarView(
                                        name: p.jid, group: false,
                                        scope: model.accountID.map { .init(accountID: $0, jid: p.jid) },
                                        worker: model.avatarWorker, cache: model.avatarCache)
                                }
                            }.aspectRatio(4 / 3, contentMode: .fit)
                            HStack {
                                Text(p.jid).font(.caption).lineLimit(1)
                                Spacer()
                                Button {
                                    model.pinnedParticipant = model.pinnedParticipant == p.jid ? nil : p.jid
                                } label: {
                                    Image(systemName: model.pinnedParticipant == p.jid ? "pin.fill" : "pin")
                                }.buttonStyle(.borderless).help("Закрепить участника")
                            }
                            HStack {
                                Text(
                                    p.state == "connected"
                                        ? "В звонке" : p.state == "invited" ? "Приглашён" : "Ожидание"
                                ).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if p.state != "connected" {
                                    Button("Позвонить") { Task { await model.invite(jid: p.jid, ringOnly: true) } }
                                        .font(.caption2).disabled(call.state != "active")
                                }
                            }
                        }
                    }
                }
            }.frame(minHeight: 160, maxHeight: .infinity)
            if let local = model.images.local {
                HStack {
                    Text("Вы")
                    Image(decorative: local, scale: 1).resizable().scaledToFit().frame(width: 100, height: 75)
                    Spacer()
                }
            }
            HStack {
                TextField("JID нового участника", text: $invite).textFieldStyle(.roundedBorder)
                Button("Пригласить") {
                    let value = invite
                    Task { await model.invite(jid: value, ringOnly: false) }
                }.disabled(
                    !WhatsAppGroupCallTargets.isUser(invite) || call.state != "active"
                        || (call.group?.participants.count ?? 0) >= 32)
            }
        }.frame(maxHeight: .infinity).accessibilityIdentifier("whatsapp.group.grid")
    }
}
