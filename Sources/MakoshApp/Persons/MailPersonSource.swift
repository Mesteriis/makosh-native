import Foundation
import MakoshCore
import MakoshMail
import MakoshPersons
import MakoshTelegram

/// What the collector needs to know about a letter, taken from the cached header only.
enum MailPersonSource {
    static func facts(_ letter: MailLetter, folders: [MailFolder], account: MailAccount) -> MailLetterFacts? {
        guard letter.key.accountID == account.id else { return nil }
        let folder = folders.first { $0.accountID == account.id && $0.path == letter.key.folder }
        let role: MailFolderRole =
            switch folder?.kind {
            case .inbox?: .inbox
            case .sent?: .sent
            case .junk?: .junk
            case .trash?: .trash
            default: letter.key.folder.uppercased() == "INBOX" ? .inbox : .other
            }
        let sender = letter.sender.trimmingCharacters(in: .whitespaces)
        return MailLetterFacts(
            accountID: account.id, folder: role, from: sender.isEmpty ? nil : MailParticipant(address: sender, name: letter.senderName),
            to: participants(letter.recipient), cc: participants(letter.cc ?? ""), bcc: participants(letter.bcc ?? ""),
            ownAddresses: [account.email.lowercased()], hasListHeaders: letter.listHeaders ?? false,
            precedenceBulk: letter.precedenceBulk ?? false, autoSubmitted: letter.autoSubmitted ?? false, markedSpam: role == .junk,
            observedAt: letter.date)
    }

    /// `Name <addr>, addr2` → participants; the cached header keeps addresses only, so names are empty.
    static func participants(_ list: String) -> [MailParticipant] {
        list.split(separator: ",").compactMap { piece in
            let text = piece.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
                let address = String(text[text.index(after: open)..<close])
                let name = text[..<open].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return MailParticipant(address: address, name: name)
            }
            return MailParticipant(address: text, name: "")
        }
    }
}

/// Telegram profiles as observations: people only, never bots, groups or accounts Telegram warns about.
enum TelegramPersonSource {
    static func observations(profiles: [TelegramContactProfile], evidence: PersonSourceEvidence) -> [PersonSourceObservation] {
        profiles.compactMap { profile in
            guard profile.isPerson, !profile.isScam, !profile.isFake else { return nil }
            var imported = profile.dossierImport
            if let username = profile.username, !username.isEmpty { imported.usernames = [username] }
            return PersonSourceObservation(
                source: ImportSource(service: profile.dossierIdentity.service, accountID: profile.dossierIdentity.accountID),
                person: imported,
                observedAt: profile.observedAt, evidence: evidence)
        }
    }
}
