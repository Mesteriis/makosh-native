import Foundation

public enum TelegramUploadSourceClassifier {
    public static func options(for facts: [TelegramUploadSourceFacts]) -> [TelegramUploadPresentation] {
        guard facts.allSatisfy(\.isValid) else { return [.file] }
        var result: [TelegramUploadPresentation] = []
        for source in facts {
            let mime = source.selectionMIME
            if mime.hasPrefix("image") {
                guard case let .decoded(width, height) = source.image,
                      width >= 40, height >= 40, width / 10 <= height, height / 10 <= width else { continue }
            }
            let contribution: TelegramUploadPresentation = mime.hasPrefix("image") || mime.hasSuffix("gif") ||
                mime.hasPrefix("video/mp4") || mime.hasPrefix("video/mov") || mime.hasSuffix("m4v") ? .media : .file
            if !result.contains(contribution) { result.append(contribution) }
            if mime == "image/webp" { result.removeAll { $0 == .media } }
        }
        return result.isEmpty ? [.file] : result
    }

    public static func initialPresentation(for facts: [TelegramUploadSourceFacts], asMedia: Bool) -> TelegramUploadPresentation {
        asMedia && options(for: facts) == [.media] ? .media : .file
    }

    public static func allowsGrouping(for facts: [TelegramUploadSourceFacts], presentation: TelegramUploadPresentation) -> Bool {
        guard presentation != .archive, !facts.isEmpty, facts.allSatisfy(\.isValid),
              !facts.contains(where: { $0.selectionMIME == "image/webp" }),
              presentation != .media || options(for: facts) == [.media] else { return false }
        if facts.contains(where: { $0.grouping == .music }) { return facts.allSatisfy { $0.grouping == .music } }
        return !facts.contains { $0.grouping == .voice || $0.grouping == .animated }
    }
}
