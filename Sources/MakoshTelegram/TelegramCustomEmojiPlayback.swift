import Foundation
import Combine
import TelegramCore

@MainActor protocol TelegramCustomEmojiResourceProvider: AnyObject {
    var accountID: Int64 { get }
    func start(descriptor: TelegramCustomEmojiDescriptor,
        receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease
}
struct TelegramCustomEmojiPlaybackLimits: Sendable {
    let maximumVisibleLeases: Int
    let maximumAnimatedDecoders: Int
    let maximumEncodedBytes: Int
    static let standard = Self(maximumVisibleLeases: 8, maximumAnimatedDecoders: 4,
        maximumEncodedBytes: 32 * 1024 * 1024)
}
@MainActor public final class TelegramCustomEmojiPlaybackContext {
    public let id = UUID()
    public let accountID: Int64
    let provider: any TelegramCustomEmojiResourceProvider
    private let limits: TelegramCustomEmojiPlaybackLimits
    private var valid = true
    var isValid: Bool { valid }
    private var visible: [UUID: @MainActor () -> Void] = [:]
    private var work: [UUID: Int] = [:]
    private var encodedBytes = 0

    init(accountID: Int64, provider: any TelegramCustomEmojiResourceProvider,
        limits: TelegramCustomEmojiPlaybackLimits = .standard) {
        self.accountID = accountID; self.provider = provider; self.limits = limits
    }
    convenience init(account: Account) {
        self.init(accountID: account.peerId.toInt64(), provider: TelegramCustomEmojiEngineResourceProvider(account: account))
    }
    public func invalidate() {
        guard valid else { return }; valid = false
        let callbacks = Array(visible.values); visible.removeAll()
        for cancel in callbacks { cancel() }
    }
    fileprivate func acquire(cancel: @escaping @MainActor () -> Void) -> UUID? {
        guard valid, accountID == provider.accountID, limits.maximumVisibleLeases > 0,
              visible.count < limits.maximumVisibleLeases else { return nil }
        let token = UUID(); visible[token] = cancel; return token
    }
    fileprivate func release(_ token: UUID) { visible.removeValue(forKey: token) }
    fileprivate func beginWork(visible token: UUID, size: Int) -> UUID? {
        // Reserve before constructing native decoders. WebP may be animated, so
        // its metadata preparation initially borrows the same bounded slot.
        guard valid, visible[token] != nil, size > 0, limits.maximumEncodedBytes >= size,
              encodedBytes <= limits.maximumEncodedBytes - size,
              limits.maximumAnimatedDecoders > 0, work.count < limits.maximumAnimatedDecoders else { return nil }
        let job = UUID(); work[job] = size; encodedBytes += size; return job
    }
    fileprivate func endWork(_ token: UUID) {
        guard let size = work.removeValue(forKey: token) else { return }; encodedBytes -= size
    }
}
public enum TelegramCustomEmojiPlaybackPhase: Equatable, Sendable { case idle, loading, playing, failed }
@MainActor public final class TelegramCustomEmojiPlaybackController: ObservableObject {
    @Published public private(set) var frame: TelegramCustomEmojiFrame?
    @Published public private(set) var phase: TelegramCustomEmojiPlaybackPhase = .idle
    private let loadingDeadline: Duration
    private var context: TelegramCustomEmojiPlaybackContext?
    private var request: UUID?
    private var visibleToken: UUID?
    private var descriptor: TelegramCustomEmojiDescriptor?
    private var width = 0, height = 0
    private var holder: TelegramCustomEmojiPlaybackLease?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var decoding = false

