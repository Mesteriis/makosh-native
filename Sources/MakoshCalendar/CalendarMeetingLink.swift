import Foundation

/// Finds a meeting link in free text: Telemost first; later providers join here.
public enum CalendarMeetingLink {
    static let telemostHosts: Set<String> = ["telemost.yandex.ru", "telemost.360.yandex.ru"]

    /// The first `https` Telemost link in the text; look-alike hosts are ignored.
    public static func telemost(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url, url.scheme == "https", let host = url.host?.lowercased(), telemostHosts.contains(host) else {
                continue
            }
            return url
        }
        return nil
    }
}
