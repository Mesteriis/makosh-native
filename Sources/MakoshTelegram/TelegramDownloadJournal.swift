import Foundation
import Combine

struct TelegramDownloadRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case pending, ready, cancelled, failed }
    var attachmentID: String
    var peerID: Int64
    var namespace: Int32
    var messageID: Int32
    var name: String
    var byteCount: Int64?
    var photo: Bool
    var state: State
    var isValid: Bool {
        peerID != 0 && namespace >= 0 && messageID > 0 &&
        attachmentID.hasPrefix("\(peerID):\(namespace):\(messageID):") && attachmentID.utf8.count <= 512 &&
        !attachmentID.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } &&
        !name.isEmpty && name.utf8.count <= 1024 && name == telegramAttachmentName(name) &&
        (byteCount.map { $0 >= 0 } ?? true)
    }
    var placeholder: TelegramAttachment {
        .init(id:attachmentID,kind:photo ? .photo : .file,name:name,byteCount:byteCount,mimeType:nil,hasPreview:false,canDownload:true)
    }
}

struct TelegramDownloadJournalSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var accountID: Int64
    var revision: UUID
    var records: [TelegramDownloadRecord]
    var isValid: Bool {
        version == 1 && accountID != 0 && records.count <= 1000 && records.allSatisfy(\.isValid) &&
        Set(records.map(\.attachmentID)).count == records.count
    }
    func encoded() throws -> Data {
        guard isValid else { throw TelegramDownloadJournalError.invalid }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2_097_152 else { throw TelegramDownloadJournalError.invalid }; return data
    }
    static func decode(_ data: Data, accountID: Int64) throws -> Self {
        guard !data.isEmpty, data.count <= 2_097_152 else { throw TelegramDownloadJournalError.invalid }
        let value = try JSONDecoder().decode(Self.self,from:data)
        guard value.accountID == accountID, value.isValid else { throw TelegramDownloadJournalError.invalid }; return value
    }
}

enum TelegramDownloadJournalError: Error { case invalid, unavailable, changed }
@MainActor protocol TelegramDownloadJournalRequest: AnyObject { func cancel() }
@MainActor protocol TelegramDownloadJournalRepository: AnyObject {
    var accountID: Int64 { get }
    func load(completion: @escaping @MainActor (Result<TelegramDownloadJournalSnapshot?,TelegramDownloadJournalError>) -> Void) -> any TelegramDownloadJournalRequest
    /// Writes run to completion on the bound account even when its UI disappears.
    func save(_ value: TelegramDownloadJournalSnapshot, expected: UUID?,
        completion: @escaping @MainActor (Result<Void,TelegramDownloadJournalError>) -> Void)
}

/// Serial CAS mutations preserve cancellation/finished cleanup and never publish
/// a durable acknowledgement before the encrypted Postbox transaction commits.
@MainActor final class TelegramDownloadJournal: ObservableObject {
    private enum Change { case upsert(TelegramDownloadRecord), remove(Set<String>) }
    private struct Mutation {
        let id = UUID()
        let change: Change
        let completion: @MainActor (Bool) -> Void
    }
    @Published private(set) var accountID: Int64?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    @Published private(set) var records: [TelegramDownloadRecord] = []
    var isReady: Bool { repository != nil && snapshot != nil && !isLoading && error == nil }
    var didLoad: (@MainActor (TelegramDownloadJournalSnapshot) -> Void)?
    var didCommit: (@MainActor (TelegramDownloadJournalSnapshot) -> Void)?
    private var repository: (any TelegramDownloadJournalRepository)?
    private var loadRequest: (any TelegramDownloadJournalRequest)?
    private var snapshot: TelegramDownloadJournalSnapshot?
    private var persistedRevision: UUID?
    private var pending: [Mutation] = []
    private var generation = UUID(), writing: UUID?
    isolated deinit { loadRequest?.cancel() }

