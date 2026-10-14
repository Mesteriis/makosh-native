import Foundation
import Combine
import AppKit

public enum TelegramCallKey {
    /// Four signed-positive big-endian64bit blocks of the native visual hash.
    public static func emoji(_ hash:Data) -> String? {
        guard hash.count == 32,TelegramCallEmojiTable.values.count == 333 else { return nil }
        let bytes = Array(hash)
        return (0..<4).map { block in
            var value = UInt64(bytes[block*8]&0x7f)
            for offset in 1..<8 { value = (value<<8)|UInt64(bytes[block*8+offset]) }
            return TelegramCallEmojiTable.values[Int(value%333)]
        }.joined()
    }
}
public enum TelegramCallTone: Sendable { case incoming, ringback }
@MainActor protocol TelegramCallTonePlayer: AnyObject {
    func play(_ tone:TelegramCallTone)
    func stop()
}
@MainActor public final class TelegramCallRingtone {
    public private(set) var tone: TelegramCallTone?
    private let player: any TelegramCallTonePlayer
    public init() { player = NativeCallTonePlayer() }
    init(player:any TelegramCallTonePlayer) { self.player = player }
    isolated deinit { player.stop() }
    public func update(call:TelegramCallSnapshot?,incoming:[TelegramIncomingCall],ready:Bool) {
        let next: TelegramCallTone?
        if let call,call.isActive { next = call.outgoing && call.phase == .requesting && call.ringing ? .ringback : nil }
        else { next = ready && !incoming.isEmpty ? .incoming : nil }
        guard tone != next else { return }
        player.stop(); tone = next
        if let next { player.play(next) }
    }
    public func stop() { tone = nil; player.stop() }
    /// Original mono PCM, two seconds; no borrowed notification/sound asset.
    public nonisolated static func wave(_ tone:TelegramCallTone) -> Data {
        let rate = 16_000,count = 32_000
        var data = Data(); data.reserveCapacity(44+count*2)
        func ascii(_ value:String) { data.append(contentsOf:value.utf8) }
        func word<T:FixedWidthInteger>(_ value:T) { var n = value.littleEndian; withUnsafeBytes(of:&n) { data.append(contentsOf:$0) } }
        ascii("RIFF"); word(UInt32(36+count*2)); ascii("WAVEfmt "); word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate*2)); word(UInt16(2)); word(UInt16(16)); ascii("data"); word(UInt32(count*2))
        for i in 0..<count {
            let time = Double(i)/Double(rate), interval = tone == .incoming ? time.truncatingRemainder(dividingBy:0.6) : time
            let on = tone == .incoming ? (time < 1.2 && interval < 0.4) : time < 0.8
            let envelope = on ? min(1,interval/0.015)*min(1,((tone == .incoming ? 0.4 : 0.8)-interval)/0.015) : 0
            let a = tone == .incoming ? 660.0 : 440.0,b = tone == .incoming ? 880.0 : 480.0
            let sample = envelope*0.09*(sin(2*Double.pi*a*time)+sin(2*Double.pi*b*time))
            word(Int16((sample*32767).rounded()))
        }
        return data
    }
}
@MainActor private final class NativeCallTonePlayer: TelegramCallTonePlayer {
    private var sound: NSSound?
    func play(_ tone:TelegramCallTone) {
        stop(); let value = NSSound(data:TelegramCallRingtone.wave(tone))
        value?.loops = true; sound = value; _ = value?.play()
    }
    func stop() { sound?.stop(); sound = nil }
    isolated deinit { sound?.stop() }
}

public enum TelegramCallPreviewCorner: String, CaseIterable, Sendable { case topLeading, topTrailing, bottomLeading, bottomTrailing }
@MainActor public final class TelegramCallVideoPresentation: ObservableObject {
    @Published public private(set) var controlsVisible = true
    @Published public private(set) var corner = TelegramCallPreviewCorner.topTrailing
    private var callID: UUID?, videoConnected = false, voiceOver = false
    private var lastActivity: TimeInterval = 0
    private var deadline: Task<Void,Never>?
    public init() {}
    isolated deinit { deadline?.cancel() }
    public func update(callID:UUID?,videoConnected:Bool,voiceOver:Bool,now:TimeInterval = Date.timeIntervalSinceReferenceDate) {
        guard now.isFinite else { return }
        let changed = self.callID != callID || self.videoConnected != videoConnected || self.voiceOver != voiceOver
        if self.callID != callID { corner = .topTrailing }
        self.callID = callID; self.videoConnected = videoConnected; self.voiceOver = voiceOver
        if changed { activity(now:now) }
    }
    public func activity(now:TimeInterval = Date.timeIntervalSinceReferenceDate) {
        guard now.isFinite else { return }; controlsVisible = true; lastActivity = now
        deadline?.cancel(); deadline = nil
        guard videoConnected,!voiceOver,callID != nil else { return }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(3)) } catch { return }
            self?.expire(now:Date.timeIntervalSinceReferenceDate)
        }
    }
    public func expire(now:TimeInterval) {
        guard now.isFinite,videoConnected,!voiceOver,callID != nil,now-lastActivity >= 3 else { return }
        controlsVisible = false
    }
    public func stop() { deadline?.cancel(); deadline = nil; callID = nil; videoConnected = false; controlsVisible = true }
    public func select(_ corner:TelegramCallPreviewCorner) { self.corner = corner; activity() }
    public func origin(in container:CGSize,preview:CGSize) -> CGPoint {
        guard [container.width,container.height,preview.width,preview.height].allSatisfy({ $0.isFinite && $0 > 0 }) else { return .zero }
        let x = max(0,container.width-preview.width),y = max(0,container.height-preview.height)
        return CGPoint(x:[.topLeading,.bottomLeading].contains(corner) ? min(12,x/2) : max(0,x-min(12,x/2)),
            y:[.topLeading,.topTrailing].contains(corner) ? min(12,y/2) : max(0,y-min(12,y/2)))
    }
    public func move(to point:CGPoint,in container:CGSize,preview:CGSize) {
        guard [point.x,point.y,container.width,container.height,preview.width,preview.height].allSatisfy(\.isFinite),container.width > 0,container.height > 0 else { return }
        let left = point.x+preview.width/2 < container.width/2,top = point.y+preview.height/2 < container.height/2
        corner = top ? (left ? .topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing); activity()
    }
}
public enum TelegramCallDecoration {
    public static func animates(active:Bool,visible:Bool,enabled:Bool,reduceMotion:Bool) -> Bool { active && visible && enabled && !reduceMotion }
    public static func radius(angle:Double,phase:Double,base:Double) -> Double {
        guard angle.isFinite,phase.isFinite,base.isFinite,base > 0 else { return 0 }
        return base+8+4*sin(3*angle+phase)+4*sin(5*angle-phase*0.7)
    }
}
