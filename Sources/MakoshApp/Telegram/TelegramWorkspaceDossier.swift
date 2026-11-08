import SwiftUI
import MakoshTelegram

struct TelegramWorkspaceDossier: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject var workspace: WorkspaceModel
    let close: () -> Void
    let open: (UUID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Досье собеседника").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 4)
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .accessibilityLabel("Закрыть досье").accessibilityIdentifier("telegram.dossier.close")
            }.padding(.horizontal, 18).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.contactProfileState {
                    case .idle: Text("Выберите диалог").foregroundStyle(.secondary)
                    case .loading: ProgressView("Загрузка…")
                    case .unavailable(let reason):
                        Text(reason).foregroundStyle(.secondary)
                        Button("Повторить", action: model.loadContactProfile)
                    case .ready(let profile):
                        if model.isCurrentContactProfile(profile, contextID: model.contactProfileContextID) {
                            HStack(spacing: 12) {
                                TelegramChatAvatar(title: profile.displayName, peerID: profile.peerID, store: model.avatars, size: 56)
                                Text(profile.displayName).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                            }
                            Label("Telegram", systemImage: "paperplane").foregroundStyle(WorkspaceStyle.accent)
                            if let username = profile.username, !username.isEmpty { Text("@\(username)").textSelection(.enabled) }
                            if let phone = profile.phone, !phone.isEmpty { Text(phone).textSelection(.enabled) }
                            if profile.isScam || profile.isFake {
                                Text("У аккаунта есть предупреждение Telegram.").foregroundStyle(.orange)
                            } else if let about = profile.about, !about.isEmpty {
                                Text(about).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            let owners = workspace.persons.filter { $0.identities.contains(profile.dossierIdentity) }
                            if owners.count == 1, let contact = owners.first {
                                if !contact.organization.isEmpty { Text(contact.organization).foregroundStyle(.secondary) }
                                Divider()
                                Text("Заметки").font(.caption).foregroundStyle(.secondary)
                                if contact.notes.isEmpty { Text("Пока нет заметок").font(.callout).foregroundStyle(.secondary) }
                                ForEach(contact.notes) { note in Text(note.text).font(.callout).textSelection(.enabled) }
                            }
                            Divider()
                            TelegramDossierLinkView(
                                workspace: workspace, telegram: model, profile: profile, contextID: model.contactProfileContextID,
                                openDossier: open)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        }.frame(width: 264).background { WorkspaceBackdrop(intensity: 0.4) }
            .accessibilityIdentifier("telegram.dossier")
    }
}
