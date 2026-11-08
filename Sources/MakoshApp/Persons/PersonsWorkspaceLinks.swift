import Foundation
import MakoshCore
import MakoshMail
import MakoshPersons
import MakoshTeams
import MakoshTelegram
import MakoshWhatsApp
import SwiftUI

/// Feeds the collector from what the channels already show: new letters, the Telegram
/// account's contacts and dialog partners, WhatsApp personal chats, Teams people. It also
/// hands the Telegram engine to the Persons host and walks the cached mail history once.
struct PersonsWorkspaceLinks: ViewModifier {
    @ObservedObject var host: PersonsHost
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var mail: MailWorkspaceModel
    @ObservedObject var telegram: TelegramModel
    @ObservedObject var whatsapp: WhatsAppWorkspaceModel
    @ObservedObject var teams: TeamsWorkspaceModel
    var enabled = true

    func body(content: Content) -> some View {
        content
            .onChange(of: host.model == nil) { _, missing in
                guard enabled, !missing else { return }
                host.telegramBridge = TelegramContactsBridgeAdapter { [weak telegram] in telegram?.contactsProvider() }
                Task { await collectLetters(mail.letters) }
                Task { await historyPass() }
                Task { await collectTelegram() }
            }
            .onChange(of: mail.letters) { _, letters in
                guard enabled else { return }
                Task { await collectLetters(letters) }
            }
            .onChange(of: telegram.chats) { _, _ in
                guard enabled else { return }
                Task { await collectTelegram() }
            }
            .onChange(of: whatsapp.chats) { _, chats in
                guard enabled, let account = whatsapp.selectedAccountID else { return }
                Task { await collectWhatsApp(chats, accountID: account) }
            }
            .onChange(of: teams.messages.count) { _, _ in
                guard enabled else { return }
                Task { await collectTeams() }
            }
    }

    // MARK: Mail

    @MainActor private func collectLetters(_ letters: [MailLetter]) async {
        guard host.model != nil else { return }
        var observations: [PersonSourceObservation] = []
        var spam: [MailEvidence] = []
        for account in mail.accounts {
            guard await host.collectsConversations(kind: .mail, accountID: account.id) else { continue }
            await host.ensureChannelSource(kind: .mail, accountID: account.id, name: account.email)
            for letter in letters where letter.key.accountID == account.id && host.markLetterCollected(letter.id) {
                guard let facts = MailPersonSource.facts(letter, folders: mail.folders, account: account) else { continue }
                observations += MailCollectionRule.observations(facts)
                spam += MailCollectionRule.spamEvidence(facts)
            }
        }
        if !observations.isEmpty || !spam.isEmpty { await host.collect(observations, spam: spam) }
    }

    /// One forward pass over the cached letters of every folder, resumable by cursor.
    @MainActor private func historyPass() async {
        guard let repository = mail.letterRepository, let service = host.service else { return }
        for account in mail.accounts {
            guard await host.collectsConversations(kind: .mail, accountID: account.id) else { continue }
            let source = ImportSource(service: "mail", accountID: account.id)
            for folder in mail.folders where folder.accountID == account.id && [.inbox, .sent, .junk, .other].contains(folder.kind) {
                var cursor =
                    (try? await service.store.cursor(source: source, scope: folder.path))
                    ?? PersonCollectionCursor(source: source, scope: folder.path, value: nil)
                var after = cursor.value.flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
                var pages = 0
                while pages < 50 {
                    guard
                        let page = try? await repository.letters(
                            accountID: account.id, folder: folder.path, afterSequence: after, limit: 200),
                        !page.isEmpty
                    else { break }
                    var observations: [PersonSourceObservation] = []
                    var spam: [MailEvidence] = []
                    for letter in page {
                        _ = host.markLetterCollected(letter.id)
                        guard let facts = MailPersonSource.facts(letter, folders: mail.folders, account: account) else { continue }
                        observations += MailCollectionRule.observations(facts)
                        spam += MailCollectionRule.spamEvidence(facts)
                    }
                    await host.collect(observations, spam: spam)
                    after = page.last?.cacheSequence ?? after
                    cursor.value = Data(String(after).utf8)
                    cursor.updatedAt = Date()
                    try? await service.store.saveCursor(cursor)
                    pages += 1
                    if page.count < 200 { break }
                }
            }
        }
    }

    // MARK: Telegram

    @MainActor private func collectTelegram() async {
        guard host.model != nil, let provider = telegram.contactsProvider() else { return }
        let accountID = String(provider.accountID)
        guard await host.collectsConversations(kind: .telegram, accountID: accountID) else { return }
        await host.ensureChannelSource(kind: .telegram, accountID: accountID, name: "Telegram · " + accountID)
        let chatIDs = telegram.chats.map(\.id)
        guard let profiles = try? await provider.profiles(peerIDs: chatIDs) else { return }
        let observations = TelegramPersonSource.observations(profiles: profiles, evidence: .conversation)
        if !observations.isEmpty { await host.collect(observations) }
    }

    // MARK: WhatsApp and Teams

    @MainActor private func collectWhatsApp(_ chats: [WhatsAppChat], accountID: UUID) async {
        guard host.model != nil, await host.collectsConversations(kind: .whatsapp, accountID: accountID.uuidString) else { return }
        let name = whatsapp.accounts.first { $0.id == accountID }?.name ?? "WhatsApp"
        await host.ensureChannelSource(kind: .whatsapp, accountID: accountID.uuidString, name: name)
        let source = ImportSource(service: "whatsapp", accountID: accountID.uuidString)
        let observations = chats.compactMap(\.dossierPerson).map {
            PersonSourceObservation(source: source, person: $0, observedAt: Date(), evidence: .conversation)
        }
        if !observations.isEmpty { await host.collect(observations) }
    }

    @MainActor private func collectTeams() async {
        guard host.model != nil, let scope = teams.selectedScope else { return }
        let accountID = scope.accountID.uuidString
        guard await host.collectsConversations(kind: .teams, accountID: accountID) else { return }
        let name = teams.accounts.first { $0.id == scope.accountID }?.name ?? "Teams"
        await host.ensureChannelSource(kind: .teams, accountID: accountID, name: name)
        let source = ImportSource(service: "teams", accountID: accountID)
        var seen = Set<String>()
        var observations: [PersonSourceObservation] = []
        let people = teams.messages.compactMap(\.author) + teams.chats.flatMap { $0.members ?? [] }
        for person in people {
            guard let imported = person.dossierPerson, seen.insert(imported.externalID).inserted else { continue }
            observations.append(PersonSourceObservation(source: source, person: imported, observedAt: Date(), evidence: .conversation))
        }
        if !observations.isEmpty { await host.collect(observations) }
    }
}
