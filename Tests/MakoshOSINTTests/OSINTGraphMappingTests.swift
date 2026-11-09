import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

final class OSINTGraphMappingTests: XCTestCase {
    private let server = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func node(
        _ id: String, _ type: FlowsintNodeType, _ value: String, _ extra: [String: JSONValue] = [:], enricher: OSINTEnricher? = nil
    )
        -> FlowsintNode
    {
        var properties = extra
        properties[type.primaryField] = .string(value)
        return FlowsintNode(
            id: id, type: type.rawValue, label: value, properties: properties,
            metadata: enricher.map { ["enricher": .string($0.rawValue)] } ?? [:])
    }

    private func edge(_ from: String, _ to: String, _ label: String = "IS_RELATED_TO") -> FlowsintEdge {
        FlowsintEdge(source: from, target: to, label: label)
    }

    private func anna() -> Person {
        Person(displayName: "Анна Каренина", phones: ["+79990000000"], emails: ["anna@example.test"], tags: [])
    }

    private func map(
        _ graph: FlowsintGraph, inputs: Set<String>, person: Person? = nil, limit: Int = 200
    ) -> (observations: [Observation], truncated: Bool) {
        OSINTGraphMapping.observations(
            graph: graph, inputNodeIDs: inputs, sketchID: "sk-1", serverID: server, person: person ?? anna(), now: now, limit: limit)
    }

    func testEmailNeighborsBecomeProposedEmails() {
        let graph = FlowsintGraph(
            nodes: [
                node("in", .individual, "Анна Каренина"),
                node("e1", .email, "Anna.K@Example.test", enricher: .individualToUsernameCandidates), node("u1", .username, "anna_k"),
            ],
            edges: [edge("in", "e1", "HAS_EMAIL"), edge("u1", "in", "BELONGS_TO")])
        let result = map(graph, inputs: ["in"])
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(
            result.observations.map { ($0.field, $0.value) }.map { "\($0.0)=\($0.1)" }.sorted(),
            ["emails=anna.k@example.test", "usernames=anna_k"])
        XCTAssertEqual(
            result.observations.first { $0.field == "emails" }?.source.identity.externalID, "sk-1/individual_to_username_candidates")
        XCTAssertEqual(result.observations.first { $0.field == "usernames" }?.source.identity.externalID, "sk-1")
    }

    func testSocialAccountUsesProfileURLOrPlatformHandle() {
        let graph = FlowsintGraph(
            nodes: [
                node("u", .username, "anna_k"),
                node(
                    "s1", .socialAccount, "github:anna_k",
                    ["platform": .string("GitHub"), "profile_url": .string("https://github.com/anna_k")]),
                node(
                    "s2", .socialAccount, "twitter:anna_k",
                    ["platform": .string("twitter"), "username": .object(["value": .string("anna_k")])]),
            ],
            edges: [edge("u", "s1"), edge("u", "s2")])
        let values = Dictionary(uniqueKeysWithValues: map(graph, inputs: ["u"]).observations.map { ($0.field, $0.value) })
        XCTAssertEqual(values["social.github"], "https://github.com/anna_k")
        XCTAssertEqual(values["social.twitter"], "twitter:anna_k")
    }

    func testBreachAndGravatarAndDeviceFormats() {
        let graph = FlowsintGraph(
            nodes: [
                node("e", .email, "anna@example.test"),
                node("b", .breach, "Adobe", ["title": .string("Adobe"), "breachdate": .string("2013-10-04")]),
                node("b2", .breach, "LinkedIn"),
                node("g", .gravatar, "hash-anna", ["src": .string("https://www.gravatar.com/avatar/hash-anna"), "exists": .bool(true)]),
                node("g0", .gravatar, "hash-none", ["src": .string("https://www.gravatar.com/avatar/hash-none"), "exists": .bool(false)]),
                node(
                    "d", .device, "dev-1",
                    ["os": .string("Windows 10"), "last_seen": .string("2024-05-01"), "ip_addresses": .array([.string("10.0.0.1")])]),
                node("dom", .domain, "example.test"),
                node("org", .organization, "Example LLC"),
            ],
            edges: [edge("e", "b"), edge("e", "b2"), edge("e", "g"), edge("e", "g0"), edge("e", "d"), edge("e", "dom"), edge("e", "org")])
        let observations = map(graph, inputs: ["e"]).observations
        let pairs = Set(observations.map { "\($0.field)=\($0.value)" })
        XCTAssertEqual(
            pairs,
            [
                "breach=Adobe, 2013-10-04", "breach=LinkedIn", "avatar=https://www.gravatar.com/avatar/hash-anna",
                "leak.device=Windows 10, 2024-05-01",
                "domain=example.test", "organization.suggested=Example LLC",
            ])
        XCTAssertFalse(observations.contains { $0.value.contains("10.0.0.1") }, "device identifiers stay on the server")
    }

