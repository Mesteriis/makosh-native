import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramQRLoginTests: XCTestCase {
    private final class Request: TelegramQRLoginRequest { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramQRLoginProvider {
        var reads: [(Request, @MainActor (Result<TelegramQRLoginResult, TelegramQRLoginError>) -> Void)] = []
        var event: (@MainActor () -> Void)?
        var events = Request()
        func request(receive: @escaping @MainActor (Result<TelegramQRLoginResult, TelegramQRLoginError>) -> Void) -> any TelegramQRLoginRequest {
            let r = Request(); reads.append((r, receive)); return r
        }
        func observeEvents(receive: @escaping @MainActor () -> Void) -> any TelegramQRLoginRequest { event = receive; return events }
    }
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1000)
        var timers: [(TimeInterval, Request, @MainActor () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TelegramQRLoginRequest {
            let r = Request(); timers.append((delay, r, action)); return r
        }
    }
    private func setup() -> (TelegramQRLoginController, Provider, Clock) {
        let p = Provider(), clock = Clock()
        let c = TelegramQRLoginController(now: { clock.now }, schedule: { clock.schedule($0, $1) })
        c.bind(p); return (c, p, clock)
    }
    func testQRContainsExactURLSafeTokenWithoutPadding() throws {
        let (c,p,clock) = setup(); c.start()
        p.reads[0].1(.success(.token(Data([251,255,239]), expiresAt: clock.now.addingTimeInterval(60))))
        XCTAssertEqual(c.displayURL, "tg://login?token=-__v"); XCTAssertEqual(c.phase, .displaying)
        XCTAssertEqual(clock.timers.last?.0, 30)
    }
    func testExpiredMalformedOrUnboundedTokenNeverDisplays() {
        for (data, expiry) in [(Data(), 10.0), (Data(repeating: 1,count: 513),10), (Data([1]),0), (Data([1]),301)] {
            let (c,p,clock) = setup(); c.start()
            p.reads[0].1(.success(.token(data, expiresAt: clock.now.addingTimeInterval(expiry))))
            XCTAssertNil(c.displayURL); XCTAssertEqual(c.phase, .failed)
        }
    }
    func testCancelClearsTokenAndRejectsLateResponseEventAndTimer() {
        let (c,p,clock) = setup(); c.start()
        p.reads[0].1(.success(.token(Data([1]), expiresAt: clock.now.addingTimeInterval(30))))
        let timer = clock.timers.last!, event = p.event
        c.cancel(); timer.2(); event?()
        p.reads[0].1(.success(.token(Data([2]), expiresAt: clock.now.addingTimeInterval(30))))
        XCTAssertEqual(c.phase, .idle); XCTAssertNil(c.displayURL)
        XCTAssertTrue(p.events.cancelled); XCTAssertTrue(timer.1.cancelled); XCTAssertEqual(p.reads.count, 1)
    }
    func testRenewalImmediatelyHidesOldTokenAndFailureRequiresExplicitRetry() {
        let (c,p,clock) = setup(); c.start()
        p.reads[0].1(.success(.token(Data([1]), expiresAt: clock.now.addingTimeInterval(30))))
        clock.timers.last?.2(); XCTAssertNil(c.displayURL); XCTAssertEqual(p.reads.count, 2)
        p.reads[1].1(.failure(.failed)); XCTAssertEqual(c.phase, .failed)
        p.event?(); XCTAssertEqual(p.reads.count, 2)
        c.start(); XCTAssertEqual(p.reads.count, 3)
    }
    func testPasswordOrAuthorizedOutcomeCancelsRenewalAndEvents() {
        for outcome: TelegramQRLoginResult in [.password, .authorized] {
            let (c,p,_) = setup(); c.start(); p.reads[0].1(.success(outcome))
            XCTAssertNil(c.displayURL); XCTAssertTrue(p.events.cancelled)
            XCTAssertEqual(c.phase, .finished); p.event?(); XCTAssertEqual(p.reads.count, 1)
        }
    }
    func testNativeEventCoalescesWithInFlightRequest() {
        let (c,p,clock) = setup(); c.start(); p.event?(); p.event?()
        XCTAssertEqual(p.reads.count, 1)
        p.reads[0].1(.success(.token(Data([1]), expiresAt: clock.now.addingTimeInterval(60))))
        XCTAssertEqual(p.reads.count, 2); XCTAssertNil(c.displayURL)
        p.reads[1].1(.success(.token(Data([2]), expiresAt: clock.now.addingTimeInterval(60))))
        XCTAssertEqual(c.displayURL, "tg://login?token=Ag")
    }
    func testRebindRevokesOldProviderBeforeNewStart() {
        let (c,p,clock) = setup(), next = Provider(); c.start(); c.bind(next)
        p.reads[0].1(.success(.token(Data([1]), expiresAt: clock.now.addingTimeInterval(30))))
        XCTAssertNil(c.displayURL); XCTAssertTrue(p.reads[0].0.cancelled)
        c.start(); XCTAssertEqual(next.reads.count, 1)
    }
    func testDeadlineStopsUnansweredRequestAndRefusesLateToken() {
        let (c,p,clock) = setup(); c.start(); XCTAssertEqual(clock.timers.first?.0, 30)
        clock.timers.first?.2(); XCTAssertTrue(p.reads[0].0.cancelled); XCTAssertEqual(c.phase, .failed)
        p.reads[0].1(.success(.token(Data([1]), expiresAt: clock.now.addingTimeInterval(30))))
        XCTAssertNil(c.displayURL)
    }
}
