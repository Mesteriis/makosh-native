import XCTest
import AVFoundation
import AppKit
import CryptoKit
@testable import MakoshTelegram

@MainActor final class TelegramCallPresentationTests: XCTestCase {
    private final class Sound: TelegramCallTonePlayer {
        var tones: [TelegramCallTone] = [], stopped = 0
        func play(_ tone:TelegramCallTone) { tones.append(tone) }
        func stop() { stopped += 1 }
    }
    private func snapshot(_ phase:TelegramCallSnapshot.Phase,ringing:Bool = false) -> TelegramCallSnapshot {
        .init(id:UUID(),accountID:1,peerID:2,title:"Synthetic",outgoing:true,phase:phase,ringing:ringing)
    }
    func testCallKeyKnownVectors() {
        XCTAssertEqual(TelegramCallKey.emoji(Data(repeating:0,count:32)),"😉😉😉😉")
        XCTAssertEqual(TelegramCallKey.emoji(Data(repeating:255,count:32)),"💍💍💍💍")
        XCTAssertEqual(TelegramCallKey.emoji(Data((0..<32).map(UInt8.init))),"💍☔️📅🍞")
        XCTAssertNil(TelegramCallKey.emoji(Data(repeating:0,count:31)))
        XCTAssertNil(TelegramCallKey.emoji(Data(repeating:0,count:33)))
        XCTAssertEqual(SHA256.hash(data:Data(TelegramCallEmojiTable.values.joined(separator:"\n").utf8)).map { String(format:"%02x",$0) }.joined(),"c22c3a00d5a68df075fecc8cb8b730a45817a246a5ca70fa3b75d248ac5b54e9")
    }
    func testRingtoneStopsOnConnectEndAndOwnerLoss() {
        let sound = Sound(); var owner: TelegramCallRingtone? = .init(player:sound)
        let incoming = TelegramIncomingCall(id:UUID(),accountID:1,peerID:2,title:"Synthetic",isVideo:false)
        owner?.update(call:nil,incoming:[incoming],ready:false); XCTAssertTrue(sound.tones.isEmpty)
        owner?.update(call:nil,incoming:[incoming],ready:true); XCTAssertEqual(sound.tones,[.incoming])
        owner?.update(call:nil,incoming:[incoming],ready:true); XCTAssertEqual(sound.tones.count,1)
        owner?.update(call:snapshot(.connecting),incoming:[],ready:true); XCTAssertNil(owner?.tone)
        owner?.update(call:snapshot(.requesting,ringing:true),incoming:[],ready:true); XCTAssertEqual(sound.tones,[.incoming,.ringback])
        owner?.update(call:snapshot(.connected),incoming:[],ready:true); XCTAssertNil(owner?.tone)
        owner?.update(call:nil,incoming:[incoming],ready:true); owner?.update(call:nil,incoming:[],ready:true); XCTAssertNil(owner?.tone)
        owner?.update(call:nil,incoming:[incoming],ready:true); let before = sound.stopped
        owner = nil; XCTAssertEqual(sound.stopped,before+1)
    }
    func testActualSyntheticRingtoneIsBoundedPlayablePCMWithoutPersonalAsset() async throws {
        for tone:TelegramCallTone in [.incoming,.ringback] {
            let data = TelegramCallRingtone.wave(tone)
            XCTAssertLessThanOrEqual(data.count,128_044)
            XCTAssertEqual(String(data:data.prefix(4),encoding:.ascii),"RIFF")
            XCTAssertNotNil(NSSound(data:data))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
            defer { try? FileManager.default.removeItem(at:url) }
            try data.write(to:url)
            let asset = TelegramNativePlaybackEngine.restrictedAsset(file:url)
            let playable = try await asset.load(.isPlayable), duration = try await asset.load(.duration).seconds
            XCTAssertTrue(playable); XCTAssertEqual(duration,2,accuracy:0.01)
        }
    }
    func testVideoControlsRevealWithKeyboardAndVoiceOver() {
        let p = TelegramCallVideoPresentation(), id = UUID()
        p.update(callID:id,videoConnected:true,voiceOver:false,now:0)
        p.expire(now:2.9); XCTAssertTrue(p.controlsVisible)
        p.expire(now:3); XCTAssertFalse(p.controlsVisible)
        p.activity(now:4); XCTAssertTrue(p.controlsVisible)
        p.expire(now:6.9); XCTAssertTrue(p.controlsVisible)
        p.update(callID:id,videoConnected:true,voiceOver:true,now:7)
        p.expire(now:100); XCTAssertTrue(p.controlsVisible)
        p.update(callID:id,videoConnected:false,voiceOver:false,now:101)
        p.expire(now:1000); XCTAssertTrue(p.controlsVisible)
        p.stop(); XCTAssertTrue(p.controlsVisible)
    }
    func testPreviewClampsAfterResizeAndInvalidGeometry() {
        let p = TelegramCallVideoPresentation()
        let preview = CGSize(width:96,height:72), container = CGSize(width:358,height:477)
        XCTAssertEqual(p.origin(in:container,preview:preview),CGPoint(x:250,y:12))
        p.move(to:CGPoint(x:-100,y:1000),in:container,preview:preview)
        XCTAssertEqual(p.corner,.bottomLeading)
        XCTAssertEqual(p.origin(in:CGSize(width:100,height:80),preview:preview),CGPoint(x:2,y:4))
        XCTAssertEqual(p.origin(in:CGSize(width:CGFloat.infinity,height:100),preview:preview),.zero)
    }
    func testReduceMotionStopsDecorationAndHiddenWindowDoesNotAnimate() {
        XCTAssertTrue(TelegramCallDecoration.animates(active:true,visible:true,enabled:true,reduceMotion:false))
        for (active,visible,enabled,reduced) in [(false,true,true,false),(true,false,true,false),(true,true,false,false),(true,true,true,true)] {
            XCTAssertFalse(TelegramCallDecoration.animates(active:active,visible:visible,enabled:enabled,reduceMotion:reduced))
        }
        for phase in stride(from:0.0,through:100.0,by:0.5) {
            let radius = TelegramCallDecoration.radius(angle:phase,phase:phase,base:64)
            XCTAssertTrue(radius.isFinite); XCTAssertGreaterThanOrEqual(radius,64); XCTAssertLessThanOrEqual(radius,80)
        }
    }
}
