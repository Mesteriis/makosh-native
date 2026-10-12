import Foundation
import Combine
import Postbox
import TelegramCore
import SwiftSignalKit

public struct TelegramSendApprovalPrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let context: TelegramSendContext
    public let title: String
    public let perMessageStars: Int64
    public let totalStars: Int64
}

public enum TelegramSendApprovalError: Error, Equatable, Sendable {
    case unavailable, incompatible, stale, cancelled, timeout, busy
}

@MainActor protocol TelegramSendApprovalProviding: AnyObject {
    func capabilities(context: TelegramSendContext)
        -> Signal<Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError>, NoError>
    func createConsent(context: TelegramSendContext, perMessageStars: Int64, consentID: UUID)
        -> Signal<Result<TelegramPaidSendConsent, TelegramPaidSendConsentError>, NoError>
}

typealias TelegramSendApprovalDeadline = (@escaping @MainActor () -> Void) -> Disposable

@MainActor final class TelegramNativeSendApprovalProvider: TelegramSendApprovalProviding {
    private let postbox: Postbox
    private let accountID: Int64
    init(postbox: Postbox, accountID: Int64) { self.postbox = postbox; self.accountID = accountID }
    func capabilities(context: TelegramSendContext)
        -> Signal<Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError>, NoError> {
        guard context.accountID == accountID, telegramSendContextIsValid(context) else { return .single(.failure(.incompatible)) }
        return approvalCapabilitiesSignal(postbox: postbox, context: context)
    }
    func createConsent(context: TelegramSendContext, perMessageStars: Int64, consentID: UUID)
        -> Signal<Result<TelegramPaidSendConsent, TelegramPaidSendConsentError>, NoError> {
        guard context.accountID == accountID, telegramSendContextIsValid(context) else { return .single(.failure(.incompatible)) }
        return approvalConsentSignal(postbox: postbox, context: context, price: perMessageStars, id: consentID)
    }
}

// Build queue-executed closures outside the UI actor. No Account/network manager
// is constructed; a disposed UI lease never deletes an already written journal.
private nonisolated func approvalCapabilitiesSignal(postbox: Postbox, context: TelegramSendContext)
    -> Signal<Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError>, NoError> {
    postbox.transaction { telegramConversationCapabilities(transaction: $0,
        accountID: context.accountID, chatID: context.chatID) } |> deliverOnMainQueue
}
private nonisolated func approvalConsentSignal(postbox: Postbox, context: TelegramSendContext,
    price: Int64, id: UUID) -> Signal<Result<TelegramPaidSendConsent, TelegramPaidSendConsentError>, NoError> {
    postbox.transaction { transaction -> Result<TelegramPaidSendConsent, TelegramPaidSendConsentError> in
        do { return .success(try telegramPaidSendConsentCreate(transaction: transaction,
            context: context, perMessageStars: price, consentID: id)) }
        catch let error as TelegramPaidSendConsentError { return .failure(error) }
        catch { return .failure(.incompatible) }
    } |> deliverOnMainQueue
}

/// Local confirmation only; no Account creation, network send or paid attributes.
@MainActor public final class TelegramSendApprovalController: ObservableObject {
    @Published public private(set) var pendingPrompt: TelegramSendApprovalPrompt?
    @Published public private(set) var isConfirming = false
    private struct Request {
        let id: UUID
        let binding: UUID
        let context: TelegramSendContext
        let title: String
        let completion: (Result<TelegramPaidSendConsent?, TelegramSendApprovalError>) -> Void
    }
    private enum Phase: Equatable { case loading, waiting, confirming }
    private var provider: TelegramSendApprovalProviding?
    private var accountID: Int64?
    private var binding = UUID()
    private var active: Request?
    private var phase: Phase?
    private var nativeLease: MetaDisposable?
    private var deadlineLease: MetaDisposable?
    private let scheduleDeadline: TelegramSendApprovalDeadline

    public init() {
        scheduleDeadline = { action in
            let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
            return ActionDisposable { work.cancel() }
        }
    }
    init(scheduleDeadline: @escaping TelegramSendApprovalDeadline) { self.scheduleDeadline = scheduleDeadline }
    isolated deinit { nativeLease?.dispose(); deadlineLease?.dispose() }

