import Foundation
import Combine

@MainActor protocol TelegramQRLoginRequest: AnyObject { func cancel() }
enum TelegramQRLoginError: Error { case failed }
enum TelegramQRLoginResult {
    case token(Data, expiresAt: Date), password, authorized
}
@MainActor protocol TelegramQRLoginProvider: AnyObject {
    func request(receive: @escaping @MainActor (Result<TelegramQRLoginResult, TelegramQRLoginError>) -> Void) -> any TelegramQRLoginRequest
    func observeEvents(receive: @escaping @MainActor () -> Void) -> any TelegramQRLoginRequest
}

/// Owns only the explicitly selected QR mode. Authorization/account state remains native.
@MainActor public final class TelegramQRLoginController: ObservableObject {
    public enum Phase: Equatable { case idle, loading, displaying, failed, finished }
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var displayURL: String?
    public var isActive: Bool { phase == .loading || phase == .displaying }
    private var provider: (any TelegramQRLoginProvider)?
    private var request: (any TelegramQRLoginRequest)?, events: (any TelegramQRLoginRequest)?, timer: (any TelegramQRLoginRequest)?
    private var generation = UUID(), requestID: UUID?
    private var eventPending = false
    private let now: @MainActor () -> Date
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> any TelegramQRLoginRequest
    public convenience init() {
        self.init(now: Date.init, schedule: { delay, action in TelegramQRLoginTimer(delay: delay, action: action) })
    }
    init(now: @escaping @MainActor () -> Date,
         schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> any TelegramQRLoginRequest) {
        self.now = now; self.schedule = schedule
    }
    isolated deinit { request?.cancel(); events?.cancel(); timer?.cancel() }
    func bind(_ provider: (any TelegramQRLoginProvider)?) { cancel(); self.provider = provider }
    public func cancel() {
        generation = UUID(); requestID = nil; eventPending = false
        request?.cancel(); request = nil; events?.cancel(); events = nil; timer?.cancel(); timer = nil
        displayURL = nil; phase = .idle
    }
    public func start() {
        cancel()
        guard let provider else { phase = .failed; return }
        phase = .loading
        let context = generation
        let observing = provider.observeEvents { [weak self] in
            guard let self, self.generation == context, self.isActive else { return }
            if self.requestID != nil { self.eventPending = true } else { self.refresh() }
        }
        if generation == context && isActive { events = observing } else { observing.cancel() }
        refresh()
    }
    private func refresh() {
        guard isActive, let provider else { return }
        guard requestID == nil else { eventPending = true; return }
        displayURL = nil; phase = .loading; timer?.cancel(); timer = nil
        let id = UUID(), context = generation; requestID = id
        timer = schedule(30) { [weak self] in
            guard let self, self.generation == context, self.requestID == id else { return }
            self.fail()
        }
        let reading = provider.request { [weak self] result in
            guard let self, self.generation == context, self.requestID == id else { return }
            self.requestID = nil; self.request?.cancel(); self.request = nil; self.timer?.cancel(); self.timer = nil
            switch result {
            case .failure: self.fail()
            case .success(.password), .success(.authorized): self.cancel(); self.phase = .finished
            case let .success(.token(data, expiresAt)):
                let lifetime = expiresAt.timeIntervalSince(self.now())
                guard !data.isEmpty, data.count <= 512, lifetime.isFinite, lifetime > 0, lifetime <= 300 else { self.fail(); return }
                self.displayURL = "tg://login?token=" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                self.phase = .displaying
                if self.eventPending { self.eventPending = false; self.refresh() }
                else {
                    self.timer = self.schedule(min(30, lifetime)) { [weak self] in
                        guard let self, self.generation == context, self.isActive else { return }
                        self.refresh()
                    }
                }
            }
        }
        if generation == context && requestID == id { request = reading } else { reading.cancel() }
    }
    private func fail() { cancel(); phase = .failed }
}

@MainActor private final class TelegramQRLoginTimer: TelegramQRLoginRequest {
    private var task: Task<Void, Never>?
    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        task = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }; action()
        }
    }
    func cancel() { task?.cancel(); task = nil }
    isolated deinit { task?.cancel() }
}
