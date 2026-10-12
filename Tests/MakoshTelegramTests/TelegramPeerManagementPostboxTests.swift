import XCTest
import Foundation
import SwiftSignalKit
import TelegramCore
@testable import Postbox
@testable import MakoshTelegram

private func managementGroup(role: TelegramGroupRole = .member, membership: TelegramGroupMembership = .Member,
        flags: TelegramGroupFlags = [], bans: TelegramChatBannedRightsFlags = [],
        migrated: Bool = false) -> TelegramGroup {
        TelegramGroup(id: PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(7)),
            title: "Synthetic", photo: [], participantCount: 2, role: role, membership: membership,
            flags: flags, defaultBannedRights: TelegramChatBannedRights(flags: bans, untilDate: Int32.max),
            migrationReference: migrated ? TelegramGroupToChannelMigrationReference(
                peerId: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(8)),
                accessHash: 1) : nil, creationDate: 0, version: 1)
    }

private func managementChannel(broadcast: Bool = false, participation: TelegramChannelParticipationStatus = .member,
        flags: TelegramChannelFlags = [], groupFlags: TelegramChannelGroupFlags = [],
        admin: TelegramChatAdminRightsFlags? = nil, bans: TelegramChatBannedRightsFlags = [],
        defaultBans: TelegramChatBannedRightsFlags = [], fee: StarsAmount? = nil) -> TelegramChannel {
        TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(9)),
            accessHash: .personal(101), title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
            participationStatus: participation,
            info: broadcast ? .broadcast(TelegramChannelBroadcastInfo(flags: []))
                : .group(TelegramChannelGroupInfo(flags: groupFlags)), flags: flags, restrictionInfo: nil,
            adminRights: admin.map { TelegramChatAdminRights(rights: $0) },
            bannedRights: TelegramChatBannedRights(flags: bans, untilDate: 2_100),
            defaultBannedRights: TelegramChatBannedRights(flags: defaultBans, untilDate: Int32.max),
            usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
            profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil,
            subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: fee,
            linkedMonoforumId: nil)
    }

private nonisolated func managementUser(_ number: Int64, hasHash: Bool = true) -> TelegramUser {
    TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(number)),
        accessHash: hasHash ? .personal(100) : nil, firstName: "Synthetic", lastName: nil,
        username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
        emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
        profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}

private func managementSeed(_ box: Postbox, rights: TelegramChatAdminRightsFlags = [.canAddAdmins, .canDeleteMessages]) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peer = managementChannel(admin: rights)
        transaction.updatePeersInternal([peer, managementUser(42)], update: { _, value in value })
        transaction.updatePeerCachedData(peerIds: [peer.id], update: { _, _ in CachedChannelData() })
    }
}
private func managementAdmission(_ box: Postbox, change: TelegramPeerChange, participant: ChannelParticipant?,
    revokeDuringFetch: Bool, calls: Atomic<Int>) -> Signal<Result<Bool, TelegramPeerManagementError>, NoError> {
    telegramAdmitPeerChange(postbox: box, accountID: 1, peerID: managementChannel().id, change: change,
        fetchMember: { _ in
            if revokeDuringFetch { return managementSeed(box, rights: []) |> map { participant } }
            return .single(participant)
        }, perform: { peer, target, accepted in
            _ = calls.modify { $0 + 1 }
            guard peer.id == managementChannel().id, target?.id == managementUser(42).id, accepted == change else { return .fail(.failed) }
            return .single(())
        }) |> map { .success(true) } |> `catch` { .single(.failure($0)) }
}

private func managementBasicSeed(_ box: Postbox) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let group = managementGroup(role: .creator(rank: nil)), peer = managementUser(42), other = managementUser(43)
        transaction.updatePeersInternal([group, peer, other], update: { _, new in new })
        transaction.updatePeerCachedData(peerIds: [group.id], update: { _, _ in
            CachedGroupData().withUpdatedAbout("Retained").withUpdatedParticipants(.init(participants: [
                .member(id: peer.id, invitedBy: other.id, invitedAt: 123), .creator(id: other.id)], version: 17))
        })
    }
}
private func managementBasicRead(_ box: Postbox) -> Signal<CachedGroupData?, NoError> {
    box.transaction { $0.getPeerCachedData(peerId: managementGroup().id) as? CachedGroupData }
}
private func managementBasicAdmission(_ box: Postbox, calls: Atomic<Int>, fetches: Atomic<Int>) -> Signal<Bool, NoError> {
    let group = managementGroup(role: .creator(rank: nil)), peer = managementUser(42), other = managementUser(43)
    let member = telegramPeerMember(GroupParticipant.member(id: peer.id, invitedBy: other.id, invitedAt: 123), peer: peer)
    let change = TelegramPeerChange.administrator(member: member, rights: 1, rank: "")
    return telegramAdmitPeerChange(postbox: box, accountID: 1, peerID: group.id, change: change,
        fetchMember: { _ in _ = fetches.modify { $0 + 1 }; return .single(nil) }, perform: { actual, target, accepted in
            guard actual.id == group.id, target?.id == peer.id, accepted == change else { return .fail(.failed) }
            _ = calls.modify { $0 + 1 }; return .single(())
        }) |> map { _ in true } |> `catch` { _ in Signal<Bool, NoError>.single(false) }
}

@MainActor final class TelegramPeerManagementPostboxTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Synthetic native management boundary")
        var result: T?
        let lease = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { lease.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func open() async throws -> Postbox {
        initializeAccountManagement()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-forward-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 17, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 18, count: 16)))
        let ready = expectation(description: "Encrypted Postbox")
        var result: Postbox?
        let lease = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false, isReadOnly: false,
            useCopy: false, useCaches: false, removeDatabaseOnError: false) |> deliverOnMainQueue).start(next: {
                if case let .postbox(box) = $0 { result = box; ready.fulfill() }
            })
        defer { lease.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        let box = try XCTUnwrap(result), stores = expectation(description: "Both MediaBox stores")
        stores.expectedFulfillmentCount = 2
        let a = (box.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        let b = (box.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        defer { a.dispose(); b.dispose() }
        await fulfillment(of: [stores], timeout: 20)
        return box
    }
    func testFreshMemberOutsidePeerViewIsReadFromActualPostboxBeforeAdmission() async throws {
        let box = try await open(); let _: Void = try await value(managementSeed(box))
        let participant = ChannelParticipant.member(id: managementUser(42).id, invitedAt: 0, adminInfo: nil, banInfo: nil, rank: nil, subscriptionUntilDate: nil)
        let member = telegramPeerMember(participant, peer: managementUser(42), owner: false)
        let change = TelegramPeerChange.administrator(member: member, rights: TelegramChatAdminRightsFlags.canDeleteMessages.rawValue, rank: "Editor")
        let calls = Atomic(value: 0)
        let result = try await value(managementAdmission(box, change: change, participant: participant, revokeDuringFetch: false, calls: calls))
        switch result { case .success: break; case .failure: XCTFail("Exact freshly fetched member must reach the admitted RPC boundary") }
        XCTAssertEqual(calls.with { $0 }, 1)
    }
    func testRightsRevokedDuringParticipantFetchPreventRPCAndStaleRoleCannotBeEdited() async throws {
        let box = try await open(); let _: Void = try await value(managementSeed(box))
        let participant = ChannelParticipant.member(id: managementUser(42).id, invitedAt: 0, adminInfo: nil, banInfo: nil, rank: nil, subscriptionUntilDate: nil)
        let member = telegramPeerMember(participant, peer: managementUser(42), owner: false)
        let change = TelegramPeerChange.administrator(member: member, rights: TelegramChatAdminRightsFlags.canDeleteMessages.rawValue, rank: "Editor")
        let calls = Atomic(value: 0)
        let result = try await value(managementAdmission(box, change: change, participant: participant, revokeDuringFetch: true, calls: calls))
        if case .success = result { XCTFail("Revoked actor rights must prevent RPC") }
        XCTAssertEqual(calls.with { $0 }, 0)
        let _: Void = try await value(managementSeed(box))
        let protected = ChannelParticipant.creator(id: managementUser(42).id, adminInfo: nil, rank: nil)
        let changed = try await value(managementAdmission(box, change: change, participant: protected, revokeDuringFetch: false, calls: calls))
        if case .success = changed { XCTFail("A changed target role must prevent RPC") }
        XCTAssertEqual(calls.with { $0 }, 0)
    }
    func testBasicGroupAdmissionAndAcknowledgedRolePreserveVersionAndOtherMembers() async throws {
        let box = try await open()
        let group = managementGroup(role: .creator(rank: nil))
        let peer = managementUser(42), other = managementUser(43)
        let original = GroupParticipant.member(id: peer.id, invitedBy: other.id, invitedAt: 123)
        let _: Void = try await value(managementBasicSeed(box))
        let member = telegramPeerMember(original, peer: peer)
        let calls = Atomic(value: 0), fetches = Atomic(value: 0)
        let signal = managementBasicAdmission(box, calls: calls, fetches: fetches)
        let accepted = try await value(signal)
        XCTAssertTrue(accepted); XCTAssertEqual(calls.with { $0 }, 1); XCTAssertEqual(fetches.with { $0 }, 0)
        let _: Void = try await value(telegramAcknowledgeBasicAdministrator(postbox: box, peerID: group.id, member: member, rights: 1))
        let cache = try await value(managementBasicRead(box))
        XCTAssertEqual(cache?.about, "Retained"); XCTAssertEqual(cache?.participants?.version, 17)
        XCTAssertEqual(cache?.participants?.participants, [.admin(id: peer.id, invitedBy: other.id, invitedAt: 123), .creator(id: other.id)])
        // A later changed role is not overwritten by an ACK for the old basis.
        let _: Void = try await value(telegramAcknowledgeBasicAdministrator(postbox: box, peerID: group.id, member: member, rights: 0))
        let after = try await value(managementBasicRead(box))
        XCTAssertEqual(after?.participants?.participants, cache?.participants?.participants)
    }

}
