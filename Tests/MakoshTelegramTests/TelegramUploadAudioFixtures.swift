import Foundation
import AVFoundation
import XCTest

// Synthetic mono PCM only; never records or reads an account or microphone.
func writeUploadAudioFixture(_ url: URL, seconds: Double = 1.25) throws {
    let rate = 44_100, frames = Int(seconds * 44_100)
    var pcm = Data(capacity: frames * 2)
    for frame in 0..<frames {
        var sample = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(rate)) * 8_000).littleEndian
        withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
    }
    var data = Data("RIFF".utf8)
    func u32(_ value: UInt32) {
        var number = value.littleEndian
        withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
    }
    func u16(_ value: UInt16) {
        var number = value.littleEndian
        withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
    }
    u32(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    data.append(Data("data".utf8)); u32(UInt32(pcm.count)); data.append(pcm)
    try data.write(to: url)
}

func writeUploadTaggedAudioFixture(_ url: URL, title: String, performer: String) async throws {
    let wav = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wav")
    try writeUploadAudioFixture(wav, seconds: 1.25)
    defer { try? FileManager.default.removeItem(at: wav) }
    let asset = AVURLAsset(url: wav)
    let export = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
    func tag(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier; item.value = value as NSString
        return item
    }
    export.metadata = [tag(.iTunesMetadataSongName, title), tag(.iTunesMetadataArtist, performer)]
    try await export.export(to: url, as: .m4a)
}

// Golden synthetic mono MP3; tests do not invoke ffmpeg.
// Generation: ffmpeg -f lavfi -i sine=frequency=440:sample_rate=22050:duration=1.25 -ac 1
// -c:a libmp3lame -b:a 32k -metadata title="Synthetic MP3" -metadata artist="Synthetic Artist"
// -id3v2_version 3 -write_id3v1 0 synthetic.mp3
// SHA256: f89040055e7d09f1a11249fc0f75bea226d340bef5c1283e1243c238b80da0c8; 5503 bytes.
func writeUploadMP3AudioFixture(_ url: URL) throws {
    let bytes = try XCTUnwrap(Data(base64Encoded: """
        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
        qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqg==
        """, options: .ignoreUnknownCharacters))
    try bytes.write(to: url)
}
