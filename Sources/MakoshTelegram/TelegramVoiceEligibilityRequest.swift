import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

func telegramVoiceEligibilitySnapshot(transaction: Transaction, peerID: PeerId, now: Int32,
    kind: TelegramRecordingKind = .voice) -> TelegramVoiceEligibility {
    let peer = transaction.getPeer(peerID), cache = transaction.getPeerCachedData(peerId: peerID)
    var pending = false
    if let channel = peer as? TelegramChannel, channel.isRestrictedBySlowmode {
        transaction.withAllMessages(peerId: peerID) { message in
            if message.flags.contains(.Unsent) { pending = true; return false }
            return true
        }
    }
    return telegramVoiceEligibility(peer: peer, cachedData: cache, now: now, hasPendingMessages: pending, kind: kind)
}

@MainActor final class TelegramVoiceEligibilityRequest {
    private let subscription = MetaDisposable()
    private var requestID: UUID?
    private var continuation: CheckedContinuation<TelegramVoiceEligibility, Never>?
    private var deadline: Task<Void, Never>?
    isolated deinit { subscription.dispose(); deadline?.cancel(); continuation?.resume(returning: .unavailable) }
    func check(account: Account, target: TelegramUploadTarget, isOneTime: Bool = false,
        kind: TelegramRecordingKind = .voice) async -> TelegramVoiceEligibility {
        guard account.peerId.toInt64() == target.accountID else { return .unavailable }
        return await check(signal: telegramVoiceEligibilitySignal(account: account, peerID: PeerId(target.chatID),
            isOneTime: isOneTime, kind: kind))
    }
    func check(signal: Signal<TelegramVoiceEligibility, NoError>) async -> TelegramVoiceEligibility {
        cancel()
        guard !Task.isCancelled else { return .unavailable }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .unavailable); return }
                self.continuation = continuation; requestID = id
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.finish(.unavailable, id: id)
                }
                let lease = (signal |> take(1) |> deliverOnMainQueue).start(next: { [weak self] value in
                    MainActor.assumeIsolated { self?.finish(value, id: id) }
                })
                if requestID == id { subscription.set(lease) } else { lease.dispose() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.unavailable, id: id) }
        }
    }
    func cancel() { if let id = requestID { finish(.unavailable, id: id) } }
    private func finish(_ value: TelegramVoiceEligibility, id: UUID) {
        guard requestID == id else { return }
        requestID = nil; deadline?.cancel(); deadline = nil; subscription.set(nil)
        let waiting = continuation; continuation = nil; waiting?.resume(returning: value)
    }
}

private func telegramVoiceEligibilitySignal(account: Account, peerID: PeerId, isOneTime: Bool,
    kind: TelegramRecordingKind) -> Signal<TelegramVoiceEligibility, NoError> {
    account.postbox.transaction { transaction in
        let timestamp = Date().timeIntervalSince1970 + account.network.globalTimeDifference
        guard timestamp.isFinite, timestamp >= Double(Int32.min), timestamp < Double(Int32.max) else { return .unavailable }
        if isOneTime {
            return telegramVoiceOnceEligibility(peer: transaction.getPeer(peerID), cachedData: transaction.getPeerCachedData(peerId: peerID),
                accountID: account.peerId.toInt64(), now: Int32(timestamp), kind: kind)
        }
        return telegramVoiceEligibilitySnapshot(transaction: transaction, peerID: peerID, now: Int32(timestamp), kind: kind)
    }
}
