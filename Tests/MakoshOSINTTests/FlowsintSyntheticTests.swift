import Foundation
import XCTest

@testable import MakoshOSINT

final class FlowsintSyntheticTests: XCTestCase {
    static let anna = "anna@example.test"

    static func findings() -> [FlowsintSynthetic.Finding] {
        [
            .init(
                enricher: .emailToGravatar, inputType: .email, inputValue: anna, outputType: .gravatar, outputValue: "hash-anna",
                properties: ["src": .string("https://www.gravatar.com/avatar/hash-anna"), "exists": .bool(true)], edgeLabel: "HAS_GRAVATAR"),
            .init(
                enricher: .emailToBreaches, inputType: .email, inputValue: anna, outputType: .breach, outputValue: "Adobe",
                properties: ["title": .string("Adobe"), "breachdate": .string("2013-10-04")], edgeLabel: "FOUND_IN_BREACH"),
            .init(
                enricher: .usernameToMaigret, inputType: .username, inputValue: "anna_k", outputType: .socialAccount,
                outputValue: "github:anna_k",
                properties: ["platform": .string("github"), "profile_url": .string("https://github.com/anna_k")], edgeLabel: "HAS_ACCOUNT"),
            .init(
                enricher: .usernameToMaigret, inputType: .username, inputValue: "anna_k", outputType: .socialAccount,
                outputValue: "twitter:anna_k",
                properties: ["platform": .string("twitter"), "profile_url": .string("https://x.com/anna_k")],
                edgeLabel: "HAS_ACCOUNT"),
        ]
    }

    private func sketch(_ api: FlowsintSynthetic) async throws -> FlowsintSketch {
        let investigation = try await api.createInvestigation(name: "Makosh")
        return try await api.createSketch(title: UUID().uuidString, investigationID: investigation.id)
    }

    func testLaunchThenScanAppendsFindings() async throws {
        let api = FlowsintSynthetic(findings: Self.findings())
        let sketch = try await sketch(api)
        let email = try await api.addNode(sketchID: sketch.id, type: .email, value: Self.anna)
        let username = try await api.addNode(sketchID: sketch.id, type: .username, value: "anna_k")
        let before = try await api.graph(sketchID: sketch.id)
        XCTAssertEqual(before.nodes.count, 2)
        let task = try await api.launch(enricher: .emailToGravatar, sketchID: sketch.id, nodeIDs: [email])
        let first = try await api.scan(id: task)
        XCTAssertEqual(first, .completed)
        let afterGravatar = try await api.graph(sketchID: sketch.id)
        XCTAssertEqual(afterGravatar.nodes.count, 3)
        let gravatar = try XCTUnwrap(afterGravatar.nodes.first { $0.type == "Gravatar" })
        XCTAssertEqual(gravatar.properties["src"]?.stringValue, "https://www.gravatar.com/avatar/hash-anna")
        XCTAssertEqual(gravatar.metadata["enricher"]?.stringValue, "email_to_gravatar")
        XCTAssertTrue(afterGravatar.edges.contains(FlowsintEdge(source: email, target: gravatar.id, label: "HAS_GRAVATAR")))
        let maigret = try await api.launch(enricher: .usernameToMaigret, sketchID: sketch.id, nodeIDs: [username])
        _ = try await api.scan(id: maigret)
        let breaches = try await api.launch(enricher: .emailToBreaches, sketchID: sketch.id, nodeIDs: [email])
        _ = try await api.scan(id: breaches)
        let all = try await api.graph(sketchID: sketch.id)
        XCTAssertEqual(all.nodes.filter { $0.type == "SocialAccount" }.count, 2)
        XCTAssertEqual(all.nodes.filter { $0.type == "Breach" }.count, 1)
        XCTAssertEqual(all.edges.filter { $0.source == username }.count, 2)
        let launches = await api.recordedLaunches
        XCTAssertEqual(launches.map(\.enricher), [.emailToGravatar, .usernameToMaigret, .emailToBreaches])
        XCTAssertEqual(launches[0].nodeIDs, [email])
        // A launch on a node without findings completes with nothing new.
        let phone = try await api.addNode(sketchID: sketch.id, type: .phone, value: "+79990000000")
        let empty = try await api.launch(enricher: .phoneToInfos, sketchID: sketch.id, nodeIDs: [phone])
        let status = try await api.scan(id: empty)
        XCTAssertEqual(status, .completed)
        let unchanged = try await api.graph(sketchID: sketch.id)
        XCTAssertEqual(unchanged.nodes.count, all.nodes.count + 1)
    }