    func testInputPhoneCarrierBecomesPhoneInfo() {
        let graph = FlowsintGraph(
            nodes: [
                node("p", .phone, "+79990000000", ["country": .string("RU"), "carrier": .string("МТС"), "line_type": .string("mobile")]),
                node("p2", .phone, "+7 (999) 000-00-01"),
                node("p3", .phone, "+79990000002"),
            ],
            edges: [edge("p", "p2")])
        let observations = map(graph, inputs: ["p"]).observations
        let pairs = Set(observations.map { "\($0.field)=\($0.value)" })
        XCTAssertEqual(pairs, ["phone.info=+79990000000 — RU, МТС, mobile", "phones=+79990000001"])
    }

    func testUnlinkedNodesAreIgnored() {
        let graph = FlowsintGraph(
            nodes: [node("e", .email, "anna@example.test"), node("x", .email, "stranger@example.test"), node("y", .breach, "Other")],
            edges: [edge("x", "y")])
        XCTAssertTrue(map(graph, inputs: ["e"]).observations.isEmpty)
    }

    func testCurrentAndAlreadyProposedValuesAreSkipped() {
        var person = anna()
        let identity = OSINTGraphMapping.identity(serverID: server, sketchID: "sk-1")
        person.observations = [
            Observation(field: "usernames", value: "anna_k", source: SourceStamp(identity: identity, fetchedAt: now), status: .proposed),
            Observation(
                field: "breach", value: "Adobe, 2013-10-04", source: SourceStamp(identity: identity, fetchedAt: now), status: .confirmed),
        ]
        let graph = FlowsintGraph(
            nodes: [
                node("in", .individual, "Анна Каренина"), node("e", .email, "ANNA@example.test"), node("p", .phone, "8 999 000-00-00"),
                node("u", .username, "anna_k"), node("u2", .username, "anna_k"),
                node("b", .breach, "Adobe", ["breachdate": .string("2013-10-04")]),
                node("u3", .username, "karenina"),
            ],
            edges: [edge("in", "e"), edge("in", "p"), edge("in", "u"), edge("in", "u2"), edge("in", "b"), edge("in", "u3")])
        let observations = map(graph, inputs: ["in"], person: person).observations
        XCTAssertEqual(observations.map { "\($0.field)=\($0.value)" }, ["usernames=karenina"])
    }

    func testLimitTruncates() {
        var nodes = [node("in", .individual, "Анна")]
        var edges: [FlowsintEdge] = []
        for index in 0..<201 {
            nodes.append(node("d\(index)", .domain, "d\(index).example.test"))
            edges.append(edge("in", "d\(index)"))
        }
        let result = map(FlowsintGraph(nodes: nodes, edges: edges), inputs: ["in"])
        XCTAssertEqual(result.observations.count, 200)
        XCTAssertTrue(result.truncated)
        let small = map(FlowsintGraph(nodes: nodes, edges: edges), inputs: ["in"], limit: 10)
        XCTAssertEqual(small.observations.count, 10)
    }

    func testIdentityAndStatus() {
        let identity = OSINTGraphMapping.identity(serverID: server, sketchID: "sk-1")
        XCTAssertEqual(identity, ServiceIdentity(service: "osint", accountID: server.uuidString, externalID: "sk-1"))
        XCTAssertEqual(OSINTGraphMapping.service, "osint")
        let graph = FlowsintGraph(
            nodes: [node("e", .email, "anna@example.test"), node("d", .domain, "example.test")], edges: [edge("e", "d")])
        let observations = map(graph, inputs: ["e"]).observations
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].status, .proposed)
        XCTAssertEqual(observations[0].source.identity.service, "osint")
        XCTAssertEqual(observations[0].source.identity.accountID, server.uuidString)
        XCTAssertEqual(observations[0].source.fetchedAt, now)
    }

    func testEnricherNodesCarryLowercaseTypes() {
        // Live flowsint writes enricher output with lowercase types ("socialaccount", "username") and GitHub-style platforms.
        let graph = FlowsintGraph(
            nodes: [
                node("n1", .username, "mesteriis"),
                FlowsintNode(
                    id: "n2", type: "socialaccount", label: "Alexander (GitHub)",
                    properties: [
                        "id": .string("mesteriis@GitHub"), "platform": .string("GitHub"),
                        "profile_url": .string("https://github.com/mesteriis"),
                        "username": .object(["value": .string("mesteriis")]),
                    ]),
                FlowsintNode(id: "n3", type: "username", label: "mesteriis", properties: ["value": .string("mesteriis")]),
            ],
            edges: [edge("n1", "n2", "HAS_ACCOUNT"), edge("n1", "n3", "SAME_AS")])
        var person = Person(displayName: "avm", tags: [])
        person.usernames = ["mesteriis"]
        let result = map(graph, inputs: ["n1"], person: person)
        XCTAssertEqual(result.observations.map { "\($0.field)=\($0.value)" }, ["social.github=https://github.com/mesteriis"])
    }
}