    func bind(repository: (any TelegramDownloadJournalRepository)?) {
        generation = UUID(); let context = generation
        loadRequest?.cancel(); loadRequest = nil; writing = nil
        let abandoned = pending; pending = []
        self.repository = repository; accountID = repository?.accountID
        snapshot = nil; persistedRevision = nil; records = []; error = nil; isSaving = false; isLoading = false
        for mutation in abandoned { mutation.completion(false) }
        guard generation == context, let repository else { return }
        isLoading = true
        let request = repository.load { [weak self] result in
            guard let self, self.generation == context, self.accountID == repository.accountID else { return }
            self.isLoading = false; let old = self.loadRequest; self.loadRequest = nil; old?.cancel()
            switch result {
            case let .success(value):
                guard value.map({ $0.accountID == repository.accountID && $0.isValid }) ?? true else { self.fail(.invalid); return }
                self.persistedRevision = value?.revision
                let loaded = value ?? .init(accountID:repository.accountID,revision:UUID(),records:[])
                self.snapshot = loaded; self.records = loaded.records; self.didLoad?(loaded)
            case let .failure(error): self.fail(error)
            }
        }
        if generation == context, isLoading { loadRequest = request } else { request.cancel() }
    }
    func reload() {
        guard !isSaving, let repository else { return }; bind(repository:repository)
    }
    func upsert(_ record: TelegramDownloadRecord, completion: @escaping @MainActor (Bool) -> Void) {
        guard record.isValid else { completion(false); return }
        enqueue(.upsert(record),completion:completion)
    }
    func remove(ids: Set<String>, completion: @escaping @MainActor (Bool) -> Void) {
        guard ids.count <= 1000 else { completion(false); return }
        enqueue(.remove(ids),completion:completion)
    }
    private func enqueue(_ change: Change, completion: @escaping @MainActor (Bool) -> Void) {
        guard isReady, pending.count < 1000 else { completion(false); return }
        pending.append(.init(change:change,completion:completion)); pump()
    }
    private func pump() {
        guard isReady, writing == nil, let mutation = pending.first, let repository, var candidate = snapshot else { return }
        switch mutation.change {
        case let .upsert(value):
            if let index = candidate.records.firstIndex(where:{ $0.attachmentID == value.attachmentID }) { candidate.records[index] = value }
            else { candidate.records.append(value) }
        case let .remove(ids): candidate.records.removeAll { ids.contains($0.attachmentID) }
        }
        candidate.revision = UUID()
        guard (try? candidate.encoded()) != nil else { fail(.invalid); return }
        writing = mutation.id; isSaving = true; let context = generation
        let value = candidate
        repository.save(value,expected:persistedRevision) { [self] result in
            guard self.generation == context, self.writing == mutation.id,
                  self.pending.first?.id == mutation.id, self.accountID == value.accountID else { return }
            self.writing = nil; self.isSaving = false
            switch result {
            case .success:
                self.snapshot = value; self.persistedRevision = value.revision; self.records = value.records
                self.pending.removeFirst(); mutation.completion(true)
                guard self.generation == context else { return }; self.pump()
                if self.generation == context, self.pending.isEmpty, self.writing == nil, let snapshot = self.snapshot { self.didCommit?(snapshot) }
            case let .failure(error): self.fail(error)
            }
        }
    }
    private func fail(_ cause: TelegramDownloadJournalError) {
        switch cause {
        case .invalid: error = "Очередь загрузок имеет несовместимый формат или превышает допустимый размер. Сохранённые данные не изменены."
        case .unavailable: error = "Не удалось подтвердить сохранение очереди загрузок. Проверьте её перед перезапуском."
        case .changed: error = "Очередь загрузок изменена другим окном. Обновите её перед продолжением."
        }
        writing = nil; isSaving = false
        let abandoned = pending; pending = []
        for mutation in abandoned { mutation.completion(false) }
    }
}