    public func bind(account: Account?) {
        bind(provider: account.map { TelegramNativeSendApprovalProvider(postbox: $0.postbox,
            accountID: $0.peerId.toInt64()) }, accountID: account?.peerId.toInt64())
    }
    func bind(provider: TelegramSendApprovalProviding?, accountID: Int64?) {
        let completion = clear()
        binding = UUID(); self.provider = provider; self.accountID = accountID
        completion?(.failure(.cancelled))
    }
    func request(context: TelegramSendContext, title: String,
        completion: @escaping (Result<TelegramPaidSendConsent?, TelegramSendApprovalError>) -> Void) {
        guard let provider, let accountID else { completion(.failure(.unavailable)); return }
        guard context.accountID == accountID, telegramSendContextIsValid(context) else {
            completion(.failure(.incompatible)); return
        }
        guard active == nil else { completion(.failure(.busy)); return }
        let request = Request(id: UUID(), binding: binding, context: context, title: title, completion: completion)
        active = request; phase = .loading
        let lease = MetaDisposable(); nativeLease = lease
        startDeadline(request: request, phase: .loading)
        guard matches(request, phase: .loading) else { return }
        lease.set((provider.capabilities(context: context) |> deliverOnMainQueue).start(next: { [weak self] result in
            MainActor.assumeIsolated { self?.receiveCapabilities(result, request: request) }
        }))
    }
    public func confirm(promptID: UUID) {
        guard let request = active, let prompt = pendingPrompt, prompt.id == promptID,
            prompt.context == request.context, matches(request, phase: .waiting),
            accountID == request.context.accountID, let provider else { return }
        phase = .confirming; isConfirming = true
        let lease = MetaDisposable(); nativeLease = lease
        startDeadline(request: request, phase: .confirming)
        guard matches(request, phase: .confirming) else { return }
        lease.set((provider.createConsent(context: request.context, perMessageStars: prompt.perMessageStars,
            consentID: prompt.id) |> deliverOnMainQueue).start(next: { [weak self] result in
            MainActor.assumeIsolated { self?.receiveConsent(result, request: request, prompt: prompt) }
        }))
    }
    public func cancel() { finish(.failure(.cancelled)) }
    public func cancel(promptID: UUID) {
        guard pendingPrompt?.id == promptID else { return }
        cancel()
    }
    func cancel(context: TelegramSendContext) {
        guard active?.context == context else { return }
        cancel()
    }
    public func dispose() { bind(provider: nil, accountID: nil) }

    private func receiveCapabilities(_ result: Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError>,
        request: Request) {
        guard matches(request, phase: .loading) else { return }
        clearNative()
        switch result {
        case let .failure(error): finish(.failure(error == .incompatible ? .incompatible : .unavailable))
        case let .success(value):
            guard value.accountID == request.context.accountID, value.chatID == request.context.chatID else {
                finish(.failure(.incompatible)); return
            }
            switch value.messageFee {
            case .free: finish(.success(nil))
            case .unavailable: finish(.failure(.unavailable))
            case let .stars(price):
                guard let total = telegramPaidSendTotal(price: price, count: request.context.messageCount) else {
                    finish(.failure(.incompatible)); return
                }
                pendingPrompt = .init(id: UUID(), context: request.context, title: request.title,
                    perMessageStars: price, totalStars: total)
                phase = .waiting
            }
        }
    }
    private func receiveConsent(_ result: Result<TelegramPaidSendConsent, TelegramPaidSendConsentError>,
        request: Request, prompt: TelegramSendApprovalPrompt) {
        guard matches(request, phase: .confirming), pendingPrompt == prompt else { return }
        switch result {
        case let .failure(error): finish(.failure(error == .incompatible ? .incompatible : .stale))
        case let .success(consent):
            guard consent.id == prompt.id, consent.context == request.context,
                consent.perMessageStars == prompt.perMessageStars, consent.totalStars == prompt.totalStars else {
                finish(.failure(.incompatible)); return
            }
            finish(.success(consent))
        }
    }
    private func matches(_ request: Request, phase: Phase) -> Bool {
        active?.id == request.id && binding == request.binding && self.phase == phase
            && accountID == request.context.accountID
    }
    private func startDeadline(request: Request, phase: Phase) {
        deadlineLease?.dispose()
        let lease = MetaDisposable(); deadlineLease = lease
        lease.set(scheduleDeadline { [weak self] in
            guard let self, self.matches(request, phase: phase) else { return }
            self.finish(.failure(.timeout))
        })
    }
    private func clearNative() {
        nativeLease?.dispose(); nativeLease = nil
        deadlineLease?.dispose(); deadlineLease = nil
    }
    private func clear() -> ((Result<TelegramPaidSendConsent?, TelegramSendApprovalError>) -> Void)? {
        let completion = active?.completion
        active = nil; phase = nil; pendingPrompt = nil; isConfirming = false
        clearNative()
        return completion
    }
    private func finish(_ result: Result<TelegramPaidSendConsent?, TelegramSendApprovalError>) {
        clear()?(result)
    }
}
