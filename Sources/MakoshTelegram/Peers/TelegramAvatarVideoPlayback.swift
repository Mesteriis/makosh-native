import Foundation
import Combine
import AVFoundation

enum TelegramAvatarVideoEvent: Sendable {
    case resource(String?,start:Double)
    case data(resourceID:String,url:URL,size:Int64)
    case failed(resourceID:String)
}
@MainActor final class TelegramAvatarVideoFeed {
    @MainActor private final class Job {
        let continuation: AsyncStream<TelegramAvatarVideoEvent>.Continuation
        var lease: (any TelegramAvatarLease)?, deadline: Task<Void,Never>?
        var resource: String?, acceptsData = false
        init(_ continuation:AsyncStream<TelegramAvatarVideoEvent>.Continuation) { self.continuation = continuation }
        func stop() { deadline?.cancel(); lease?.cancel(); continuation.finish() }
    }
    private var provider: (any TelegramAvatarProvider)?
    private var jobs: [UUID:Job] = [:]
    isolated deinit { for job in jobs.values { job.stop() } }
    func bind(_ provider:(any TelegramAvatarProvider)?) {
        let old = jobs; jobs = [:]; self.provider = provider
        for job in old.values { job.stop() }
    }
    func events(peerID:Int64) -> AsyncStream<TelegramAvatarVideoEvent> {
        let (stream,continuation) = AsyncStream<TelegramAvatarVideoEvent>.makeStream(bufferingPolicy:.bufferingNewest(2))
        guard let provider,jobs.count < 4 else { continuation.finish(); return stream }
        let token = UUID(),job = Job(continuation); jobs[token] = job
        continuation.onTermination = { [weak self] _ in Task { @MainActor [weak self] in self?.remove(token) } }
        let lease = provider.startVideo(key:.init(peerID:peerID,size:.large)) { [weak self] event in self?.receive(event,token:token) }
        if jobs[token] === job,let lease { job.lease = lease }
        else { lease?.cancel(); remove(token) }
        return stream
    }
    private func receive(_ event:TelegramAvatarVideoEvent,token:UUID) {
        guard let job = jobs[token] else { return }
        switch event {
        case let .resource(id,start):
            job.deadline?.cancel(); job.deadline = nil; job.resource = nil; job.acceptsData = false
            guard start.isFinite,(0...30).contains(start),id.map({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }) ?? true else {
                job.continuation.yield(.resource(nil,start:0)); return
            }
            job.resource = id; job.acceptsData = id != nil; job.continuation.yield(event)
            if let id {
                job.deadline = Task { [weak self] in
                    do { try await Task.sleep(for:.seconds(30)) } catch { return }
                    self?.receive(.failed(resourceID:id),token:token)
                }
            }
        case let .data(id,url,size):
            guard job.resource == id,job.acceptsData else { return }
            job.acceptsData = false; job.deadline?.cancel(); job.deadline = nil
            guard (1...16_777_216).contains(size),url.isFileURL else { job.continuation.yield(.resource(nil,start:0)); return }
            job.continuation.yield(event)
        case let .failed(id):
            guard job.resource == id else { return }
            job.acceptsData = false; job.deadline?.cancel(); job.deadline = nil
            job.continuation.yield(.resource(nil,start:0))
        }
    }
    private func remove(_ token:UUID) { jobs.removeValue(forKey:token)?.stop() }
}

/// Window-owned muted loop. Decoder teardown precedes deleting its private copy;
/// account/resource changes revoke old loads before a replacement can publish.
@MainActor public final class TelegramAvatarVideoPlayback: ObservableObject {
    @MainActor private final class Lifetime {
        private var finished = false
        private var continuation: CheckedContinuation<Void,Never>?
        func wait() async { if !finished { await withCheckedContinuation { continuation = $0 } } }
        func finish() { finished = true; let old = continuation; continuation = nil; old?.resume() }
    }
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var error: String?
    private let makeEngine: @MainActor () -> any TelegramPlaybackEngine
    private var reader: Task<Void,Never>?, worker: Task<Void,Never>?, deadline: Task<Void,Never>?
    private var engine: (any TelegramPlaybackEngine)?, lifetime: Lifetime?
    private var session = UUID(), operation = UUID(), resource: String?, start = 0.0
    public init() { makeEngine = { TelegramNativePlaybackEngine(keepsItemAtEnd:true,muted:true,maximumDuration:30,maximumVideoDimension:1024) } }
    init(makeEngine:@escaping @MainActor () -> any TelegramPlaybackEngine) { self.makeEngine = makeEngine }
    isolated deinit { reader?.cancel(); worker?.cancel(); deadline?.cancel(); engine?.stop(); lifetime?.finish() }
    public func open(store:TelegramAvatarStore,peerID:Int64) {
        stop(); error = nil; let id = session,accountContext = store.contextID
        let events = store.videoFeed.events(peerID:peerID)
        reader = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled,store.contextID == accountContext,self?.session == id else { break }
                self?.receive(event,session:id)
            }
            if self?.session == id { self?.stop() }
        }
    }
    public func stop() {
        session = UUID(); reader?.cancel(); reader = nil; resource = nil; stopPlayback()
    }
    private func stopPlayback() {
        operation = UUID(); worker?.cancel(); worker = nil; deadline?.cancel(); deadline = nil
        engine?.stop(); engine = nil; player = nil; lifetime?.finish(); lifetime = nil
    }
    private func receive(_ event:TelegramAvatarVideoEvent,session:UUID) {
        guard self.session == session else { return }
        switch event {
        case let .resource(id,start): stopPlayback(); resource = id; self.start = start
        case let .failed(id): if resource == id { stopPlayback() }
        case let .data(id,url,size):
            guard resource == id,worker == nil else { return }
            let token = UUID(),engine = makeEngine(),lifetime = Lifetime(),start = self.start
            operation = token; self.engine = engine; self.lifetime = lifetime
            deadline = Task { [weak self] in
                do { try await Task.sleep(for:.seconds(30)) } catch { return }
                if self?.operation == token { self?.stopPlayback() }
            }
            worker = Task { [weak self] in
                var file: TelegramPlaybackFile?
                defer {
                    engine.stop()
                    if let file { do { try TelegramPlaybackFileIO.discard(file) } catch { self?.error = "Не удалось удалить временную копию видеоаватара." } }
                }
                do {
                    file = try await TelegramPlaybackFileIO.prepare(source:url,expectedSize:size)
                    try Task.checkCancellation()
                    guard self?.operation == token,let file else { return }
                    let info = try await engine.load(file:file.url,kind:.video) { [weak self] event in
                        guard let self,self.operation == token else { return }
                        switch event {
                        case .ended: engine.seek(seconds:start); engine.play(rate:1)
                        case .failed: self.stopPlayback()
                        default: break
                        }
                    }
                    try Task.checkCancellation()
                    guard info.hasVideo,info.duration.isFinite,(0...30).contains(info.duration),info.duration > start,
                          self?.operation == token,let player = engine.player else { throw TelegramNativePlaybackError.unavailable }
                    engine.setVolume(0); player.isMuted = true; engine.seek(seconds:start)
                    if let self,self.operation == token {
                        self.player = player; self.deadline?.cancel(); self.deadline = nil
                        engine.play(rate:1)
                    }
                    await lifetime.wait()
                } catch { if self?.operation == token { self?.stopPlayback(); if !(error is CancellationError) { self?.error = "Не удалось воспроизвести видеоаватар." } } }
            }
        }
    }
}
