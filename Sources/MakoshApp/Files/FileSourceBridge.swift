import Foundation
import MakoshCore
import MakoshFiles
import MakoshMail
import MakoshTeams
import MakoshTelegram
import MakoshWhatsApp

/// Titles for catalogue rows from the sections that know the chat or letter.
/// Lives on the main actor like the models it reads; nothing is retained strongly.
@MainActor final class FileSourceBridge: FileSourceResolving {
    private weak var telegram: TelegramModel?
    private weak var whatsapp: WhatsAppWorkspaceModel?
    private weak var mail: MailWorkspaceModel?
    private weak var teams: TeamsWorkspaceModel?

    init(telegram: TelegramModel, whatsapp: WhatsAppWorkspaceModel, mail: MailWorkspaceModel, teams: TeamsWorkspaceModel) {
        self.telegram = telegram
        self.whatsapp = whatsapp
        self.mail = mail
        self.teams = teams
    }

    func sourceTitle(for identity: MessageArchiveIdentity) async -> String? { title(identity) }

    private func title(_ identity: MessageArchiveIdentity) -> String? {
        switch identity.service {
        case "telegram":
            guard let telegram, let account = telegram.aiContextAccountID, String(account) == identity.accountID,
                let chat = Int64(identity.conversationID)
            else { return nil }
            return telegram.aiContextChats.first { $0.id == chat }?.title
        case "whatsapp":
            guard let whatsapp, whatsapp.selectedAccountID?.uuidString == identity.accountID else { return nil }
            return whatsapp.chats.first { $0.id == identity.conversationID }?.name
        case "mail":
            guard let mail, let letter = mail.letters.first(where: { $0.key.archiveIdentity == identity }) else { return nil }
            let sender = letter.senderName.isEmpty ? letter.sender : letter.senderName
            let subject = letter.subject.isEmpty ? "(без темы)" : letter.subject
            return sender.isEmpty ? subject : "\(subject) · \(sender)"
        case "teams":
            guard let teams else { return nil }
            return teams.chats.first {
                $0.scope.accountID.uuidString == identity.accountID && $0.scope.archiveConversationID == identity.conversationID
            }?.displayName
        default: return nil
        }
    }
}
