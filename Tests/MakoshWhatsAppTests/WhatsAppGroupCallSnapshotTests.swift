import XCTest

@testable import MakoshWhatsApp

final class WhatsAppGroupCallSnapshotTests: XCTestCase {
  func testGroupTargetsTwoThrough31AndOwnAliasesRejected() throws {
    for count in [2, 31] {
      XCTAssertEqual(
        try WhatsAppGroupCallTargets.validate(
          (0..<count).map { "20\($0)@lid" }, ownAliases: ["100@lid", "700@s.whatsapp.net"]
        ).count, count)
    }
    for targets in [
      ["200@lid"], (0..<32).map { "20\($0)@lid" }, ["200@lid", "200@lid"],
      ["100:2@lid", "200@lid"], ["700@s.whatsapp.net", "200@lid"], ["500@g.us", "200@lid"],
    ] {
      XCTAssertThrowsError(
        try WhatsAppGroupCallTargets.validate(
          targets, ownAliases: ["100@lid", "700@s.whatsapp.net"]))
    }
  }
  func testLegacySnapshotDecodeAndNoRelaySecrets() throws {
    let old: [String: Any] = [
      "id": "GROUP", "epoch": 11, "peer": "500@g.us", "state": "active", "incoming": false,
      "video": false, "remoteVideo": false, "videoRequested": false, "muted": false,
    ]
    let decoded = try JSONDecoder().decode(
      WhatsAppCallSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertNil(decoded.group)
    var value = old
    value["group"] = [
      "groupJID": "500@g.us", "rosterRevision": 5, "participantLimit": 32, "relay": "PRIVATE_RELAY",
      "participants": [
        [
          "jid": "200@lid", "state": "future-state", "me": true,
          "devices": [["jid": "200:2@lid", "pid": 4, "capability": "PRIVATE_CAPABILITY"]],
        ]
      ],
    ]
    let group = try JSONDecoder().decode(
      WhatsAppCallSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    XCTAssertEqual(group.group?.participants.first?.state, "future-state")
    XCTAssertEqual(group.group?.participants.first?.me, true)
    XCTAssertEqual(group.group?.participants.first?.devices.first?.pid, 4)
    let encoded = String(decoding: try JSONEncoder().encode(group), as: UTF8.self)
    XCTAssertFalse(encoded.contains("PRIVATE"))
    XCTAssertFalse(encoded.contains("relay"))
    XCTAssertFalse(encoded.contains("capability"))
    var oversized = value["group"] as! [String: Any]
    oversized["participants"] = (0..<33).map {
      ["jid": "20\($0)@lid", "devices": []] as [String: Any]
    }
    value["group"] = oversized
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        WhatsAppCallSnapshot.self, from: JSONSerialization.data(withJSONObject: value)))
  }
}
extension WhatsAppGroupCallSnapshotTests {
  func testLIDDotsAndPNDeviceAliasesNeverRebindParticipants() throws {
    XCTAssertEqual(
      try WhatsAppGroupCallTargets.validate(["100.part@lid", "200@lid"], ownAliases: ["100@lid"]),
      ["100.part@lid", "200@lid"])
    XCTAssertThrowsError(
      try WhatsAppGroupCallTargets.validate(
        ["700@s.whatsapp.net", "200@lid"], ownAliases: ["700.4@s.whatsapp.net"]))
    XCTAssertEqual(
      try WhatsAppGroupCallTargets.validate(["200@lid", "300@lid"], ownAliases: ["_@lid"]),
      ["200@lid", "300@lid"])
    for alias in ["@lid", ":2@lid", "200:bad@lid"] {
      XCTAssertThrowsError(
        try WhatsAppGroupCallTargets.validate(["200@lid", "300@lid"], ownAliases: [alias]))
    }
    let malformed = Data(#"{"jid":"200:bad@lid","pid":1}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(WhatsAppCallDeviceIdentity.self, from: malformed))
  }
}
