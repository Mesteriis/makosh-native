import XCTest
import AVFoundation
import Combine
import TelegramCore
import Postbox
@testable import MakoshTelegram

@MainActor final class TelegramAvatarVideoTests: XCTestCase {
    private final class Lease: TelegramAvatarLease { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramAvatarProvider {
        var video: [@MainActor (TelegramAvatarVideoEvent)->Void] = []
        var leases: [Lease] = []
        func start(key:TelegramAvatarKey,receive:@escaping @MainActor (TelegramAvatarEvent)->Void) -> any TelegramAvatarLease { Lease() }
        func startVideo(key:TelegramAvatarKey,receive:@escaping @MainActor (TelegramAvatarVideoEvent)->Void) -> (any TelegramAvatarLease)? {
            video.append(receive); let lease = Lease(); leases.append(lease); return lease
        }
    }
    private final class Engine: TelegramPlaybackEngine {
        let player: AVPlayer? = AVPlayer()
        var calls: [String] = [], file: URL?, receive: (@MainActor (TelegramPlaybackEvent)->Void)?
        var pending: CheckedContinuation<TelegramPlaybackInfo,Error>?
        var delay = false
        var didLoad: (() -> Void)?
        func load(file:URL,kind:TelegramPlaybackKind,receive:@escaping @MainActor (TelegramPlaybackEvent)->Void) async throws -> TelegramPlaybackInfo {
            self.file = file; self.receive = receive; calls.append("load")
            if delay { return try await withCheckedThrowingContinuation { pending = $0; didLoad?() } }
            didLoad?(); return .init(duration:2,hasVideo:true)
        }
        func play(rate:Float) { calls.append("play") }
        func pause() { calls.append("pause") }
        func seek(seconds:Double) { calls.append("seek:\(seconds)") }
        func setVolume(_ volume:Float) { calls.append("volume:\(volume)") }
        func stop() { calls.append("stop") }
    }
    private func file() throws -> (URL,Int64) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("0000ftypowned-synthetic-video".utf8).write(to:url)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return (url,Int64(try Data(contentsOf:url).count))
    }
    func testVideoAvatarStaleResourceCannotPublishAndMutedLoopStopsOnOwnerLoss() async throws {
        let source = try file(),store = TelegramAvatarStore(),provider = Provider()
        store.bind(provider)
        let first = Engine(),second = Engine(); first.delay = true
        var engines = [first,second]
        var playback:TelegramAvatarVideoPlayback? = .init(makeEngine:{ engines.removeFirst() })
        playback?.open(store:store,peerID:42)
        let waiting = expectation(description:"First decoder pending"); first.didLoad = { waiting.fulfill() }
        provider.video[0](.resource("old",start:0)); provider.video[0](.data(resourceID:"old",url:source.0,size:source.1))
        await fulfillment(of:[waiting],timeout:5)
        provider.video[0](.resource("new",start:0.25))
        provider.video[0](.data(resourceID:"old",url:source.0,size:source.1))
        let loaded = expectation(description:"Replacement decoder"); second.didLoad = { loaded.fulfill() }
        provider.video[0](.data(resourceID:"new",url:source.0,size:source.1))
        await fulfillment(of:[loaded],timeout:5)
        for _ in 0..<50 where playback?.player == nil { await Task.yield() }
        XCTAssertTrue(playback?.player === second.player)
        XCTAssertEqual(second.calls.prefix(4),["load","volume:0.0","seek:0.25","play"])
        first.pending?.resume(returning:.init(duration:2,hasVideo:true)); first.pending = nil
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(playback?.player === second.player)
        second.receive?(.ended); XCTAssertEqual(Array(second.calls.suffix(2)),["seek:0.25","play"])
        let copied = try XCTUnwrap(second.file)
        weak var old = playback; playback = nil
        for _ in 0..<100 where FileManager.default.fileExists(atPath:copied.path) { await Task.yield() }
        XCTAssertNil(old); XCTAssertTrue(provider.leases[0].cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath:copied.path))
        XCTAssertEqual(second.calls.last,"stop")
    }
    func testAccountRebindStopsPublishedVideoAndLateOldDataIsIgnored() async throws {
        let source = try file(),store = TelegramAvatarStore(),first = Provider(),second = Provider(),engine = Engine()
        store.bind(first); let playback = TelegramAvatarVideoPlayback(makeEngine:{ engine })
        playback.open(store:store,peerID:42)
        let loaded = expectation(description:"Video load"); engine.didLoad = { loaded.fulfill() }
        first.video[0](.resource("a",start:0)); first.video[0](.data(resourceID:"a",url:source.0,size:source.1))
        await fulfillment(of:[loaded],timeout:5)
        for _ in 0..<50 where playback.player == nil { await Task.yield() }
        XCTAssertNotNil(playback.player)
        store.bind(second)
        first.video[0](.data(resourceID:"a",url:source.0,size:source.1))
        for _ in 0..<100 where playback.player != nil { await Task.yield() }
        XCTAssertNil(playback.player); XCTAssertTrue(first.leases[0].cancelled)
        XCTAssertEqual(engine.calls.filter { $0 == "load" }.count,1)
        playback.stop()
    }
    func testOversizeDataNeverReachesDecoderAndHiddenOwnerReleasesObservation() async {
        let store = TelegramAvatarStore(),provider = Provider(),engine = Engine(); store.bind(provider)
        let playback = TelegramAvatarVideoPlayback(makeEngine:{ engine }); playback.open(store:store,peerID:42)
        provider.video[0](.resource("a",start:0)); provider.video[0](.data(resourceID:"a",url:URL(fileURLWithPath:"/unused-owned-fixture"),size:16_777_217))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(engine.calls.isEmpty); playback.stop()
        for _ in 0..<50 where !provider.leases[0].cancelled { await Task.yield() }
        XCTAssertTrue(provider.leases[0].cancelled)
    }
    func testVideoObservationBudgetAndAccountResetReleaseEveryLease() {
        let store = TelegramAvatarStore(),provider = Provider(); store.bind(provider)
        let streams = (0..<5).map { store.videoFeed.events(peerID:Int64($0+40)) }
        XCTAssertEqual(streams.count,5); XCTAssertEqual(provider.leases.count,4)
        store.bind(nil); XCTAssertTrue(provider.leases.allSatisfy(\.cancelled))
    }
    func testOwnedSyntheticProviderFeedsActualMutedNativeVideoAvatar() async throws {
        let store = TelegramAvatarStore(); store.bind(TelegramSyntheticAvatarProvider())
        let playback = TelegramAvatarVideoPlayback()
        let ready = expectation(description:"Actual owned video-avatar decoder ready")
        let observation = playback.$player.sink { if $0 != nil { ready.fulfill() } }
        defer { observation.cancel(); playback.stop(); store.bind(nil) }
        playback.open(store:store,peerID:43)
        await fulfillment(of:[ready],timeout:5)
        let player = try XCTUnwrap(playback.player)
        XCTAssertTrue(player.isMuted); XCTAssertEqual(player.volume,0)
        XCTAssertEqual(player.currentItem?.duration.seconds ?? 0,2,accuracy:0.1)
    }
}

