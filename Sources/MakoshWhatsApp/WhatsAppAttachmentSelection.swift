import Foundation
import MakoshCore
import UniformTypeIdentifiers

public struct WhatsAppAttachmentCandidate: Sendable {
  public let file: URL
  public let kind: String, mime: String
  public let size: Int64
}
public enum WhatsAppAttachmentSelectionFailure: Error, LocalizedError, Sendable {
  case count, size, file
  public var errorDescription: String? {
    switch self {
    case .count: "Можно прикрепить не больше 10 файлов."
    case .size: "Каждый файл должен быть не больше 100 МиБ, весь пакет — не больше 1000 МиБ."
    case .file: "Выберите обычные файлы. Папки и символические ссылки не поддерживаются."
    }
  }
}
public enum WhatsAppAttachmentSelection {
  @concurrent public static func inspect(
    _ urls: [URL], asFiles: Bool,
    existing: [WhatsAppPreparedFile]
  ) async throws -> [WhatsAppAttachmentCandidate] {
    try await BackgroundWork.run {
      guard !urls.isEmpty, urls.count <= 10, existing.count <= 10 - urls.count else {
        throw WhatsAppAttachmentSelectionFailure.count
      }
      var total: Int64 = 0
      for file in existing {
        guard (0...100 * 1024 * 1024).contains(file.size) else {
          throw WhatsAppAttachmentSelectionFailure.size
        }
        total += file.size
      }
      return try urls.map { url in
        guard url.isFileURL, url.lastPathComponent.utf8.count <= 512 else {
          throw WhatsAppAttachmentSelectionFailure.file
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink == false,
          let count = values.fileSize
        else {
          throw WhatsAppAttachmentSelectionFailure.file
        }
        let size = Int64(count)
        guard (0...100 * 1024 * 1024).contains(size) else {
          throw WhatsAppAttachmentSelectionFailure.size
        }
        total += size
        guard total <= 1000 * 1024 * 1024 else { throw WhatsAppAttachmentSelectionFailure.size }
        let type = UTType(filenameExtension: url.pathExtension)
        let kind: String
        if asFiles {
          kind = "document"
        } else if type?.conforms(to: .image) == true {
          kind = url.pathExtension.lowercased() == "webp" ? "sticker" : "image"
        } else if type?.conforms(to: .movie) == true {
          kind = "video"
        } else if type?.conforms(to: .audio) == true {
          kind = "audio"
        } else {
          kind = "document"
        }
        return .init(
          file: url, kind: kind, mime: type?.preferredMIMEType ?? "application/octet-stream",
          size: size)
      }
    }
  }
}
