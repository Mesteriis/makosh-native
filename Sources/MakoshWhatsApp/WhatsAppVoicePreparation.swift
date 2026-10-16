import Darwin
import Foundation
import MakoshCore
import MakoshVoiceCodec

extension WhatsAppFiles {
  public func prepareVoice(samples: [Int16], accountID: UUID, chat: String) async throws
    -> WhatsAppPreparedFile
  {
    guard samples.count >= 24000, samples.count <= RecordedVoiceCodec.maximumSamples else {
      throw WhatsAppFailure.invalid
    }
    let bytes = try await RecordedVoiceCodec.encode(samples: samples)
    let lease = try makeLease(name: "Voice.ogg")
    defer { lease.remove() }
    let fd = Darwin.open(
      lease.url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw WhatsAppFailure.storage }
    defer { Darwin.close(fd) }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        try Task.checkCancellation()
        let written = Darwin.write(
          fd, buffer.baseAddress!.advanced(by: offset), min(65536, buffer.count - offset))
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw WhatsAppFailure.storage }
        offset += written
      }
    }
    var file = try await prepare(
      file: lease.url, accountID: accountID, chat: chat, kind: "audio",
      mime: "audio/ogg; codecs=opus")
    file.voice = true
    file.seconds = max(1, Int64(samples.count + 47999) / 48000)
    try await repository.savePreparedFile(file)
    return file
  }
}
extension WhatsAppServing {
  public func prepareVoice(accountID: UUID, chat: String, samples: [Int16]) async throws
    -> WhatsAppPreparedFile
  { throw WhatsAppFailure.unavailable }
}
extension WhatsAppWorker {
  public func prepareVoice(accountID: UUID, chat: String, samples: [Int16]) async throws
    -> WhatsAppPreparedFile
  {
    guard let repository, try await repository.accounts().contains(where: { $0.id == accountID }),
      let files
    else { throw WhatsAppFailure.invalid }
    return try await files.prepareVoice(samples: samples, accountID: accountID, chat: chat)
  }
}
