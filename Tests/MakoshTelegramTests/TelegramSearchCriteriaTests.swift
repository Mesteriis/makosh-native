import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramSearchCriteriaTests: XCTestCase {
    func testMediaSelectionProducesTheExactDistinctNativeSearchMask() {
        let masks: [(TelegramSearchMediaFilter, UInt32?)] = [
            (.all, nil), (.photoVideo, 1), (.photos, 256), (.videos, 512),
            (.links, 8), (.music, 4), (.voiceOrVideo, 16), (.voice, 4096), (.roundVideo, 8192),
            (.gifs, 128), (.files, 2)
        ]
        for (filter, expected) in masks {
            XCTAssertEqual(filter.tags?.rawValue, expected, "Unexpected native mask for \(filter)")
        }
    }

    func testGlobalScopesBuildGeneralSearchWithMediaAndNoDateRange() {
        let scopes: [(TelegramSearchScope, TelegramSearchPeersScope)] = [
            (.all, .everywhere), (.privateChats, .privateChats),
            (.groups, .groups), (.channels, .channels)
        ]
        for (scope, expected) in scopes {
            let criteria = TelegramSearchCriteria(query: "needle", media: .links, scope: scope)
            XCTAssertEqual(criteria.nativeLocation,
                .general(scope: expected, tags: .webPage, minDate: nil, maxDate: nil))
            XCTAssertEqual(SearchMessagesLocation.general(scope: scope.nativeScope, tags: nil,
                minDate: nil, maxDate: nil), .general(scope: expected, tags: nil, minDate: nil, maxDate: nil))
        }
    }

    func testChatSearchPreservesSenderTopicAndSeparateRoundVideoFilter() {
        let chatID: Int64 = 8_589_935_593
        let criteria = TelegramSearchCriteria(query: "meeting", senderID: 42, media: .roundVideo,
            scope: .groups, chatID: chatID, threadID: 77)
        XCTAssertTrue(criteria.isValid)
        XCTAssertTrue(criteria.isActive)
        XCTAssertEqual(criteria.nativeLocation, .peer(peerId: PeerId(chatID), fromId: PeerId(42),
            tags: .roundVideo, reactions: nil, threadId: 77, minDate: nil, maxDate: nil))
    }

    func testWhitespaceQueryNormalizesOnlyItsOuterBoundary() {
        let criteria = TelegramSearchCriteria(query: "  \nПривет  мир 🧭\t ")
        XCTAssertEqual(criteria.query, "Привет  мир 🧭")
        XCTAssertTrue(criteria.isActive)
        XCTAssertTrue(criteria.isValid)
    }

    func testEmptyQueryActivatesAppliedFiltersButChatContextAloneDoesNot() {
        XCTAssertFalse(TelegramSearchCriteria(query: " \n\t").isActive)
        XCTAssertFalse(TelegramSearchCriteria(chatID: 10).isActive)
        XCTAssertFalse(TelegramSearchCriteria(chatID: 10, threadID: 7).isActive)
        XCTAssertFalse(TelegramSearchCriteria(scope: .channels, chatID: 10).isActive,
            "A global scope does not constrain an explicit peer search")
        XCTAssertTrue(TelegramSearchCriteria(senderID: 20, chatID: 10).isActive)
        XCTAssertTrue(TelegramSearchCriteria(media: .files).isActive)
        XCTAssertTrue(TelegramSearchCriteria(media: .voice, chatID: 10).isActive)
        XCTAssertTrue(TelegramSearchCriteria(scope: .groups).isActive)
    }

    func testOrphanSenderAndTopicFailClosedInsteadOfBroadeningGlobalSearch() {
        for criteria in [TelegramSearchCriteria(query: "text", senderID: 20),
                         TelegramSearchCriteria(query: "text", threadID: 7),
                         TelegramSearchCriteria(senderID: 20, media: .files, threadID: 7)] {
            XCTAssertFalse(criteria.isValid)
            XCTAssertFalse(criteria.isActive)
            XCTAssertNil(criteria.nativeLocation)
        }
    }

    func testNoncanonicalPackedPeerIDsAreRejectedBeforeConstructingNativePeerIDs() {
        let invalid: [Int64] = [1 << 59, 1 << 60, 1 << 61, 1 << 62, Int64.min,
            Int64.max, -1, 0x0000000700000000, 0x7fffffff00000001]
        for id in invalid {
            for criteria in [TelegramSearchCriteria(query: "text", chatID: id),
                             TelegramSearchCriteria(query: "text", senderID: id, chatID: 10)] {
                XCTAssertFalse(criteria.isValid, "Noncanonical packed peer: \(id)")
                XCTAssertFalse(criteria.isActive)
                XCTAssertNil(criteria.nativeLocation)
            }
        }
    }

    func testSearchablePeersPreserveExactNativeIdentityIncludingSignedSecretIDs() {
        let valid: [Int64] = [1, 0x0000000100000001, 0x0000000200000001,
            0x0000000300000001, 0x000000037fffffff, 0x0000000380000000,
            0x00000003ffffffff, 0x07fffffaffffffff]
        for id in valid {
            let criteria = TelegramSearchCriteria(query: "text", chatID: id)
            XCTAssertTrue(criteria.isValid, "Searchable packed peer: \(id)")
            XCTAssertEqual(criteria.nativeLocation, .peer(peerId: PeerId(id), fromId: nil,
                tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil))
        }
    }

    func testPlaceholderUnknownNamespaceAndOversizedSecretPeersCannotStartSearch() {
        let invalid: [Int64] = [0, 0x0000000100000000, 0x0000000200000000,
            0x0000000300000000, 0x0000000400000001, 0x0000000500000001,
            0x0000000600000001, 0x0000000700000001, 0x7fffffff00000000,
            0x0000000b00000001]
        for id in invalid {
            let criteria = TelegramSearchCriteria(query: "text", chatID: id)
            XCTAssertFalse(criteria.isValid, "Not a searchable peer: \(id)")
            XCTAssertFalse(criteria.isActive)
            XCTAssertNil(criteria.nativeLocation)
        }
    }

    func testSenderMustBeANonemptyCloudPeerInsteadOfSecretOrPlaceholder() {
        let invalid: [Int64] = [0, 0x0000000100000000, 0x0000000200000000,
            0x0000000300000001, 0x00000003ffffffff, 0x0000000400000001,
            0x0000000500000001, 0x0000000600000001, 0x0000000700000001,
            0x7fffffff00000000]
        for id in invalid {
            let criteria = TelegramSearchCriteria(query: "text", senderID: id, chatID: 10)
            XCTAssertFalse(criteria.isValid, "Not a searchable sender: \(id)")
            XCTAssertFalse(criteria.isActive)
            XCTAssertNil(criteria.nativeLocation)
        }
    }

    func testForumThreadMustFitPositiveInt32WithoutClamping() {
        let invalid: [Int64] = [0, -1, Int64.min, 2_147_483_648, Int64.max]
        for threadID in invalid {
            let criteria = TelegramSearchCriteria(query: "text", chatID: 8_589_935_593,
                threadID: threadID)
            XCTAssertFalse(criteria.isValid, "Not an exact positive forum message ID: \(threadID)")
            XCTAssertFalse(criteria.isActive)
            XCTAssertNil(criteria.nativeLocation)
        }
    }

    func testPositiveCloudSendersAndExactForumThreadBoundaryReachNativeLocation() {
        let senders: [Int64] = [1, 0x0000000100000001, 0x0000000200000001,
            0x07fffffaffffffff]
        for id in senders {
            let criteria = TelegramSearchCriteria(senderID: id, media: .photos,
                chatID: 8_589_935_593, threadID: 2_147_483_647)
            XCTAssertTrue(criteria.isValid)
            XCTAssertTrue(criteria.isActive)
            XCTAssertEqual(criteria.nativeLocation,
                .peer(peerId: PeerId(8_589_935_593), fromId: PeerId(id), tags: .photo,
                    reactions: nil, threadId: 2_147_483_647, minDate: nil, maxDate: nil))
        }
    }
}
