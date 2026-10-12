import XCTest
import Foundation
import MakoshCore
@testable import MakoshTelegram

final class TelegramPendingUploadArchiveDraftTests: XCTestCase {
    // Catches losing the new source-only Media allowance while retaining an authenticated ZIP descriptor.
    func testSchema18KeepsAllDocumentMediaWithStrictCachedArchiveFields() async throws {
        var json = try await fixtureJSON(), items = json["items"] as! [[String: Any]]
        for index in items.indices {
            var facts = items[index]["sourceFacts"] as! [String: Any]
            facts["selectionMIME"] = "image/png"; facts["image"] = ["kind": "decoded", "width": 64, "height": 64]
            items[index]["sourceFacts"] = facts
        }
        json["items"] = items; json["presentation"] = "media"
        XCTAssertFalse(try decode(json).isValid, "Schema16 must retain its visual payload requirement")
        json["schemaVersion"] = 18
        let draft: TelegramPendingUploadDraft
        do { draft = try decode(json) } catch { return XCTFail("Complete schema18 must decode: \(error)") }
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.items.map { $0.file.attachment.kind }, ["file", "file"])
        XCTAssertEqual(try decode(object(draft)), draft)
        for mutation in 0..<4 {
            var invalid = json
            switch mutation {
            case 0: invalid.removeValue(forKey: "archive")
            case 1: invalid["archive"] = NSNull()
            case 2: invalid["futureMediaPolicy"] = true
            default: invalid["schemaVersion"] = 19
            }
            try refused(invalid)
        }
    }

    // Catches treating Archive as N ordinary native items, dropping its originals, or rewriting raw editor input.
    func testLiteralSchema16RetainsAllOriginalItemsArchiveAndRichCaption() async throws {
        let json = try await fixtureJSON()
        let draft: TelegramPendingUploadDraft
        do { draft = try decode(json) } catch { return XCTFail("Valid schema16 refused: \(error)") }
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.schemaVersion, 16)
        XCTAssertEqual(draft.presentation, .archive); XCTAssertEqual(draft.items.count, 2)
        let encoded = try object(draft)
        XCTAssertEqual(encoded["archive"] as? NSDictionary, json["archive"] as? NSDictionary)
        XCTAssertEqual(encoded["items"] as? NSArray, json["items"] as? NSArray)
        XCTAssertEqual(encoded["captionInput"] as? NSDictionary, json["captionInput"] as? NSDictionary)
        XCTAssertNil(encoded["file"])
        XCTAssertEqual(try decode(encoded), draft)
    }

    // Catches an initializer choosing15 or caption/disposition updates discarding the16 cache.
    func testConstructorAndUpdatesRetainDescriptorAndReferenceCaptionRules() async throws {
        let json = try await fixtureJSON(), base = try sourceDraft(json)
        let archive = try descriptor(json)
        let draft = try TelegramPendingUploadDraft(id: base.id, accountID: base.accountID, chatID: base.chatID,
            title: base.title, captionInput: base.captionInput, originalDraft: base.originalDraft, replyTarget: base.replyTarget,
            items: base.items, isGrouped: false, presentation: .archive, archive: archive)
        XCTAssertEqual(draft.schemaVersion, 16); XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.captionRules, .reference); XCTAssertEqual(draft.archive, archive)
        let input = try TelegramComposerInput(formattedText: .init(text: "  Updated 😀  "), selection: .init(location: 3, length: 1))
        let updated = draft.updating(captionInput: input, captionAboveMedia: false, mediaSpoiler: false, disposition: .submissionStarted)
        XCTAssertEqual(updated.archive, archive); XCTAssertEqual(updated.items, draft.items)
        XCTAssertEqual(updated.schemaVersion, 16); XCTAssertTrue(updated.isValid)
        XCTAssertEqual(try decode(object(updated)), updated)
    }

    // Catches accepting a new field (including null) in old schemas or reinterpreting their presentation enum.
    func testSchemas1Through15RejectArchivePresenceAndOldPresentationRejectsArchive() async throws {
        let current = try await fixtureJSON()
        for version in 1...15 {
            var old = version < 6 ? try object(pendingUploadFixture()) : try pendingUploadBatchJSON()
            old["schemaVersion"] = version
            if version >= 14 {
                old = try pendingUploadSourceFactsJSON(); old["schemaVersion"] = version
            } else if version >= 8 { old["presentation"] = "file" }
            _ = try decode(old)
            for value: Any in [NSNull(), current["archive"]!] {
                var invalid = old; invalid["archive"] = value
                XCTAssertThrowsError(try decode(invalid), "schema\(version) must refuse archive key presence")
            }
            if version >= 8 {
                var invalid = old; invalid["presentation"] = "archive"
                XCTAssertThrowsError(try decode(invalid), "schema\(version) must refuse Archive presentation")
            }
        }
    }

    // Catches synthesized Codable silently dropping unknown keys/nulls or accepting future format meanings.
    func testDescriptorAndMemberRequireExactNonNullKeysAndVersion1() async throws {
        let json = try await fixtureJSON(), archive = json["archive"] as! [String: Any]
        for key in ["id", "formatVersion", "file", "members"] {
            var missing = archive; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try decodeDescriptor(missing))
            var null = archive; null[key] = NSNull()
            XCTAssertThrowsError(try decodeDescriptor(null))
        }
        for (key, value): (String, Any) in [("future", true), ("formatVersion", 2), ("formatVersion", 0), ("formatVersion", "1")] {
            var invalid = archive; invalid[key] = value
            XCTAssertThrowsError(try decodeDescriptor(invalid))
        }
        for action in 0..<5 {
            var invalid = archive, members = archive["members"] as! [[String: Any]]
            switch action {
            case 0: members[0].removeValue(forKey: "itemID")
            case 1: members[0]["entryName"] = NSNull()
            case 2: members[0]["future"] = true
            case 3: members[0]["entryName"] = 1
            default: members[0]["itemID"] = NSNull()
            }
            invalid["members"] = members
            XCTAssertThrowsError(try decodeDescriptor(invalid))
        }
    }

    // Catches an optional16 descriptor, downgrade smuggling, ambiguous legacy resources, or untracked future top-level fields.
    func testSchema16RequiresArchiveFactsAndStrictFieldsAndCannotDowngrade() async throws {
        let json = try await fixtureJSON()
        for action in 0..<8 {
            var invalid = json
            switch action {
            case 0: invalid.removeValue(forKey: "archive")
            case 1: invalid["archive"] = NSNull()
            case 2: invalid["schemaVersion"] = 15
            case 3: invalid["schemaVersion"] = 17
            case 4: invalid["future"] = true
            case 5: invalid["file"] = ((json["items"] as! [[String: Any]])[0]["file"])
            case 6: var items = json["items"] as! [[String: Any]]; items[1].removeValue(forKey: "sourceFacts"); invalid["items"] = items
            default: var items = json["items"] as! [[String: Any]]; items[0]["sourceFacts"] = NSNull(); invalid["items"] = items
            }
            try refused(invalid)
        }
    }

    // Catches descriptor identity aliasing, member reorder/loss, or binding against another account/preparation.
    func testArchiveIdentityMembershipAndResourceBindingsAreStrict() async throws {
        let json = try await fixtureJSON(), items = json["items"] as! [[String: Any]]
        for action in 0..<12 {
            var invalid = json, archive = json["archive"] as! [String: Any], members = archive["members"] as! [[String: Any]], file = archive["file"] as! [String: Any]
            switch action {
            case 0: archive["id"] = "00000000-0000-0000-0000-000000000000"
            case 1: archive["id"] = items[0]["id"]
            case 2: archive["id"] = (items[0]["file"] as! [String: Any])["id"]
            case 3: archive["id"] = file["id"]
            case 4: file["id"] = (items[0]["file"] as! [String: Any])["id"]
            case 5: members.reverse()
            case 6: members.removeLast()
            case 7: members[1] = members[0]
            case 8: members[0]["itemID"] = "00000000-0000-0000-0000-000000000099"
            case 9: var identity = file["identity"] as! [String: Any]; identity["conversationID"] = "43"; file["identity"] = identity
            case 10: var attachment = file["attachment"] as! [String: Any]; attachment["id"] = "prepared:00000000-0000-0000-0000-0000000000a1"; file["attachment"] = attachment
            default: var attachment = file["attachment"] as! [String: Any]; attachment["name"] = "other.zip"; file["attachment"] = attachment
            }
            archive["file"] = file; archive["members"] = members; invalid["archive"] = archive
            try refused(invalid)
        }
    }

    // Catches unsafe or canonically colliding allocated names, without recalculating the durable allocator.
    func testDurableEntryNamesAllowHiddenAndLongNamesButRefuseUnsafeOrPortableDuplicates() async throws {
        let json = try await fixtureJSON(), base = try sourceDraft(json)
        var archive = json["archive"] as! [String: Any], members = archive["members"] as! [[String: Any]]
        members[0]["entryName"] = String(repeating: "x", count: 1040); members[1]["entryName"] = ".hidden"
        archive["members"] = members
        XCTAssertTrue(try decodeDescriptor(archive).isValid(identity: base.file.identity, items: base.items))
        for names in [["same", "same"], ["Same", "same"], ["e\u{301}", "é"], ["../x", "two"], ["a\\b", "two"], ["a:b", "two"], ["a\n", "two"], ["", "two"], ["..", "two"], [String(repeating: "x", count: 1041), "two"]] {
            var invalid = json, value = archive
            for index in members.indices { members[index]["entryName"] = names[index] }
            value["members"] = members; invalid["archive"] = value; try refused(invalid)
        }
    }

    // Catches a ZIP record which is not a plain durable encrypted file or breaks ZIP32/storage-envelope metadata limits.
    func testArchiveRecordRequiresDurableOwnedScopePlainKindAndBoundedSizeHashes() async throws {
        let json = try await fixtureJSON()
        for action in 0..<10 {
            var invalid = json, archive = json["archive"] as! [String: Any], file = archive["file"] as! [String: Any]
            switch action {
            case 0: file["state"] = "pending"
            case 1: file["plaintextSHA256"] = "invalid"
            case 2: file["sha256"] = "invalid"
            case 3: file["objectKey"] = "../outside"
            case 4: file["plaintextByteCount"] = 21; var attachment = file["attachment"] as! [String: Any]; attachment["size"] = 21; file["attachment"] = attachment
            case 5: file["plaintextByteCount"] = 4294967295 as UInt64; var attachment = file["attachment"] as! [String: Any]; attachment["size"] = 4294967295 as UInt64; file["attachment"] = attachment
            case 6: var attachment = file["attachment"] as! [String: Any]; attachment["kind"] = "video"; file["attachment"] = attachment
            case 7: file["byteCount"] = 0
            case 8: file["storageID"] = "invalid"
            default: var attachment = file["attachment"] as! [String: Any]; attachment["size"] = 999; file["attachment"] = attachment
            }
            archive["file"] = file; invalid["archive"] = archive; try refused(invalid)
        }
    }

    // Catches admitting a history or legacy-purpose ZIP as a new outgoing bundle.
    func testArchiveZIPRequiresOutgoingPurposeInBothDurableStates() async throws {
        let json = try await fixtureJSON(), base = try sourceDraft(json)
        let cases: [(Any?, Bool)] = [
            (nil, false), (NSNull(), false),
            (["conversation": ["defaultEnabled": true]], false),
            (["preparation": [:]], false),
            (["outgoing": ["defaultEnabled": false]], true),
            (["outgoing": ["defaultEnabled": true]], true)
        ]
        for state in ["stored", "local"] {
            for (purpose, valid) in cases {
                var archive = json["archive"] as! [String: Any], file = archive["file"] as! [String: Any]
                file["state"] = state
                if let purpose { file["purpose"] = purpose } else { file.removeValue(forKey: "purpose") }
                archive["file"] = file
                let value = try decodeDescriptor(archive)
                XCTAssertEqual(value.isValid(identity: base.file.identity, items: base.items), valid, "\(state): \(String(describing: purpose))")
            }
        }
    }

    // Catches stale source facts, substituting canonical JPEG metadata for the retained raw original, or allowing recorder intent.
    func testArchiveBindsCompleteRawFactsIncludingPhotoOriginalWithoutDroppingCanonicalResources() async throws {
        var json = try await fixtureJSON(), items = json["items"] as! [[String: Any]]
        var prepared = items[0]["file"] as! [String: Any], original = prepared
        var attachment = prepared["attachment"] as! [String: Any]
        attachment["kind"] = "photo"; attachment["name"] = "first.jpg"; prepared["attachment"] = attachment
        var originalAttachment = original["attachment"] as! [String: Any]
        originalAttachment["id"] = "original:00000000-0000-0000-0000-000000000011"; originalAttachment["name"] = "first.png"
        original["attachment"] = originalAttachment; original["id"] = "00000000-0000-0000-0000-000000000099"
        items[0]["file"] = prepared; items[0]["originalFile"] = original
        var facts = items[0]["sourceFacts"] as! [String: Any]
        facts["role"] = "original"; facts["name"] = "first.png"; facts["selectionMIME"] = "image/png"; facts["image"] = ["kind": "decoded", "width": 80, "height": 80]
        items[0]["sourceFacts"] = facts; json["items"] = items
        let draft = try decode(json); XCTAssertTrue(draft.isValid)
        XCTAssertEqual(try object(draft)["items"] as? NSArray, items as NSArray)
        var cached = json; cached["presentation"] = "media"
        XCTAssertTrue(try decode(cached).isValid)
        for action in 0..<4 {
            var invalid = json, changed = items, broken = facts
            switch action {
            case 0: broken["role"] = "prepared"
            case 1: broken["name"] = "first.jpg"
            case 2: broken["plaintextSHA256"] = String(repeating: "b", count: 64)
            default: broken["grouping"] = "voice"
            }
            changed[0]["sourceFacts"] = broken; invalid["items"] = changed; try refused(invalid)
        }
    }

    // Catches group/above/spoiler semantics leaking into the single ZIP, while inactive File retains its cache.
    func testActiveArchiveFlagsFailClosedWhileInactiveFileCacheRetainsOrdinaryBehavior() async throws {
        let json = try await fixtureJSON()
        for key in ["isGrouped", "captionAboveMedia", "mediaSpoiler"] { var invalid = json; invalid[key] = true; try refused(invalid) }
        var cached = json; cached["presentation"] = "file"; cached["isGrouped"] = true
        let file = try decode(cached); XCTAssertTrue(file.isValid)
        XCTAssertEqual(try object(file)["archive"] as? NSDictionary, json["archive"] as? NSDictionary)
    }

    // Catches expecting N or an extra leading caption ID for Archive, or weakening existing File cardinality.
    func testAcceptedArchiveHasExactlyOneLocalIDWhileInactiveFileUsesOriginalProjection() async throws {
        let json = try await fixtureJSON()
        for (mode, count, valid) in [("archive", 1, true), ("archive", 0, false), ("archive", 2, false), ("file", 1, false), ("file", 3, true)] {
            var value = json; value["presentation"] = mode
            value["disposition"] = ["acceptedBatch": ["messageIDs": (0..<count).map { ["peerID": 42, "namespace": 1, "id": $0 + 1] }]]
            XCTAssertEqual(try decode(value).isValid, valid, "\(mode)/\(count)")
        }
        for (peer, namespace) in [(43, 1), (42, 0)] {
            var invalid = json; invalid["disposition"] = ["acceptedBatch": ["messageIDs": [["peerID": peer, "namespace": namespace, "id": 1]]]]
            try refused(invalid)
        }
    }

    // Catches widening any generic grouping or per-item projection route when the public enum gains Archive.
    func testArchiveCannotBeClassifiedGroupedOrProjectedPerItem() async throws {
        let json = try await fixtureJSON(), base = try sourceDraft(json)
        XCTAssertEqual(TelegramUploadSourceClassifier.options(for: base.items.compactMap(\.sourceFacts)), [.file])
        XCTAssertEqual(TelegramUploadSourceClassifier.initialPresentation(for: base.items.compactMap(\.sourceFacts), asMedia: true), .file)
        XCTAssertFalse(TelegramUploadSourceClassifier.allowsGrouping(for: base.items.compactMap(\.sourceFacts), presentation: .archive))
        XCTAssertFalse(TelegramUploadPresentation.archive.allowsGrouping(base.items))
        XCTAssertFalse(TelegramUploadPresentation.archive.allowsGrouping([(name: "a.txt", isVisual: false)]))
        XCTAssertFalse(TelegramUploadPresentation.archive.allowsGrouping([(name: "a.txt", isVisual: false, metadata: nil)]))
        XCTAssertNil(base.items[0].payload(for: .archive))
        let staged = TelegramUploadFile(id: UUID(), name: "a.txt", size: 1, mode: .file, pixelWidth: nil, pixelHeight: nil,
            url: URL(fileURLWithPath: "/synthetic/payload"), directory: URL(fileURLWithPath: "/synthetic"))
        let item = TelegramUploadBatchItem(id: UUID(), file: staged)
        XCTAssertNil(item.presented(as: .archive))
        XCTAssertFalse(TelegramUploadPresentation.archive.allowsGrouping([item]))
    }

    // Catches metadata bounds depending only on raw bytes or allowing zero/aliased IDs in the descriptor.
    func testDescriptorSharedCountCatalogAndAggregateBoundsAndAttachmentNamespace() async throws {
        let json = try await fixtureJSON(), base = try sourceDraft(json), archive = try descriptor(json)
        XCTAssertEqual(TelegramPendingUploadArchive.attachmentID(archive.id), "archive:00000000-0000-0000-0000-0000000000a1")
        XCTAssertTrue(archive.isValid(identity: base.file.identity, items: base.items))
        let expanded = try expandedItems(base: base.items[0], count: 1024)
        let members = expanded.enumerated().map { index, item in
            TelegramPendingUploadArchive.Member(itemID: item.id, entryName: "e" + String(format: "%04d", index) + String(repeating: "x", count: 973))
        }
        let exact = TelegramPendingUploadArchive(id: archive.id, file: archive.file, members: members)
        XCTAssertTrue(exact.isValid(identity: base.file.identity, items: expanded), "1024*(46+978)=1MiB catalog")
        let over = TelegramPendingUploadArchive(id: archive.id, file: archive.file,
            members: members.map { .init(itemID: $0.itemID, entryName: $0.entryName + "x") })
        XCTAssertFalse(over.isValid(identity: base.file.identity, items: expanded))
        let tooMany = try expandedItems(base: base.items[0], count: 1025)
        XCTAssertFalse(TelegramPendingUploadArchive(id: archive.id, file: archive.file,
            members: tooMany.map { .init(itemID: $0.id, entryName: $0.file.attachment.name) }).isValid(identity: base.file.identity, items: tooMany))
        let large = try expandedItems(base: base.items[0], count: 2, rawSize: 750 * 1024 * 1024)
        let largeArchive = TelegramPendingUploadArchive(id: archive.id, file: archive.file,
            members: large.map { .init(itemID: $0.id, entryName: $0.file.attachment.name) })
        XCTAssertTrue(largeArchive.isValid(identity: base.file.identity, items: large))
        XCTAssertFalse(largeArchive.isValid(identity: base.file.identity, items: try expandedItems(base: base.items[0], count: 2, rawSize: 750 * 1024 * 1024 + 1)))
    }

    private func decode(_ json: [String: Any]) throws -> TelegramPendingUploadDraft {
        try JSONDecoder().decode(TelegramPendingUploadDraft.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func decodeDescriptor(_ json: [String: Any]) throws -> TelegramPendingUploadArchive {
        try JSONDecoder().decode(TelegramPendingUploadArchive.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func descriptor(_ json: [String: Any]) throws -> TelegramPendingUploadArchive { try decodeDescriptor(json["archive"] as! [String: Any]) }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func refused(_ json: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        do { let value = try decode(json); XCTAssertFalse(value.isValid, "Invalid archive sendable", file: file, line: line) }
        catch is DecodingError { }
    }
    private func sourceDraft(_ json: [String: Any]) throws -> TelegramPendingUploadDraft {
        var source = json; source["schemaVersion"] = 15; source["presentation"] = "file"; source.removeValue(forKey: "archive")
        return try decode(source)
    }
    private func expandedItems(base: TelegramPendingUploadItem, count: Int, rawSize: Int64? = nil) throws -> [TelegramPendingUploadItem] {
        let original = try object(base)
        return try (0..<count).map { index in
            var item = original, record = original["file"] as! [String: Any], attachment = record["attachment"] as! [String: Any], facts = original["sourceFacts"] as! [String: Any]
            let id = String(format: "10000000-0000-0000-0000-%012d", index + 1)
            item["id"] = id; record["id"] = String(format: "20000000-0000-0000-0000-%012d", index + 1)
            attachment["id"] = "prepared:" + id; attachment["name"] = "source\(index).txt"
            facts["itemID"] = id; facts["name"] = "source\(index).txt"
            if let rawSize { record["plaintextByteCount"] = rawSize; attachment["size"] = rawSize; facts["byteCount"] = rawSize }
            record["attachment"] = attachment; item["file"] = record; item["sourceFacts"] = facts
            return try JSONDecoder().decode(TelegramPendingUploadItem.self, from: JSONSerialization.data(withJSONObject: item))
        }
    }
    private func fixtureJSON() async throws -> [String: Any] {
        var json = try pendingUploadSourceFactsJSON()
        json["schemaVersion"] = 16; json["presentation"] = "archive"; json["isGrouped"] = false
        let base = try sourceDraft(json), archiveID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-schema16-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input"); try Data("Synthetic 😀".utf8).write(to: input)
        var sources: [TelegramUploadArchiveIO.Source] = []
        defer { sources.forEach { try? TelegramUploadFileIO.discard($0.file) } }
        for item in base.items {
            let staged = try await TelegramUploadFileIO.stage(input, mode: .file)
            let file = TelegramUploadFile(id: staged.id, name: item.file.attachment.name, size: staged.size, mode: .file,
                pixelWidth: nil, pixelHeight: nil, url: staged.url, directory: staged.directory)
            sources.append(.init(itemID: item.id, file: file))
        }
        let zip = try await TelegramUploadArchiveIO.prepare(sources)
        defer { try? TelegramUploadFileIO.discard(zip.file) }
        let recordID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!
        let capture = try ArchiveFileCapture(file: zip.file.url, byteCount: zip.file.size)
        let receipt = try capture.seal(to: directory.appendingPathComponent("sealed"), key: Data(repeating: 9, count: 32), objectID: recordID)
        let record = ArchiveFileRecord(id: recordID, identity: base.file.identity,
            attachment: .init(id: "archive:00000000-0000-0000-0000-0000000000a1", kind: "file", name: "Telegram Archive.zip", size: receipt.plaintextByteCount),
            objectKey: "vaults/synthetic/files/" + recordID.uuidString.lowercased(), storageID: String(repeating: "a", count: 64),
            receipt: receipt, capturedAt: Date(timeIntervalSince1970: 100), state: .stored, purpose: .outgoing(defaultEnabled: false))
        json["archive"] = ["id": archiveID.uuidString, "formatVersion": 1, "file": try object(record),
            "members": [["itemID": "00000000-0000-0000-0000-000000000011", "entryName": "first.txt"],
                        ["itemID": "00000000-0000-0000-0000-000000000012", "entryName": "second.txt"]]]
        return json
    }
}
