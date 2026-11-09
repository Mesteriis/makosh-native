import Foundation
import MakoshCore

/// The isolated QA world for «Персоны»: a Yandex source book with two cards, a Google recipient,
/// a synthetic Telegram that needs a phone and a synthetic macOS book; three inbound letters from
/// one domain, one junk letter, a Telegram contact that merges by phone, a flagged person without
/// a phone, a role-address pair and one deleted person. Everything lives in memory and one
/// `qa_persons_` schema.
public enum PersonsSyntheticSeed {
    public static let yandex = "yandex"
    public static let google = "google"
    public static let telegram = "telegram"
    public static let mac = "mac"
    public static let mailAccount = "qa-mail"
    static let ownAddress = "qa@makosh.test"
    static let observedAt = Date(timeIntervalSince1970: 1_793_000_000)

    /// Synthetic books by account id; the same instances serve the adapter factory and the seed.
    public static func books() -> [String: PersonSyntheticBook] {
        [
            yandex: PersonSyntheticBook(cards: [
                card("anna", "Анна Сидорова", phone: "+7 916 100-00-01", emails: ["anna@sidorov.ru", "info@sidorov.ru"]),
                card("boris", "Борис Сидоров", phone: "+7 916 100-00-02", emails: ["boris@sidorov.ru", "info@sidorov.ru"]),
            ]),
            google: PersonSyntheticBook(),
            telegram: PersonSyntheticBook(
                capabilities: .init(acceptsOrganizations: false, requiresPhoneOrPeer: true, supportsMarker: false)),
            mac: PersonSyntheticBook(),
        ]
    }

    static func card(_ id: String, _ name: String, phone: String, emails: [String]) -> RemoteCard {
        RemoteCard(
            externalID: id, etag: "qa-\(id)", makoshID: nil,
            imported: ImportedPerson(externalID: id, displayName: name, phones: [phone], emails: emails), kind: .person)
    }

    /// Idempotent: a schema that already holds the Yandex book is left as it is.
    public static func seed(service: PersonsService, persons: PersonStore, books: [String: PersonSyntheticBook]) async throws {
        let existing = try await service.snapshot().books
        guard !existing.contains(where: { $0.kind == .synthetic && $0.accountID == yandex }) else { return }
        let source = try await service.connectSynthetic(
            name: "Яндекс · синтетический CardDAV", accountID: yandex, isAddressBookSource: true)
        let recipients = [
            try await service.connectSynthetic(name: "Google · синтетический", accountID: google),
            try await service.connectSynthetic(name: "Telegram · синтетический", accountID: telegram),
            try await service.connectSynthetic(name: "Контакты macOS · синтетические", accountID: mac),
        ]
        for book in recipients {
            try await service.setBookOptions(
                id: book.id, readBook: nil, isAddressBookSource: nil, acceptsAddressBook: true, collectConversations: nil)
        }
        _ = try await service.ensureChannelSource(kind: .mail, accountID: mailAccount, name: ownAddress)
        // The first Google write drops its connection after applying, and the book cannot be reached for the
        // check that would settle it: one attempt stays unknown until «Отказаться».
        await books[google]?.failNext(.unknownOutcome(stage: "create"))
        await books[google]?.failFind(.unreachable)
        _ = try await service.readBook(id: source.id)

        var observations: [PersonSourceObservation] = []
        for (address, name) in [
            ("anna@sidorov.ru", "Анна Сидорова"), ("boris@sidorov.ru", "Борис Сидоров"), ("viktor@sidorov.ru", "Виктор Сидоров"),
        ] {
            observations += MailCollectionRule.observations(letter(from: address, name: name, folder: .inbox))
        }
        let spam = MailCollectionRule.spamEvidence(letter(from: "spam@evil.test", name: "Спам", folder: .junk))
        try await service.collect(observations, spam: spam)

        // A Telegram contact with Anna's phone: one automatic merge.
        try await service.collect([
            PersonSourceObservation(
                source: ImportSource(service: "telegram", accountID: "100"),
                person: ImportedPerson(externalID: "501", displayName: "Анна", phones: ["+7 916 100-00-01"], usernames: ["anna"]),
                observedAt: observedAt, evidence: .conversation)
        ])

        // Viktor is flagged by hand but has no phone: Telegram cannot take him.
        let viktor = ServiceIdentity(service: "mail", accountID: mailAccount, externalID: "viktor@sidorov.ru")
        if let person = try persons.personsOwning(viktor).first { try persons.setAddressBook(personID: person.id, true, origin: .user) }
        // One person nobody needs any more waits in «Удалённые».
        let gone = try persons.createPerson(draft: PersonDraft(displayName: "Удалённая Персона", emails: ["gone@old.test"]))
        try persons.deletePerson(id: gone)
        await service.requestWritePass()
    }

    static func letter(from address: String, name: String, folder: MailFolderRole) -> MailLetterFacts {
        MailLetterFacts(
            accountID: mailAccount, folder: folder, from: MailParticipant(address: address, name: name),
            to: [MailParticipant(address: ownAddress, name: "")], cc: [], bcc: [], ownAddresses: [ownAddress], hasListHeaders: false,
            precedenceBulk: false, autoSubmitted: false, markedSpam: folder == .junk, observedAt: observedAt)
    }
}