    public init(loadingDeadline: Duration = .seconds(30)) { self.loadingDeadline = loadingDeadline }
    isolated deinit { deadline?.cancel(); worker?.cancel(); holder?.release(); if let visibleToken { context?.release(visibleToken) } }
    public func bind(context: TelegramCustomEmojiPlaybackContext?) {
        guard self.context !== context else { return }; stop(); self.context = context
    }
    public func play(descriptor: TelegramCustomEmojiDescriptor, width: Int, height: Int) {
        if self.descriptor == descriptor, self.width == width, self.height == height,
           phase == .loading || phase == .playing { return }
        stop()
        guard let context, (1...512).contains(width), (1...512).contains(height), loadingDeadline > .zero,
              let token = context.acquire(cancel: { [weak self] in self?.stop() }) else { phase = .failed; return }
        let request = UUID(), holder = TelegramCustomEmojiPlaybackLease()
        self.request = request; self.visibleToken = token; self.holder = holder
        self.descriptor = descriptor; self.width = width; self.height = height; phase = .loading
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: self?.loadingDeadline ?? .zero) } catch { return }
            guard let self, self.request == request, self.phase == .loading else { return }
            self.fail(request: request)
        }
        holder.install(context.provider.start(descriptor: descriptor, receive: { [weak self] event in
            self?.receive(event, request: request, context: context, holder: holder)
        }))
    }
    public func stop() {
        request = nil; deadline?.cancel(); deadline = nil; worker?.cancel(); worker = nil
        holder?.release(); holder = nil
        if let token = visibleToken { context?.release(token) }; visibleToken = nil
        decoding = false; descriptor = nil; frame = nil; phase = .idle
    }
    private func fail(request: UUID) {
        guard self.request == request else { return }; stop(); phase = .failed
    }
    private func receive(_ event: TelegramMediaEvent, request: UUID,
        context: TelegramCustomEmojiPlaybackContext, holder: TelegramCustomEmojiPlaybackLease) {
        guard self.request == request, self.context === context, phase == .loading else { return }
        switch event {
        case let .data(url, offset, size, complete):
            guard complete, !decoding else { return }
            guard offset == 0, size > 0, size <= 8 * 1024 * 1024, url.isFileURL,
                  let visibleToken, let descriptor,
                  let budget = context.beginWork(visible: visibleToken, size: Int(size)) else { fail(request: request); return }
            decoding = true; holder.borrow()
            let width = self.width, height = self.height
            worker = Task.detached(priority: .utility) { [weak self] in
                let result = await Self.decode(url: url, size: Int(size), format: descriptor.format,
                    width: width, height: height, publish: { [weak self] pixels in
                        guard let self, self.request == request, self.context === context,
                              !Task.isCancelled else { return false }
                        self.deadline?.cancel(); self.deadline = nil
                        self.frame = pixels; self.phase = .playing; return true
                    })
                await MainActor.run {
                    context.endWork(budget); holder.endBorrow()
                    guard let self, self.request == request else { return }
                    self.worker = nil
                    switch result {
                    case let .staticFrame(pixels):
                        self.deadline?.cancel(); self.deadline = nil
                        self.frame = pixels; self.phase = .playing
                    case .failed: self.fail(request: request)
                    }
                }
            }
        case .failed: if !decoding { fail(request: request) }
        case .progress, .fetchCompleted: break
        }
    }
    private enum DecodeResult: Sendable { case staticFrame(TelegramCustomEmojiFrame), failed }
    private nonisolated static func decode(url: URL, size: Int, format: TelegramCustomEmojiFormat,
        width: Int, height: Int, publish: @escaping @MainActor @Sendable (TelegramCustomEmojiFrame) -> Bool) async -> DecodeResult {
        do {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw TelegramCustomEmojiError.invalid }
            let file = try FileHandle(forReadingFrom: url)
            let bytes: Data
            do { defer { try? file.close() }; bytes = try file.read(upToCount: size + 1) ?? Data() }
            guard bytes.count == size else { throw TelegramCustomEmojiError.invalid }
            try Task.checkCancellation()
            let decoder = try TelegramCustomEmojiAnimationDecoder(bytes: bytes, format: format)
            let durations = decoder.info.frameDurations, total = durations.reduce(0, +)
            guard !durations.isEmpty, total.isFinite, total > 0, total <= 9 else { throw TelegramCustomEmojiError.invalid }
            let clock = ContinuousClock(), start = clock.now
            var last: Int?
            while true {
                try Task.checkCancellation()
                let elapsed = start.duration(to: clock.now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
                let position = seconds.truncatingRemainder(dividingBy: total)
                var end = 0.0, index = durations.count - 1
                for (candidate, duration) in durations.enumerated() {
                    end += duration; if position < end { index = candidate; break }
                }
                if index != last {
                    let pixels = try await decoder.frame(index: index, width: width, height: height)
                    try Task.checkCancellation()
                    // Complete the one-shot native job and release its budget/
                    // borrow before exposing ready state to synchronous stop().
                    if durations.count == 1 { return .staticFrame(pixels) }
                    guard await publish(pixels) else { throw CancellationError() }; last = index
                }
                try await Task.sleep(for: .milliseconds(33))
            }
        } catch { return .failed }
    }
}
@MainActor private final class TelegramCustomEmojiPlaybackLease {
    private var lease: (any TelegramMediaLease)?
    private var released = false
    private var borrows = 0
    func install(_ lease: any TelegramMediaLease) { self.lease = lease; if released && borrows == 0 { release() } }
    func borrow() { borrows += 1 }
    func endBorrow() { borrows -= 1; if released { release() } }
    func release() {
        released = true
        if borrows == 0 { let old = lease; lease = nil; old?.cancel() }
    }
}
