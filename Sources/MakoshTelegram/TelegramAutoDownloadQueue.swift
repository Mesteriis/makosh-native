import Foundation
import Combine

@MainActor final class TelegramAutoDownloadQueue {
    private let settings: TelegramAutoDownloadSettings
    private let media: TelegramMediaController
    private var subscriptions = Set<AnyCancellable>()
    private var evaluation: Task<Void, Never>?
    private var context: UUID?, accountID: Int64?
    private var active = false
    private var eligibility: @MainActor () -> Bool = { true }
    private var attachments: [TelegramAttachment] = []
    private var attempted = Set<String>()
    private var previousPreferences: TelegramAutoDownloadPreferences
    init(settings: TelegramAutoDownloadSettings, media: TelegramMediaController) {
        self.settings = settings; self.media = media; previousPreferences = settings.preferences; accountID = settings.accountID
        media.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        settings.objectWillChange.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
    }
    isolated deinit { evaluation?.cancel(); media.cancelAutomaticDownloads(except: []) }
    func archiveCapacityChanged() { schedule() }
    func replace(attachments: [TelegramAttachment], contextID: UUID, active: Bool,
        eligibility: @escaping @MainActor () -> Bool = { true }) {
        if context != contextID || accountID != settings.accountID {
            attempted = []; media.cancelAutomaticDownloads(except: [])
        }
        context = contextID; accountID = settings.accountID; self.active = active
        self.eligibility = eligibility
        self.attachments = Array(attachments.prefix(100))
        attempted.formIntersection(Set(self.attachments.map(\.id)))
        if !active { attempted = [] }
        schedule()
    }
    private func schedule() {
        evaluation?.cancel()
        evaluation = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.drain()
        }
    }
    private func drain() {
        let preferences = settings.preferences
        if accountID != settings.accountID {
            active = false; attachments = []; attempted = []; accountID = settings.accountID
        }
        if preferences != previousPreferences {
            previousPreferences = preferences; attempted = []; media.cancelAutomaticDownloads(except: [])
        }
        let eligible = active && settings.accountID != nil && settings.error == nil ? attachments.filter { attachment in
            TelegramDownloadPeer.allCases.contains { preferences.allows(attachment, peer: $0) }
        } : []
        media.cancelAutomaticDownloads(except: Set(eligible.map(\.id)))
        for attachment in eligible {
            guard media.automaticInFlightCount < 3 else { break }
            guard !attempted.contains(attachment.id) else { continue }
            let capturedContext = context, capturedAccount = accountID
            let started = media.startAutomatically(attachment, preferences: preferences) { [weak self] in
                guard let self else { return false }
                return self.active && self.context == capturedContext && self.accountID == capturedAccount &&
                    self.settings.accountID == capturedAccount && self.settings.error == nil &&
                    self.settings.preferences == preferences && self.attachments.contains(attachment) && self.eligibility()
            }
            if started { attempted.insert(attachment.id) }
        }
    }
}
