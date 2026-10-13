import Foundation
import Combine
import CryptoKit
import CoreGraphics
import ImageIO
import Postbox
import TelegramCore

public enum TelegramAvatarKind: String, Sendable { case main, fallback }
public struct TelegramAvatarTarget: Equatable, Hashable, Sendable {
    public let accountID: Int64, peerID: Int64
    public let kind: TelegramAvatarKind
    public init(accountID: Int64, peerID: Int64, kind: TelegramAvatarKind) {
        self.accountID = accountID; self.peerID = peerID; self.kind = kind
    }
    var isValid: Bool {
        guard telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser,
              let peer = telegramManagementPeerID(peerID) else { return false }
        return kind == .fallback ? peerID == accountID : peer.namespace != Namespaces.Peer.CloudUser || peerID == accountID
    }
}
public struct TelegramAvatarSnapshot: Equatable, Sendable {
    public let target: TelegramAvatarTarget
    public let title: String
    public let photoID: Int64?
    public let canEdit: Bool
    var isValid: Bool {
        target.isValid && !title.isEmpty && title.utf16.count <= 512 && !title.contains("\0") && (photoID.map { $0 > 0 } ?? true)
    }
}
public struct TelegramAvatarPhoto: @unchecked Sendable {
    let bytes: Data
    public let preview: TelegramImagePreview
    let sha256: String
    private init(bytes: Data, image: CGImage) {
        self.bytes = bytes; preview = .init(image: image, originalExtension: "jpg")
        sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    var isValid: Bool {
        guard bytes.count > 0, bytes.count <= 2 * 1024 * 1024,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256,
              preview.image.width == preview.image.height, (40...640).contains(preview.image.width),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == preview.image.width,
              (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == preview.image.height else { return false }
        return [kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary].allSatisfy { props[$0] == nil }
    }
    /// Uses the immutable decoded selection shown to the user, never reopens a mutable original.
    public static func prepare(preview: TelegramImagePreview, crop: CGRect,
                               transform: TelegramUploadVideoCoverTransform = .init()) throws -> Self {
        guard [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite), crop.minX >= 0, crop.minY >= 0,
              crop.width > 0, crop.height > 0, crop.maxX <= 1, crop.maxY <= 1,
              preview.image.width <= 8192, preview.image.height <= 8192,
              preview.image.width * preview.image.height <= 40_000_000 else { throw TelegramUploadFileError.invalidImage }
        let size = transform.imageSize(CGSize(width: preview.image.width, height: preview.image.height))
        let selectedWidth = crop.width * size.width, selectedHeight = crop.height * size.height
        // The reference crop canvas rounds its fitted dimensions up. Snap its
        // near-square selection to one integer side before the renderer rounds.
        guard abs(selectedWidth - selectedHeight) <= max(1, max(selectedWidth, selectedHeight) * 0.005) else { throw TelegramUploadFileError.invalidImage }
        let x = (crop.minX * size.width).rounded(), y = (crop.minY * size.height).rounded()
        let side = min(selectedWidth.rounded(), selectedHeight.rounded(), size.width - x, size.height - y)
        let snapped = CGRect(x: x / size.width, y: y / size.height, width: side / size.width, height: side / size.height)
        let image = try transform.render(preview.image, crop: snapped, maximumPixelSize: 640)
        guard image.width == image.height, image.width >= 40, let data = TelegramUploadJPEGEncoder.encode(image) else { throw TelegramUploadFileError.invalidImage }
        let result = Self(bytes: data, image: image)
        guard result.isValid else { throw TelegramUploadFileError.invalidImage }
        return result
    }
}
public struct TelegramAvatarDraft: Identifiable {
    public let id = UUID()
    public let basis: TelegramAvatarSnapshot
    public let photo: TelegramAvatarPhoto?
}
enum TelegramAvatarError: Error, Equatable { case failed, changed, unavailable, uncertain }
enum TelegramAvatarEditingEvent { case progress(Float), committing, saved(TelegramAvatarSnapshot), failed(TelegramAvatarError) }
@MainActor protocol TelegramAvatarEditingRequest: AnyObject { func cancel() }
@MainActor protocol TelegramAvatarEditingProvider: AnyObject {
    var accountID: Int64 { get }
    func load(target: TelegramAvatarTarget, receive: @escaping @MainActor (Result<TelegramAvatarSnapshot, TelegramAvatarError>) -> Void) -> any TelegramAvatarEditingRequest
    func apply(basis: TelegramAvatarSnapshot, photo: TelegramAvatarPhoto?, receive: @escaping @MainActor (TelegramAvatarEditingEvent) -> Bool) -> any TelegramAvatarEditingRequest
}

@MainActor public final class TelegramAvatarEditingController: ObservableObject {
    public enum Phase: Equatable { case idle, uploading, committing, saved, changed, failed, uncertain }
    @Published public private(set) var snapshot: TelegramAvatarSnapshot?
    @Published public private(set) var draft: TelegramAvatarDraft?
    @Published public private(set) var status: TelegramSearchStatus = .idle
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var progress: Float = 0
    @Published public private(set) var contextID = UUID()
    public var accountID: Int64? { provider?.accountID }
    public var isBusy: Bool { phase == .uploading || phase == .committing }
    private var provider: (any TelegramAvatarEditingProvider)?
    private var target: TelegramAvatarTarget?
    private var read: (any TelegramAvatarEditingRequest)?, write: (any TelegramAvatarEditingRequest)?
    private var readID: UUID?, writeID: UUID?
    private var readDeadline: Task<Void, Never>?, writeDeadline: Task<Void, Never>?
    private var uncertain = Set<TelegramAvatarTarget>()
    public init() {}
    isolated deinit { read?.cancel(); write?.cancel(); readDeadline?.cancel(); writeDeadline?.cancel() }
    func bind(_ provider: (any TelegramAvatarEditingProvider)?) { close(); self.provider = provider }
    public func open(_ target: TelegramAvatarTarget) {
        close()
        guard target.isValid, provider?.accountID == target.accountID else { status = .failed; return }
        self.target = target; phase = uncertain.contains(target) ? .uncertain : .idle; load(reconcile: false)
    }
    public func close() {
        if phase == .committing, let target { uncertain.insert(target) }
        readID = nil; writeID = nil; contextID = UUID()
        read?.cancel(); write?.cancel(); read = nil; write = nil
        readDeadline?.cancel(); writeDeadline?.cancel(); readDeadline = nil; writeDeadline = nil
        target = nil; snapshot = nil; draft = nil; status = .idle; phase = .idle; progress = 0
    }
    public func refresh() { guard !isBusy else { return }; draft = nil; contextID = UUID(); load(reconcile: true) }
    private func load(reconcile: Bool) {
        readID = nil; read?.cancel(); read = nil; readDeadline?.cancel()
        guard let provider, let target else { status = .failed; return }
        let token = UUID(), context = contextID; readID = token; status = .loading
        readDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.readID == token else { return }
            self.readID = nil; self.read?.cancel(); self.read = nil; self.status = .timedOut
        }
        let request = provider.load(target: target) { [weak self] result in
            guard let self, self.readID == token, self.contextID == context, self.provider?.accountID == target.accountID else { return }
            self.readID = nil; self.readDeadline?.cancel(); self.readDeadline = nil; self.read?.cancel(); self.read = nil
            guard case let .success(value) = result, value.target == target, value.isValid else { self.status = .failed; return }
            self.snapshot = value; self.status = .ready
            if reconcile { self.uncertain.remove(target); self.phase = .idle }
        }
        if readID == token { read = request } else { request.cancel() }
    }
    private func canStage(_ context: UUID) -> Bool {
        context == contextID && status == .ready && !isBusy && phase != .uncertain && snapshot?.canEdit == true
            && snapshot?.target == target && snapshot?.target.accountID == provider?.accountID
    }
    @discardableResult public func stage(_ photo: TelegramAvatarPhoto, contextID: UUID) -> Bool {
        guard canStage(contextID), photo.isValid, let snapshot else { return false }
        draft = .init(basis: snapshot, photo: photo); return true
    }
    @discardableResult public func stageRemoval(contextID: UUID) -> Bool {
        guard canStage(contextID), let snapshot, snapshot.photoID != nil else { return false }
        draft = .init(basis: snapshot, photo: nil); return true
    }
    public func discardDraft() { guard !isBusy else { return }; draft = nil }
    public func cancelUpload() { guard phase == .uploading else { return }; finish(.idle); progress = 0 }
    @discardableResult public func apply(draftID: UUID, contextID: UUID) -> Bool {
        guard canStage(contextID), let provider, let draft, draft.id == draftID, draft.basis == snapshot else { return false }
        let token = UUID(); writeID = token; phase = .uploading; progress = 0
        writeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard let self, self.writeID == token else { return }; self.timeoutMutation()
        }
        let request = provider.apply(basis: draft.basis, photo: draft.photo) { [weak self] event in
            guard let self, self.writeID == token, self.contextID == contextID, self.provider?.accountID == draft.basis.target.accountID else { return false }
            switch event {
            case let .progress(value):
                guard self.phase == .uploading, value.isFinite, (0...1).contains(value) else { self.finish(.failed); return false }
                self.progress = value
            case .committing:
                guard self.phase == .uploading else { return false }; self.phase = .committing
            case let .saved(value):
                guard self.phase == .committing, value.isValid, value.target == draft.basis.target,
                      draft.photo == nil ? value.photoID == nil : (value.photoID != nil && value.photoID != draft.basis.photoID) else {
                    self.markUncertain(); return true
                }
                self.snapshot = value; self.draft = nil; self.finish(.saved)
            case let .failed(error):
                if self.phase == .committing || error == .uncertain { self.markUncertain() }
                else { self.finish(error == .changed ? .changed : .failed) }
            }
            return true
        }
        if writeID == token { write = request } else { request.cancel() }
        return true
    }
    private func finish(_ phase: Phase) {
        writeID = nil; write?.cancel(); write = nil; writeDeadline?.cancel(); writeDeadline = nil; self.phase = phase
    }
    private func markUncertain() { if let target { uncertain.insert(target) }; finish(.uncertain) }
    func timeoutMutation() { guard writeID != nil else { return }; if phase == .committing { markUncertain() } else { finish(.failed) } }
}
