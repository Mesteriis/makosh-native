import Foundation

public struct MailLetterVersion: Identifiable, Sendable {
    public let id: Int64
    public let letter: MailLetter
}
public enum MailTextPagination {
    public static func pages(_ text: String, pageSize: Int = 16000) throws -> [String] {
        guard pageSize > 0, pageSize <= 128000 else { throw MailFailure.invalidInput }
        var pages: [String] = [], start = text.startIndex
        while start < text.endIndex {
            try Task.checkCancellation()
            let end = text.index(start, offsetBy: pageSize, limitedBy: text.endIndex) ?? text.endIndex
            pages.append(String(text[start..<end])); start = end
        }
        return pages.isEmpty ? [""] : pages
    }
}