    func testFailNextUnknownStillApplies() async throws {
        let api = FlowsintSynthetic()
        let investigation = try await api.createInvestigation(name: "Makosh")
        await api.failNext(.unknownOutcome(stage: "createSketch"), stage: "createSketch")
        do {
            _ = try await api.createSketch(title: "person-1", investigationID: investigation.id)
            XCTFail("the failure was armed")
        } catch { XCTAssertEqual(error as? OSINTFailure, .unknownOutcome(stage: "createSketch"), "\(error)") }
        let sketches = try await api.sketches(investigationID: investigation.id)
        XCTAssertEqual(sketches.map(\.title), ["person-1"], "an unknown outcome still applied the write")
        let second = try await api.createSketch(title: "person-2", investigationID: investigation.id)
        XCTAssertEqual(second.title, "person-2", "the armed failure fires once")
        await api.failNext(.apiRejected(code: 422, stage: "addNode"), stage: "addNode")
        do {
            _ = try await api.addNode(sketchID: second.id, type: .email, value: "x@example.test")
            XCTFail("the failure was armed")
        } catch { XCTAssertEqual(error as? OSINTFailure, .apiRejected(code: 422, stage: "addNode"), "\(error)") }
        let graph = try await api.graph(sketchID: second.id)
        XCTAssertTrue(graph.nodes.isEmpty, "a rejection applies nothing")
    }

    func testHungScanStaysRunning() async throws {
        let api = FlowsintSynthetic(findings: Self.findings())
        let sketch = try await sketch(api)
        let email = try await api.addNode(sketchID: sketch.id, type: .email, value: Self.anna)
        let task = try await api.launch(enricher: .emailToGravatar, sketchID: sketch.id, nodeIDs: [email])
        await api.hangScan(id: task)
        let first = try await api.scan(id: task)
        let second = try await api.scan(id: task)
        XCTAssertEqual([first, second], [.running, .running])
        let graph = try await api.graph(sketchID: sketch.id)
        XCTAssertEqual(graph.nodes.count, 1, "a hung task adds nothing")
        do {
            _ = try await api.scan(id: "no-such-task")
            XCTFail("unknown task")
        } catch { XCTAssertEqual(error as? OSINTFailure, .apiRejected(code: 404, stage: "scan"), "\(error)") }
    }

    func testDuplicateNodesMerge() async throws {
        let api = FlowsintSynthetic(findings: Self.findings())
        let sketch = try await sketch(api)
        let first = try await api.addNode(sketchID: sketch.id, type: .email, value: Self.anna)
        let again = try await api.addNode(sketchID: sketch.id, type: .email, value: "Anna@Example.test")
        XCTAssertEqual(first, again, "same type and primary value is one node")
        let task = try await api.launch(enricher: .emailToGravatar, sketchID: sketch.id, nodeIDs: [first])
        _ = try await api.scan(id: task)
        let repeat_ = try await api.launch(enricher: .emailToGravatar, sketchID: sketch.id, nodeIDs: [first])
        _ = try await api.scan(id: repeat_)
        let graph = try await api.graph(sketchID: sketch.id)
        XCTAssertEqual(graph.nodes.filter { $0.type == "Gravatar" }.count, 1, "findings merge too")
        XCTAssertEqual(graph.edges.count, 1)
    }

    func testHealthUsersKeysAndDeletion() async throws {
        let api = FlowsintSynthetic(installed: false)
        let down = try await api.health()
        XCTAssertFalse(down)
        await api.setInstalled(true)
        let up = try await api.health()
        XCTAssertTrue(up)
        let created = try await api.register(email: "makosh-osint@sh-inc.dev", password: "pw")
        XCTAssertTrue(created)
        let again = try await api.register(email: "makosh-osint@sh-inc.dev", password: "other")
        XCTAssertFalse(again)
        let users = await api.users
        XCTAssertEqual(users, ["makosh-osint@sh-inc.dev"])
        try await api.login(email: "makosh-osint@sh-inc.dev", password: "pw")
        do {
            try await api.login(email: "makosh-osint@sh-inc.dev", password: "wrong")
            XCTFail("wrong password")
        } catch { XCTAssertEqual(error as? OSINTFailure, .serviceAuthFailed, "\(error)") }
        let key = try await api.createKey(name: "HIBP_API_KEY", value: "secret-value")
        let keys = try await api.keys()
        XCTAssertEqual(keys, [key])
        XCTAssertEqual(key.name, "HIBP_API_KEY")
        XCTAssertFalse(String(reflecting: keys).contains("secret-value"))
        try await api.deleteKey(id: key.id)
        let none = try await api.keys()
        XCTAssertTrue(none.isEmpty)
        let sketch = try await sketch(api)
        try await api.deleteSketch(id: sketch.id)
        let gone = try await api.sketch(id: sketch.id)
        XCTAssertNil(gone)
        do {
            _ = try await api.graph(sketchID: sketch.id)
            XCTFail("deleted sketch has no graph")
        } catch { XCTAssertEqual(error as? OSINTFailure, .apiRejected(code: 404, stage: "graph"), "\(error)") }
        let names = try await api.enrichers()
        XCTAssertEqual(Set(names), Set(OSINTEnricher.allCases.map(\.rawValue)))
    }
}
