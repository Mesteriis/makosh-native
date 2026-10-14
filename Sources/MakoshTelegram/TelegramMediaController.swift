import Foundation
import Combine

public enum TelegramMediaPurpose: Hashable, Sendable { case preview, full }

public struct TelegramMediaKey: Hashable, Sendable {
    public let attachmentID: String
    public let purpose: TelegramMediaPurpose
    public init(attachmentID: String, purpose: TelegramMediaPurpose) {
        self.attachmentID = attachmentID
        self.purpose = purpose
    }
}

public enum TelegramMediaPhase: Equatable, Sendable {
    case idle, queued, downloading(Double?), capturing, ready, failed, cancelled, timedOut
}

@MainActor
protocol TelegramMediaLease: AnyObject { func cancel() }

@MainActor protocol TelegramMediaArchiveReservation: AnyObject {
    func capture(file: URL, byteCount: Int64) -> Bool
    func capture(file:URL,byteCount:Int64,completion:@escaping @MainActor (Bool) -> Void)
    func cancel()
}
extension TelegramMediaArchiveReservation {
    func capture(file:URL,byteCount:Int64,completion:@escaping @MainActor (Bool) -> Void) { completion(capture(file:file,byteCount:byteCount)) }
}

@MainActor
protocol TelegramMediaProvider: AnyObject {
    func start(attachmentID: String, purpose: TelegramMediaPurpose,
               receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease
    func startAutomatically(attachmentID: String, preferences: TelegramAutoDownloadPreferences,
        isCurrent: @escaping @MainActor () -> Bool,
        receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease
    func startCached(attachmentID: String, receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease
}

private final class RefusedAutomaticMediaLease: TelegramMediaLease { func cancel() {} }
extension TelegramMediaProvider {
    func startCached(attachmentID:String,receive:@escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
        receive(.failed); return RefusedAutomaticMediaLease()
    }
    func startAutomatically(attachmentID: String, preferences: TelegramAutoDownloadPreferences,
        isCurrent: @escaping @MainActor () -> Bool,
        receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
        receive(.failed); return RefusedAutomaticMediaLease()
    }
}

enum TelegramMediaEvent {
    case progress(Double?)
    case data(URL, offset: Int64, size: Int64, complete: Bool)
    case failed
    case fetchCompleted
}

public struct TelegramMediaTransfer: Identifiable, Equatable, Sendable {
    public let id, contextID: UUID
    public let key: TelegramMediaKey
    public let attachment: TelegramAttachment
    public let phase: TelegramMediaPhase
    public let automatic: Bool
}

/// Owns each provider lease until cancellation or removal, including completed files.
/// File content and export validation belong to the provider/export boundary.
@MainActor
public final class TelegramMediaController: ObservableObject {
    @MainActor
    private final class LeaseHolder {
        var lease: (any TelegramMediaLease)?
        var borrows = 0
        var releasePending = false
        var archiveReservation: (any TelegramMediaArchiveReservation)?
        func release() {
            archiveReservation?.cancel(); archiveReservation = nil
            releasePending = true
            if borrows == 0 { let old = lease; lease = nil; old?.cancel() }
        }
        func endBorrow() { borrows -= 1; if releasePending { release() } }
    }
    @MainActor
    private struct Job {
        let token: UUID
        var phase: TelegramMediaPhase
        var file: URL?
        var size: Int64 = 0
        var holder = LeaseHolder()
        var deadline: Task<Void, Never>?
        var completedFile: (@MainActor (String,URL,Int64) -> Void)?
        var automatic = false
        var automaticIsCurrent: (@MainActor () -> Bool)?
        var preferences: TelegramAutoDownloadPreferences?
        var admitted = true
        var cachedOnly = false
        var deadlineID = UUID()
        var highestProgress: Double?
        var receivedBytes: Int64 = 0
        var reserveManual: (@MainActor () -> (any TelegramMediaArchiveReservation)?)?
    }
    @Published private var revision = 0
    private var provider: (any TelegramMediaProvider)?
    private var attachments: [String: TelegramAttachment] = [:]
    private var jobs: [TelegramMediaKey: Job] = [:]
    private var manualOrder: [TelegramMediaKey] = []
    private var pumping = false
    private let scheduleDeadline: @MainActor (@escaping @MainActor () -> Void) -> Task<Void,Never>
    private var journal: TelegramDownloadJournal?
    private var journalObservation: AnyCancellable?
    private var recordFor: (@MainActor (TelegramAttachment,TelegramDownloadRecord.State) -> TelegramDownloadRecord?)?
    @Published private var manualError: String?
    @Published private var restoringQueue = false
    private(set) var restorationContextID = UUID()
    public var queueError: String? { journal?.error ?? manualError }
    public var isQueueLoading: Bool { journal?.isLoading == true || restoringQueue }
    public var isQueueSaving: Bool { journal?.isSaving == true }
    public func retryQueuePersistence() { restorationContextID = UUID(); manualError = nil; journal?.reload() }
    func setQueueRestoring(_ value:Bool,contextID:UUID) {
        guard transferContextID == contextID else { return }; restoringQueue = value
    }
    func hasTransfer(attachmentID:String) -> Bool { jobs[.init(attachmentID:attachmentID,purpose:.full)] != nil }
    func configureJournal(_ journal: TelegramDownloadJournal,
        recordFor: @escaping @MainActor (TelegramAttachment,TelegramDownloadRecord.State) -> TelegramDownloadRecord?) {
        self.journal = journal; self.recordFor = recordFor
        journalObservation = journal.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    func restoreManual(attachment:TelegramAttachment,state:TelegramDownloadRecord.State,
        completedFile:(@MainActor (String,URL,Int64) -> Void)?, contextID:UUID? = nil,
        reserveFile:(@MainActor () -> (any TelegramMediaArchiveReservation)?)? = nil) {
        let key = TelegramMediaKey(attachmentID:attachment.id,purpose:.full)
        guard contextID.map({ $0 == restorationContextID }) ?? true, provider != nil, attachment.canDownload else { return }
        if var existing = jobs[key] {
            guard [.failed,.cancelled,.timedOut].contains(existing.phase) else { return }
            // An explicitly refreshed native source may recover a previously
            // refused placeholder. Preserve cancellation and install the newly
            // verified archive recipe without starting a transfer.
            attachments[attachment.id] = attachment; existing.completedFile = completedFile; existing.reserveManual = reserveFile
            if state == .cancelled { existing.phase = .cancelled }
            jobs[key] = existing; revision &+= 1; return
        }
        guard manualAttachmentKeys.count < 1000 else { return }
        attachments[attachment.id] = attachment
        let phase: TelegramMediaPhase
        switch state { case .pending,.ready: phase = .queued; case .cancelled: phase = .cancelled; case .failed: phase = .failed }
        jobs[key] = Job(token:UUID(),phase:phase,completedFile:completedFile,admitted:true,cachedOnly:state == .ready,reserveManual:reserveFile)
        manualOrder.append(key); revision &+= 1
        if phase == .queued { pumpManual() }
    }
    func noteQueueRestorationFailure() {
        manualError = "Некоторые исходные сообщения изменены или недоступны. Их загрузки остановлены; обновите очередь для повторной проверки."
    }
    var completedFullFile: (@MainActor (String,URL,Int64) -> Void)?
    var reserveAutomaticFile: (@MainActor (String) -> (any TelegramMediaArchiveReservation)?)?
    var reserveManualFile: (@MainActor (String) -> (any TelegramMediaArchiveReservation)?)?
    func archiveCapacityChanged() { pumpManual() }

    @Published public private(set) var transferContextID = UUID()
    public var transfers: [TelegramMediaTransfer] {
        jobs.keys.filter { $0.purpose == .full }.compactMap { transfer(for:$0) }.sorted { $0.key.attachmentID < $1.key.attachmentID }
    }
    public func transfer(for key: TelegramMediaKey) -> TelegramMediaTransfer? {
        guard let job = jobs[key], let attachment = attachments[key.attachmentID] else { return nil }
        return .init(id:job.token,contextID:transferContextID,key:key,attachment:attachment,phase:job.phase,automatic:job.automatic)
    }
    private func matchesTransfer(_ transfer: TelegramMediaTransfer) -> Bool {
        transfer.contextID == transferContextID && jobs[transfer.key]?.token == transfer.id && attachments[transfer.key.attachmentID] == transfer.attachment
    }
    @discardableResult public func cancelTransfer(_ transfer: TelegramMediaTransfer) -> Bool {
        guard matchesTransfer(transfer), let job = jobs[transfer.key] else { return false }
        switch job.phase {
        case .queued, .downloading, .capturing:
            if !job.automatic { restorationContextID = UUID() }
            finish(transfer.key,phase:.cancelled); return true
        default: return false
        }
    }
    @discardableResult public func retryTransfer(_ transfer: TelegramMediaTransfer) -> Bool {
        guard matchesTransfer(transfer), let job = jobs[transfer.key], [.failed,.cancelled,.timedOut].contains(job.phase), transfer.key.purpose == .full else { return false }
        return start(transfer.attachment,purpose:.full,automatic:nil)
    }
    @discardableResult public func invalidateTransfer(_ transfer: TelegramMediaTransfer) -> Bool {
        guard matchesTransfer(transfer), let phase = jobs[transfer.key]?.phase, [.ready,.capturing].contains(phase) else { return false }
        finish(transfer.key,phase:.failed); return true
    }
    @discardableResult public func clearFinishedTransfers(contextID: UUID) -> Bool {
        guard contextID == transferContextID else { return false }
        var removed = Set<String>()
        for key in Array(jobs.keys) where key.purpose == .full {
            if jobs[key]?.phase == .queued || jobs[key]?.phase == .capturing { continue }
            if case .downloading = jobs[key]?.phase { continue }
            if jobs[key]?.automatic == false { removed.insert(key.attachmentID) }
            remove(key,persist:false)
        }
        if !removed.isEmpty { restorationContextID = UUID(); journal?.remove(ids:removed) { [weak self] saved in
            guard let self, self.transferContextID == contextID else { return }
            if !saved { self.manualError = "Удаление из сохранённой очереди не подтверждено. Обновите очередь." }
        } }
        return true
    }
    public convenience init() {
        self.init(scheduleDeadline:{ action in Task { @MainActor in
            do { try await Task.sleep(for:.seconds(60)) } catch { return }; action()
        } })
    }
    init(scheduleDeadline:@escaping @MainActor (@escaping @MainActor () -> Void) -> Task<Void,Never>) { self.scheduleDeadline = scheduleDeadline }

    isolated deinit {
        for job in jobs.values { job.deadline?.cancel(); job.holder.release() }
    }

    public func phase(for key: TelegramMediaKey) -> TelegramMediaPhase { jobs[key]?.phase ?? .idle }

    public func downloadedFile(for key: TelegramMediaKey) -> URL? {
        guard let phase = jobs[key]?.phase, [.ready,.capturing].contains(phase) else { return nil }
        return jobs[key]?.file
    }

    public func withDownloadedFile(for key: TelegramMediaKey, transfer: TelegramMediaTransfer? = nil,
                                   operation: @MainActor (URL, Int64) async throws -> Void) async throws -> Bool {
        guard let job = jobs[key], [.ready,.capturing].contains(job.phase), let url = job.file else { return false }
        if let transfer { guard transfer.key == key, matchesTransfer(transfer) else { return false } }
        job.holder.borrows += 1
        defer { job.holder.endBorrow() }
        try await operation(url, job.size)
        return true
    }

    func bind(provider: (any TelegramMediaProvider)?) {
        reset()
        self.provider = provider
    }

    public func reset() {
        let previous = jobs
        jobs.removeAll()
        attachments.removeAll()
        manualOrder = []; journalObservation = nil; journal = nil; recordFor = nil; manualError = nil
        restorationContextID = UUID(); restoringQueue = false
        transferContextID = UUID()
        provider = nil
        completedFullFile = nil
        reserveAutomaticFile = nil
        reserveManualFile = nil
        revision &+= 1
        for job in previous.values { job.deadline?.cancel(); job.holder.release() }
    }

    func retain(attachments: [TelegramAttachment]) {
        let visible = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var next = visible
        // Explicit full downloads belong to this account. An absent chat is not
        // evidence that its pinned resource changed. A changed descriptor is.
        for key in manualAttachmentKeys where next[key] == nil { next[key] = self.attachments[key] }
        let removed = jobs.keys.filter { key in
            let scope = key.purpose == .preview || jobs[key]?.automatic == true ? visible : next
            guard let old = self.attachments[key.attachmentID], let new = scope[key.attachmentID] else { return true }
            return old != new
        }
        for key in removed { remove(key) }
        self.attachments = next
    }
    var manualAttachmentKeys: Set<String> {
        Set(jobs.compactMap { key,job in key.purpose == .full && !job.automatic ? key.attachmentID : nil })
    }
    func retainedManualAttachment(_ id: String) -> TelegramAttachment? {
        manualAttachmentKeys.contains(id) ? attachments[id] : nil
    }

    public func start(_ attachment: TelegramAttachment, purpose: TelegramMediaPurpose) {
        _ = start(attachment, purpose: purpose, automatic: nil)
    }

    @discardableResult func startAutomatically(_ attachment: TelegramAttachment, preferences: TelegramAutoDownloadPreferences,
        isCurrent: @escaping @MainActor () -> Bool) -> Bool {
        start(attachment, purpose: .full, automatic: preferences, isCurrent: isCurrent)
    }
    var automaticInFlightCount: Int {
        jobs.values.filter { job in if job.phase == .capturing { return job.automatic }; if case .downloading = job.phase { return job.automatic }; return false }.count
    }
    var inFlightCount: Int {
        jobs.values.filter { if [.queued,.capturing].contains($0.phase) { return true }; if case .downloading = $0.phase { return true }; return false }.count
    }
    func cancelAutomaticDownloads(except retained: Set<String>) {
        for key in jobs.keys.filter({ jobs[$0]?.automatic == true && !retained.contains($0.attachmentID) }) { remove(key) }
    }
    @discardableResult private func start(_ attachment: TelegramAttachment, purpose: TelegramMediaPurpose,
        automatic: TelegramAutoDownloadPreferences?, isCurrent: (@MainActor () -> Bool)? = nil) -> Bool {
        guard provider != nil, attachments[attachment.id] == attachment,
              purpose == .preview ? attachment.hasPreview : attachment.canDownload else { return false }
        guard automatic == nil || isCurrent?() == true else { return false }
        let key = TelegramMediaKey(attachmentID: attachment.id, purpose: purpose)
        let manual = purpose == .full && automatic == nil
        if manual, let journal, !journal.isReady { manualError = "Очередь загрузок ещё не прочитана или её сохранение недоступно. Обновите очередь."; return false }
        if manual, jobs[key] == nil || jobs[key]?.automatic == true, manualAttachmentKeys.count >= 1000 { manualError = "В очереди уже1000файлов. Уберите завершённые перед новой загрузкой."; return false }
        if let phase = jobs[key]?.phase {
            if phase == .ready {
                if manual, jobs[key]?.automatic == true { restorationContextID = UUID(); jobs[key]?.automatic = false; persist(key,state:.ready) }
                return false
            }
            if phase == .queued || phase == .capturing { return false }
            if case .downloading = phase {
                if automatic != nil || jobs[key]?.automatic != true { return false }
                // A manual action owns a new lease, independent of automatic admission.
            }
        }
        let reservation: (any TelegramMediaArchiveReservation)?
        if automatic != nil, let reserveAutomaticFile {
            guard let granted = reserveAutomaticFile(attachment.id) else { return false }; reservation = granted
        } else { reservation = nil }
        let completion: (@MainActor (String,URL,Int64) -> Void)?
        let manualReservation: (@MainActor () -> (any TelegramMediaArchiveReservation)?)?
        if let old = jobs[key], key.purpose == .full, !old.automatic { completion = old.completedFile; manualReservation = old.reserveManual }
        else {
            completion = completedFullFile
            if let factory = reserveManualFile { let id = attachment.id; manualReservation = { factory(id) } }
            else { manualReservation = nil }
        }
        if manual { restorationContextID = UUID(); manualError = nil }
        remove(key,persist:false)
        let token = UUID()
        jobs[key] = Job(token: token, phase: manual ? .queued : .downloading(nil), completedFile: completion,
            automatic: automatic != nil, automaticIsCurrent: isCurrent,preferences:automatic,admitted:journal == nil,reserveManual:manualReservation)
        jobs[key]?.holder.archiveReservation = reservation
        revision &+= 1
        if manual {
            manualOrder.append(key)
            if journal != nil {
                persist(key,state:.pending) { [weak self] saved in
                    guard let self, self.jobs[key]?.token == token else { return }
                    if saved { self.jobs[key]?.admitted = true; self.pumpManual() }
                    else { self.finish(key,phase:.failed,persist:false) }
                }
            } else { pumpManual() }
        } else { beginFetch(key,token:token) }
        return true
    }

    private func pumpManual() {
        guard !pumping else { return }; pumping = true
        defer { pumping = false }
        while provider != nil, manualInFlightCount < 4,
              let key = manualOrder.first(where:{ jobs[$0]?.phase == .queued && jobs[$0]?.admitted == true }), let token = jobs[key]?.token {
            if let factory = jobs[key]?.reserveManual, jobs[key]?.holder.archiveReservation == nil {
                guard let reservation = factory() else { return }; jobs[key]?.holder.archiveReservation = reservation
            }
            beginFetch(key,token:token)
        }
    }
    private var manualInFlightCount: Int {
        jobs.filter { entry in
            guard entry.key.purpose == .full, !entry.value.automatic else { return false }
            if entry.value.phase == .capturing { return true }; if case .downloading = entry.value.phase { return true }; return false
        }.count
    }
    private func beginFetch(_ key: TelegramMediaKey, token: UUID) {
        guard let provider, let job = jobs[key], job.token == token else { return }
        jobs[key]?.phase = .downloading(nil)
        armDeadline(key,token:token)
        revision &+= 1
        let receive: @MainActor (TelegramMediaEvent) -> Void = { [weak self] event in
            self?.receive(event, key: key, token: token)
        }
        let lease: any TelegramMediaLease
        if job.cachedOnly { lease = provider.startCached(attachmentID:key.attachmentID,receive:receive) }
        else if let preferences = job.preferences {
            lease = provider.startAutomatically(attachmentID:key.attachmentID,preferences:preferences,isCurrent:job.automaticIsCurrent ?? { false },receive:receive)
        } else { lease = provider.start(attachmentID:key.attachmentID,purpose:key.purpose,receive:receive) }
        // A provider may emit completion, failure or cancellation synchronously.
        guard let current = jobs[key], current.token == token else { lease.cancel(); return }
        switch current.phase {
        case .downloading, .capturing, .ready:
            current.holder.lease = lease
            if current.holder.releasePending { current.holder.release() }
        default: lease.cancel()
        }
    }

    private func persist(_ key: TelegramMediaKey, state: TelegramDownloadRecord.State, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard key.purpose == .full, jobs[key]?.automatic == false, let journal else { completion?(true); return }
        guard let attachment = attachments[key.attachmentID], let record = recordFor?(attachment,state) else {
            manualError = "Исходное сообщение для сохранения очереди недоступно."; completion?(false); return
        }
        let context = transferContextID
        journal.upsert(record) { [weak self] saved in
            guard let self, self.transferContextID == context else { return }
            if !saved { self.manualError = "Сохранение очереди не подтверждено. Обновите её перед перезапуском." }
            completion?(saved)
        }
    }

    public func cancel(_ key: TelegramMediaKey) {
        if key.purpose == .full, jobs[key]?.automatic == false { restorationContextID = UUID() }
        finish(key, phase: .cancelled)
    }

    /// Deterministic deadline seam for tests; real timers also check their token.
    func timeout(_ key: TelegramMediaKey) {
        guard let token = jobs[key]?.token else { return }
        timeout(key, token: token)
    }

    private func timeout(_ key: TelegramMediaKey, token: UUID) {
        guard let job = jobs[key], job.token == token, case .downloading = job.phase else { return }
        finish(key, phase: .timedOut)
    }
    private func armDeadline(_ key:TelegramMediaKey,token:UUID) {
        guard jobs[key]?.token == token else { return }
        jobs[key]?.deadline?.cancel(); let id = UUID(); jobs[key]?.deadlineID = id
        let task = scheduleDeadline { [weak self] in
            guard let self, self.jobs[key]?.token == token, self.jobs[key]?.deadlineID == id else { return }
            self.timeout(key,token:token)
        }
        if jobs[key]?.token == token, jobs[key]?.deadlineID == id { jobs[key]?.deadline = task } else { task.cancel() }
    }

    private func receive(_ event: TelegramMediaEvent, key: TelegramMediaKey, token: UUID) {
        guard let job = jobs[key], job.token == token, case .downloading = job.phase else { return }
        if job.automatic, job.automaticIsCurrent?() != true { finish(key, phase: .cancelled); return }
        switch event {
        case .progress(let value):
            let progress = value.flatMap { $0.isFinite ? min(1,max(0,$0)) : nil }
            jobs[key]?.phase = .downloading(progress)
            if let progress, job.highestProgress.map({ progress > $0 }) ?? true {
                jobs[key]?.highestProgress = progress; armDeadline(key,token:token)
            }
        case let .data(url, offset, size, complete):
            if !complete, offset == 0, size > job.receivedBytes, url.isFileURL {
                jobs[key]?.receivedBytes = size; armDeadline(key,token:token)
            }
            guard complete, offset == 0, size >= 0, url.isFileURL else { return }
            if let reservation = job.holder.archiveReservation {
                // The reservation freezes an FD before its first suspension.
                // Complete native bytes remain borrowable while archive admission
                // waits; the bounded active slot prevents unlimited next fetches.
                jobs[key]?.file = url; jobs[key]?.size = size; jobs[key]?.phase = .capturing
                jobs[key]?.deadline?.cancel(); jobs[key]?.deadline = nil; revision &+= 1
                reservation.capture(file:url,byteCount:size) { [weak self] captured in
                    guard let self, self.jobs[key]?.token == token, self.jobs[key]?.phase == .capturing else { return }
                    guard captured else { self.finish(key,phase:.failed); return }
                    self.jobs[key]?.holder.archiveReservation = nil
                    self.completeFile(key,token:token,url:url,size:size,reserved:true)
                }
                return
            }
            completeFile(key,token:token,url:url,size:size,reserved:false); return
        case .failed:
            finish(key, phase: .failed)
            return
        case .fetchCompleted:
            // Fetch termination is not proof of a complete readable resource.
            return
        }
        revision &+= 1
    }
    private func completeFile(_ key:TelegramMediaKey,token:UUID,url:URL,size:Int64,reserved:Bool) {
        guard let job = jobs[key], job.token == token else { return }
        jobs[key]?.phase = .ready; jobs[key]?.file = url; jobs[key]?.size = size
        jobs[key]?.deadline?.cancel(); jobs[key]?.deadline = nil
        if !reserved, key.purpose == .full { job.completedFile?(key.attachmentID,url,size) }
        revision &+= 1; persist(key,state:.ready); pumpManual()
    }

    private func finish(_ key: TelegramMediaKey, phase: TelegramMediaPhase, persist: Bool = true) {
        guard let old = jobs[key] else { return }
        // Invalidate before invoking provider cancellation, which may emit events.
        jobs[key] = Job(token: UUID(), phase: phase, completedFile: old.completedFile, automatic: old.automatic,reserveManual:old.reserveManual)
        revision &+= 1
        old.deadline?.cancel()
        old.holder.release()
        if persist { self.persist(key,state:phase == .cancelled ? .cancelled : .failed) }
        pumpManual()
    }

    private func remove(_ key: TelegramMediaKey, persist: Bool = true) {
        guard let old = jobs.removeValue(forKey: key) else { return }
        if persist, key.purpose == .full, !old.automatic { restorationContextID = UUID() }
        revision &+= 1
        old.deadline?.cancel(); old.holder.release()
        manualOrder.removeAll { $0 == key }
        if persist, key.purpose == .full, !old.automatic {
            let context = transferContextID
            journal?.remove(ids:[key.attachmentID]) { [weak self] saved in
                guard let self, self.transferContextID == context else { return }
                if !saved { self.manualError = "Удаление из сохранённой очереди не подтверждено." }
            }
        }
    }
}
