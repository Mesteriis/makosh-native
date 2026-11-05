import Foundation
import MakoshAI
import MakoshCore
import MakoshMail
import MakoshTelegram
import MakoshWhatsApp

/// Sources "+" and "@" offer: chats loaded in Telegram and the open WhatsApp
/// account, letters of the open mail folder, and contacts. Only titles are
/// read here; message text is read when a card is sent.
@MainActor final class AIContextSearch: ObservableObject {
    @Published private(set) var suggestions: [AIContextSuggestion] = []
    private let telegram: TelegramModel
    private let whatsapp: WhatsAppWorkspaceModel
    private let mail: MailWorkspaceModel
    private let contacts: () -> [Contact]
    static let limit = 30

    init(telegram: TelegramModel, whatsapp: WhatsAppWorkspaceModel, mail: MailWorkspaceModel, contacts: @escaping () -> [Contact]) {
        self.telegram = telegram
        self.whatsapp = whatsapp
        self.mail = mail
        self.contacts = contacts
    }

    func update(query: String) {
        suggestions = AIContextRanking.rank(candidates(), query: query, limit: Self.limit)
    }

    private func candidates() -> [AIContextSuggestion] {
        var result: [AIContextSuggestion] = []
        if let account = telegram.aiContextAccountID {
            for chat in telegram.aiContextChats {
                result.append(
                    .init(
                        card: .chat(
                            service: "telegram", accountID: String(account), chatID: String(chat.id), title: chat.title, range: .standard),
                        subtitle: "Telegram"))
            }
        }
        if let account = whatsapp.selectedAccountID {
            for chat in whatsapp.chats {
                result.append(
                    .init(
                        card: .chat(
                            service: "whatsapp", accountID: account.uuidString, chatID: chat.id, title: chat.name, range: .standard),
                        subtitle: "WhatsApp"))
            }
        }
        for contact in contacts() where contact.aiAccess != .forbidden {
            result.append(.init(card: .contact(id: contact.id, title: contact.displayName), subtitle: "Контакт"))
        }
        for letter in mail.letters {
            let sender = letter.senderName.isEmpty ? letter.sender : letter.senderName
            result.append(
                .init(
                    card: .letter(id: letter.id, title: letter.subject.isEmpty ? "(без темы)" : letter.subject),
                    subtitle: "Письмо · \(sender)"))
        }
        return result
    }
}
