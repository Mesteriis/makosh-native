import XCTest
import AVFoundation
@testable import MakoshTelegram

@MainActor final class TelegramCallCameraConsentTests: XCTestCase {
    func testDeniedPermissionNeverResolvesOrOpensCameraInput() async {
        let counter = CameraInputCounter()
        let source = TelegramNativeCallCameraSource(authorization: { false }, makeInput: counter.make)
        let ready = await source.start(output: { _ in XCTFail("No captured frame is authorized") }, failure: {})
        XCTAssertFalse(ready); XCTAssertEqual(counter.reads, 0)
        let released = expectation(description: "Empty capture resources released")
        source.stop { released.fulfill() }; await fulfillment(of: [released], timeout: 2)
    }
    func testCancellationBeforeStartCannotOpenDeviceEvenWithGrantedStatus() async {
        let counter = CameraInputCounter()
        let source = TelegramNativeCallCameraSource(authorization: { true }, makeInput: counter.make)
        let released = expectation(description: "Cancelled source released")
        source.stop { released.fulfill() }
        let ready = await source.start(output: { _ in XCTFail("Cancelled capture must remain inert") }, failure: {})
        XCTAssertFalse(ready); XCTAssertEqual(counter.reads, 0)
        await fulfillment(of: [released], timeout: 2)
    }
}
private final class CameraInputCounter: @unchecked Sendable {
    enum Failure: Error { case forbidden }
    private let lock = NSLock(); private var count = 0
    var reads: Int { lock.withLock { count } }
    func make() throws -> AVCaptureDeviceInput { lock.withLock { count += 1 }; throw Failure.forbidden }
}
