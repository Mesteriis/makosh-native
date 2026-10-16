import XCTest
@testable import MakoshTeams

@MainActor final class TeamsNotificationTests: XCTestCase {
    func incoming(_ id: String, scope: TeamsScope = teamsTestScope) -> TeamsMessage {
        TeamsMessage(id: id, scope: scope, body: "Private <body>", contentType: "text", author: TeamsPerson(userID: "88888888-8888-4888-8888-888888888888", tenantID: scope.tenantID, displayName: "Peer", email: nil), createdAt: Date(), modifiedAt: nil, deletedAt: nil, attachments: [], replyTo: nil)
    }
    func testNewThreadAfterBaselineDoesNotSilenceFreshReply() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let root = "/v1.0/teams/team/channels/channel/messages"
        let now = ISO8601DateFormatter().string(from: Date())
        let http = TeamsRoutedHTTP([root: [teamsJSON("{\"value\":[]}"), teamsJSON("{\"value\":[{\"id\":\"root\",\"createdDateTime\":\"\(now)\",\"body\":{\"contentType\":\"text\",\"content\":\"root\"}}]}")],
            root + "/root/replies": [teamsJSON("{\"value\":[{\"id\":\"reply\",\"createdDateTime\":\"\(now)\",\"body\":{\"contentType\":\"text\",\"content\":\"reply\"}}]}")]])
        let sync = TeamsSynchronization(context: teamsTestContext, graph: TeamsGraphClient(context: teamsTestContext, transport: http), repository: repository)
        try await sync.scan(resource: .channel(teamID: "team", channelID: "channel"), token: "synthetic")
        try await sync.scan(resource: .channel(teamID: "team", channelID: "channel"), token: "synthetic")
        let events = try await repository.claimNotifications(accountID: teamsTestScope.accountID)
        XCTAssertEqual(Set(events.map(\.messageID)), ["root", "reply"])
        let checkpoint = try await repository.checkpoint(collection: TeamsCollection(context: teamsTestContext, kind: .replies(.thread(teamID: "team", channelID: "channel", rootID: "root"))))
        XCTAssertTrue(checkpoint?.baselineEstablished == true)
        await repository.close()
    }
    func testInitialHistoryAndMutedEventsNeverReplay() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        _ = try await repository.commit(page: TeamsPage(values: [incoming("history")], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: true)
        let initial = try await repository.claimNotifications(accountID: teamsTestScope.accountID)
        XCTAssertTrue(initial.isEmpty)
        var rule = TeamsNotificationRule(); rule.show = false
        try await repository.setNotificationRule(rule, scope: .conversation(teamsTestScope))
        _ = try await repository.commit(page: TeamsPage(values: [incoming("muted")], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        try await repository.setNotificationRule(TeamsNotificationRule(), scope: .conversation(teamsTestScope))
        let muted = try await repository.claimNotifications(accountID: teamsTestScope.accountID)
        XCTAssertTrue(muted.isEmpty)
        _ = try await repository.commit(page: TeamsPage(values: [incoming("new")], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        let events = try await repository.claimNotifications(accountID: teamsTestScope.accountID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.messageID, "new")
        let repeated = try await repository.claimNotifications(accountID: teamsTestScope.accountID)
        XCTAssertTrue(repeated.isEmpty)
        try await repository.markLocallyRead(scope: teamsTestScope)
        let current = try await repository.notificationIsCurrent(events[0]); XCTAssertFalse(current)
        let reopened = TeamsRepository(keyProvider: teamsTestKey); try await reopened.open(configuration: db.configuration)
        let unread = try await reopened.localUnreadCount(scope: teamsTestScope); XCTAssertEqual(unread, 0)
        await reopened.close(); await repository.close()
    }
    func testReplyCreatesOneLocalUnreadEventWithoutRootReorderDuplicate() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let parent = TeamsScope(accountID: teamsTestScope.accountID, tenantID: teamsTestScope.tenantID, resource: .channel(teamID: "team", channelID: "channel"))
        let thread = TeamsScope(accountID: parent.accountID, tenantID: parent.tenantID, resource: .thread(teamID: "team", channelID: "channel", rootID: "root"))
        let roots = TeamsCollection(context: teamsTestContext, kind: .messages(parent.resource))
        let replies = TeamsCollection(context: teamsTestContext, kind: .replies(thread.resource))
        _ = try await repository.commit(page: TeamsPage(values: [incoming("root", scope: parent)], next: nil, continuationFailure: nil), collection: roots, baseline: true)
        let reply = incoming("reply", scope: thread)
        for _ in 0..<2 { _ = try await repository.commit(page: TeamsPage(values: [reply], next: nil, continuationFailure: nil), collection: replies, baseline: false) }
        let changedRoot = incoming("root", scope: parent)
        _ = try await repository.commit(page: TeamsPage(values: [changedRoot], next: nil, continuationFailure: nil), collection: roots, baseline: false)
        let events = try await repository.claimNotifications(accountID: parent.accountID)
        XCTAssertEqual(events.map(\.messageID), ["reply"])
        let unread = try await repository.localUnreadCount(scope: parent); XCTAssertEqual(unread, 1)
        var accountRule = TeamsNotificationRule(); accountRule.preview = false; accountRule.sound = false
        try await repository.setNotificationRule(accountRule, scope: .account(parent.accountID))
        let effective = try await repository.notificationRule(conversation: thread)
        XCTAssertFalse(effective.preview); XCTAssertFalse(effective.sound)
        try await repository.markLocallyRead(scope: parent)
        let activated = try await repository.activateNotification(token: events[0].id)
        XCTAssertNil(activated)
        await repository.close()
    }
}
