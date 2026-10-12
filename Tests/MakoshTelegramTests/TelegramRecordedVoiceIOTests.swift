import Foundation
import XCTest
import Darwin
import CryptoKit
@testable import MakoshTelegram

@MainActor final class TelegramRecordedVoiceIOTests: XCTestCase {
    // Missing secure staging/provenance or probe makes recovery depend on the recorder's memory.
    func testRecordingCreatesOwnedStageAndReprobesActualEncodedFacts() async throws {
        let file = try await TelegramRecordedVoiceIO.prepare(samples: [Int16](repeating: 0, count: 48_137))
        defer { try? TelegramUploadFileIO.discard(file) }
        XCTAssertEqual(file.mode, .file); XCTAssertEqual(file.name, "Voice.ogg")
        let bytes = try Data(contentsOf: file.url)
        XCTAssertEqual(file.size, Int64(bytes.count)); XCTAssertTrue(bytes.starts(with: Data("OggS".utf8)))
        XCTAssertEqual(file.metadata, try recordedVoiceDescriptor(sampleCount: 48_137,
            hash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            waveform: Data(repeating: 0, count: 63)))
        var info = stat(); XCTAssertEqual(lstat(file.directory.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(file.url.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        try await TelegramUploadFileIO.verifyMetadata(file)
        let restored = try await TelegramUploadFileIO.restoredStage(id: file.id, name: file.name, size: file.size,
            mode: .file, url: file.url, directory: file.directory, metadata: file.metadata)
        XCTAssertEqual(restored, file)
    }

    // Rechecks must reject changed digest/count/corrupt bytes and ownership failures.
    func testFrozenVoiceCannotHideChangedCountBytesOrSymlink() async throws {
        let file = try await TelegramRecordedVoiceIO.prepare(samples: [Int16](repeating: 0, count: 1_000))
        defer { try? TelegramUploadFileIO.discard(file) }
        let bytes = try Data(contentsOf: file.url), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        for metadata in [try recordedVoiceDescriptor(sampleCount: 999, hash: hash),
                         try recordedVoiceDescriptor(sampleCount: 1_000, hash: String(repeating: "0", count: 64))] {
            let forged = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .file,
                pixelWidth: nil, pixelHeight: nil, url: file.url, directory: file.directory, metadata: metadata)
            do { try await TelegramUploadFileIO.verifyMetadata(forged); XCTFail("Forged voice accepted") } catch {}
        }
        var corrupt = bytes; corrupt[corrupt.count - 1] ^= 1
        try corrupt.write(to: file.url)
        do { try await TelegramUploadFileIO.verifyMetadata(file); XCTFail("Corrupt voice accepted") } catch {}
        try FileManager.default.removeItem(at: file.url)
        try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        do { try await TelegramUploadFileIO.verifyMetadata(file); XCTFail("Symlink accepted") } catch {}
    }

    // Picker bytes must keep ordinary-file provenance even when they are our own valid Ogg output.
    func testPickingRecordedBytesDoesNotClassifyThemAsVoice() async throws {
        let recording = try await TelegramRecordedVoiceIO.prepare(samples: [Int16](repeating: 0, count: 1_000))
        defer { try? TelegramUploadFileIO.discard(recording) }
        let picked = try await TelegramUploadFileIO.stage(recording.url, mode: .file)
        defer { try? TelegramUploadFileIO.discard(picked) }
        XCTAssertNil(picked.metadata)
    }

    // Lossy decoding must not replace the original PCM waveform during validation/restoration.
    func testOriginalPCMWaveformSurvivesLossyEncodedByteProbe() async throws {
        var pcm = [Int16](repeating: 0, count: 48_137)
        for index in 0..<100 { pcm[index] = 1_000 }
        var expected = Data(repeating: 0, count: 63); expected[0] = 0x0c
        let file = try await TelegramRecordedVoiceIO.prepare(samples: pcm)
        defer { try? TelegramUploadFileIO.discard(file) }
        let decoded = try await TelegramRecordedVoiceCodec.decodeRecording(Data(contentsOf: file.url))
        XCTAssertNotEqual(try TelegramVoiceWaveform.make(samples: decoded), expected, "The fixture must expose lossy waveform changes")
        try await TelegramUploadFileIO.verifyMetadata(file)
        let restored = try await TelegramUploadFileIO.restoredStage(id: file.id, name: file.name, size: file.size,
            mode: .file, url: file.url, directory: file.directory, metadata: file.metadata)
        XCTAssertEqual(restored.metadata?.voice?.waveform, expected)
    }

    // Earlier schema11 pointers had explicit null waveform; restoration must retain it.
    func testLegacyNullWaveformIsPreservedDuringRestoration() async throws {
        let file = try await TelegramRecordedVoiceIO.prepare(samples: [Int16](repeating: 1_000, count: 48_000))
        defer { try? TelegramUploadFileIO.discard(file) }
        let metadata = try XCTUnwrap(file.metadata?.voice)
        let legacy = TelegramUploadMetadata.voice(.init(sampleCount: metadata.sampleCount, plaintextSHA256: metadata.plaintextSHA256))
        let restored = try await TelegramUploadFileIO.restoredStage(id: file.id, name: file.name, size: file.size,
            mode: .file, url: file.url, directory: file.directory, metadata: legacy)
        XCTAssertNotNil(restored.metadata?.voice); XCTAssertNil(restored.metadata?.voice?.waveform)
        XCTAssertEqual(restored.metadata, legacy)
    }
}
