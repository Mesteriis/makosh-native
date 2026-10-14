import XCTest
import TelegramCore
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

final class TelegramAuthorizationStateTests: XCTestCase {
    @MainActor func testFreshNativePostboxOpensPhoneFormWithoutWritingAccountState() async throws {
        let postbox = try await telegramDataPostbox(test: self)
        let view = try await telegramDataValue(postbox.stateView(), test: self)
        XCTAssertNil(view.state)
        let model = TelegramModel()
        model.applyUnauthorizedState(view.state)
        XCTAssertEqual(model.phase, .phone)
        let after = try await telegramDataValue(postbox.stateView(), test: self)
        XCTAssertNil(after.state)
    }

    @MainActor func testExistingEmptyAuthorizationOpensPhoneForm() {
        let model = TelegramModel()
        model.applyUnauthorizedState(UnauthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2, contents: .empty))
        XCTAssertEqual(model.phase, .phone)
    }

    @MainActor func testAuthorizedStateIsNeverReplacedWithPhoneEntry() {
        let model = TelegramModel()
        let state = AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2,
            peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(123)),
            state: nil, invalidatedChannels: [])
        model.applyUnauthorizedState(state)
        XCTAssertEqual(model.phase, .configuration)
    }
}