final class TelegramAvatarVideoMappingTests: XCTestCase {
    func testOnlyCurrentPhotoBoundedVideoResourceIsResolved() throws {
        let photoID:Int64 = 20
        let peerPhoto = TelegramMediaImageRepresentation(dimensions:.init(width:640,height:640),resource:CloudPeerPhotoSizeMediaResource(datacenterId:1,photoId:photoID,sizeSpec:.fullSize,volumeId:nil,localId:nil),progressiveSizes:[],immediateThumbnailData:nil)
        let peer = TelegramUser(id:PeerId(namespace:Namespaces.Peer.CloudUser,id:._internalFromInt64Value(42)),accessHash:.personal(1),firstName:"Synthetic",lastName:nil,username:nil,phone:nil,photo:[peerPhoto],botInfo:nil,restrictionInfo:nil,flags:[],emojiStatus:nil,usernames:[],storiesHidden:nil,nameColor:nil,backgroundEmojiId:nil,profileColor:nil,profileBackgroundEmojiId:nil,subscriberCount:nil,verificationIconFileId:nil)
        func image(_ id:Int64,size:Int64? = 100,start:Double = 0.25,resourceID:Int64? = nil) -> TelegramMediaImage {
            .init(imageId:.init(namespace:Namespaces.Media.CloudImage,id:id),representations:[peerPhoto],videoRepresentations:[.init(dimensions:.init(width:320,height:320),resource:CloudPhotoSizeMediaResource(datacenterId:1,photoId:resourceID ?? id,accessHash:1,sizeSpec:"v",size:size,fileReference:Data()),startTimestamp:start)],immediateThumbnailData:nil,reference:nil,partialReference:nil,flags:[])
        }
        let current = image(photoID),cached = CachedUserData().withUpdatedPhoto(.known(current))
        let source = try XCTUnwrap(telegramNativeVideoAvatarSource(peer:peer,cachedData:cached,photos:[]))
        XCTAssertEqual(source.start,0.25); XCTAssertEqual(source.resource.size,100)
        XCTAssertNil(telegramNativeVideoAvatarSource(peer:peer,cachedData:CachedUserData().withUpdatedPhoto(.known(image(21))),photos:[]))
        for value in [image(photoID,size:nil),image(photoID,size:16_777_217),image(photoID,start:.infinity),image(photoID,resourceID:21)] {
            XCTAssertNil(telegramNativeVideoAvatarSource(peer:peer,cachedData:CachedUserData().withUpdatedPhoto(.known(value)),photos:[]))
        }
    }
}
