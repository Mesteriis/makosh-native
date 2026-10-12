import XCTest
import Foundation
import Darwin
import CryptoKit
@testable import MakoshCore

final class ArchiveFileEnvelopeTests: XCTestCase {
    private let key = Data(repeating: 0x42, count: 32)
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func testPlaintextDigestUsesFrozenInodeAndDoesNotConsumeEncryptionCapture() throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        try Data("abc".utf8).write(to: source)
        let capture = try ArchiveFileCapture(file: source, byteCount: 3)
        try FileManager.default.removeItem(at: source); try Data("xyz".utf8).write(to: source)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(try capture.plaintextSHA256(), expected)
        let receipt = try capture.seal(to: root.appendingPathComponent("encrypted"), key: key, objectID: UUID())
        XCTAssertEqual(receipt.plaintextSHA256, expected)
        XCTAssertEqual(try capture.plaintextSHA256(), expected)
    }
    func testPlaintextDigestCoversEveryChunkAndRejectsChangedInode() throws {
        for count in [0, 3 * 1024 * 1024 + 19] {
            let root = try directory(), source = root.appendingPathComponent("source")
            let bytes = Data((0..<count).map { UInt8($0 % 251) }); try bytes.write(to: source)
            let capture = try ArchiveFileCapture(file: source, byteCount: Int64(count))
            XCTAssertEqual(try capture.plaintextSHA256(), sha(bytes))
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: UInt64(count + 1)); try handle.close()
            XCTAssertThrowsError(try capture.plaintextSHA256())
        }
    }
    func testChunkRoundtripReceiptsModesAndOneUseIncludingEmpty() throws {
        for count in [0, 1, 1024 * 1024, 3 * 1024 * 1024 + 19] {
            let root = try directory(), source = root.appendingPathComponent("source")
            let envelope = root.appendingPathComponent("encrypted"), plain = root.appendingPathComponent("plain")
            let data = Data((0..<count).map { UInt8($0 % 251) }); try data.write(to: source)
            let capture = try ArchiveFileCapture(file: source,byteCount: Int64(count)), id = UUID()
            let receipt = try capture.seal(to: envelope,key: key,objectID: id)
            XCTAssertEqual(receipt.plaintextByteCount,Int64(count)); XCTAssertEqual(receipt.plaintextSHA256,sha(data))
            let encrypted = try Data(contentsOf: envelope)
            XCTAssertEqual(receipt.byteCount,Int64(encrypted.count)); XCTAssertEqual(receipt.sha256,sha(encrypted))
            XCTAssertEqual(try ArchiveFileEnvelope.open(file: envelope,to: plain,key: key,objectID: id,plaintextByteCount: Int64(count)),sha(data))
            XCTAssertEqual(try Data(contentsOf: plain),data); XCTAssertEqual(try Data(contentsOf: source),data)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: envelope.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
            XCTAssertThrowsError(try capture.seal(to: root.appendingPathComponent("again"),key: key,objectID: id))
        }
    }
    func testCaptureSurvivesUnlinkAndPathReplacementWithoutReadingReplacement() throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        let original = Data("original".utf8); try original.write(to: source)
        let capture = try ArchiveFileCapture(file: source,byteCount: Int64(original.count))
        try FileManager.default.removeItem(at: source)
        try Data("replaced".utf8).write(to: source)
        let id = UUID(), encrypted = root.appendingPathComponent("encrypted"), plain = root.appendingPathComponent("plain")
        _ = try capture.seal(to: encrypted,key: key,objectID: id)
        _ = try ArchiveFileEnvelope.open(file: encrypted,to: plain,key: key,objectID: id,plaintextByteCount: Int64(original.count))
        XCTAssertEqual(try Data(contentsOf: plain),original)
        XCTAssertEqual(try Data(contentsOf: source),Data("replaced".utf8))
    }
    func testDuplicatedFrozenCaptureCanRetryAfterUnlinkWithoutSharingReadCursor() throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        let bytes = Data(repeating: 0x47,count: 2 * 1024 * 1024 + 17); try bytes.write(to: source)
        let captured = try ArchiveFileCapture(file: source,byteCount: Int64(bytes.count))
        try FileManager.default.removeItem(at: source)
        for i in 0..<2 {
            let copy = try captured.duplicate(), id = UUID(), sealed = root.appendingPathComponent("sealed\(i)"), clear = root.appendingPathComponent("clear\(i)")
            _ = try copy.seal(to: sealed,key: key,objectID: id)
            _ = try ArchiveFileEnvelope.open(file: sealed,to: clear,key: key,objectID: id,plaintextByteCount: Int64(bytes.count))
            XCTAssertEqual(try Data(contentsOf: clear),bytes)
        }
    }
    func testRejectMissingSymlinkFIFOSizeCapAndMutation() throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        try Data([1,2,3]).write(to: source)
        let link = root.appendingPathComponent("link"), fifo = root.appendingPathComponent("fifo")
        try FileManager.default.createSymbolicLink(at: link,withDestinationURL: source)
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        for url in [root,link,fifo,root.appendingPathComponent("missing")] {
            XCTAssertThrowsError(try ArchiveFileCapture(file: url,byteCount: 3))
        }
        for size: Int64 in [-1,2,4,4 * 1024 * 1024 * 1024 + 1] { XCTAssertThrowsError(try ArchiveFileCapture(file: source,byteCount: size)) }
        let capture = try ArchiveFileCapture(file: source,byteCount: 3)
        let handle = try FileHandle(forWritingTo: source); try handle.truncate(atOffset: 1); try handle.close()
        let output = root.appendingPathComponent("output")
        XCTAssertThrowsError(try capture.seal(to: output,key: key,objectID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try ArchiveFileCapture(file: source,byteCount: 1))
    }
    func testWrongKeyObjectSizeTamperTruncationAndReorderingRemovePartialOutput() throws {
        let root = try directory(), source = root.appendingPathComponent("source")
        let data = Data(repeating: 0xa7,count: 2 * 1024 * 1024)
        try data.write(to: source)
        let id = UUID(), envelope = root.appendingPathComponent("encrypted")
        _ = try ArchiveFileCapture(file: source,byteCount: Int64(data.count)).seal(to: envelope,key: key,objectID: id)
        let original = try Data(contentsOf: envelope)
        func reject(_ bytes: Data, key: Data, id: UUID, size: Int64) throws {
            try bytes.write(to: envelope)
            let output = root.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(try ArchiveFileEnvelope.open(file: envelope,to: output,key: key,objectID: id,plaintextByteCount: size))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        try reject(original,key: Data(repeating: 0,count: 32),id: id,size: Int64(data.count))
        try reject(original,key: key,id: UUID(),size: Int64(data.count))
        try reject(original,key: key,id: id,size: Int64(data.count - 1))
        var tampered = original; tampered[tampered.count - 1] ^= 1
        try reject(tampered,key: key,id: id,size: Int64(data.count))
        try reject(Data(original.dropLast()),key: key,id: id,size: Int64(data.count))
        try reject(original + Data([0]),key: key,id: id,size: Int64(data.count))
        let headerSize = 60, frameSize = 8 + 1024 * 1024 + 28
        let reordered = Data(original.prefix(headerSize)) + original.subdata(in: (headerSize + frameSize)..<original.count) + original.subdata(in: headerSize..<(headerSize + frameSize))
        try reject(reordered,key: key,id: id,size: Int64(data.count))
    }
    func testExclusiveOutputNeverOverwritesOrFollowsSymlink() throws {
        let root = try directory(), source = root.appendingPathComponent("source"), existing = root.appendingPathComponent("existing")
        try Data([1]).write(to: source); try Data([9]).write(to: existing)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link,withDestinationURL: existing)
        for destination in [existing,link] {
            XCTAssertThrowsError(try ArchiveFileCapture(file: source,byteCount: 1).seal(to: destination,key: key,objectID: UUID()))
        }
        XCTAssertEqual(try Data(contentsOf: existing),Data([9]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),existing.path)
        XCTAssertThrowsError(try ArchiveFileCapture(file: source,byteCount: 1).seal(to: root.appendingPathComponent("short-key"),key: Data(),objectID: UUID()))
    }
}
