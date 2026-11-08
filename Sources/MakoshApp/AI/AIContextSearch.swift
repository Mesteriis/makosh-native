import Combine
import Foundation
import MakoshAI
import MakoshCore
import MakoshFiles
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
    private let contacts: () -> [Person]
    static let limit = 30
    /// Files of the archive and Paperless; their late answers re-rank the list.
    private var files: FilePickerSearch?
    private var filesObservation: AnyCancellable?
    private var query = ""

    func attach(files: FilePickerSearch, refreshCatalogue: @escaping @MainActor () async -> Void = {}) {
        self.files = files
        // The catalogue fills when the Files section opens; "+" must not wait for that.
        Task {
            await refreshCatalogue()
            files.update(query: self.query)
        }
        filesObservation = files.$results.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.suggestions = AIContextRanking.rank(self.candidates(), query: self.query, limit: Self.limit)
        }
    }

    init(telegram: TelegramModel, whatsapp: WhatsAppWorkspaceModel, mail: MailWorkspaceModel, contacts: @escaping () -> [Person]) {
        self.telegram = telegram
        self.whatsapp = whatsapp
        self.mail = mail
        self.contacts = contacts
    }

    func update(query: String) {
        self.query = query
        files?.update(query: query)
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
        for pick in files?.results ?? [] {
            switch pick.kind {
            case .archive(let item):
                result.append(
                    .init(card: .file(source: .archive(recordID: item.id), title: item.name, pages: nil), subtitle: pick.subtitle))
            case .paperless(let connectionID, let document):
                result.append(
                    .init(
                        card: .file(
                            source: .paperless(connectionID: connectionID, documentID: document.id), title: document.title, pages: nil),
                        subtitle: pick.subtitle))
            }
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
