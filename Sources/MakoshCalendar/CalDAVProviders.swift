import Foundation

/// Known CalDAV servers for a mail account; Gmail goes through Google sign-in instead.
public enum CalDAVProviders {
    public static func suggestion(email: String, imapHost: String?) -> URL? {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        let host = imapHost?.lowercased() ?? ""
        func matches(_ domains: [String], _ hosts: [String]) -> Bool {
            domains.contains(domain) || hosts.contains { host == $0 || host.hasSuffix("." + $0) || host.hasPrefix($0) }
        }
        if ["gmail.com", "googlemail.com"].contains(domain) { return nil }
        if matches(["yandex.ru", "ya.ru", "yandex.com", "yandex.by", "yandex.kz", "narod.ru"], ["imap.yandex."]) {
            return URL(string: "https://caldav.yandex.ru")
        }
        if matches(["icloud.com", "me.com", "mac.com"], ["imap.mail.me.com"]) { return URL(string: "https://caldav.icloud.com") }
        if domain.hasPrefix("fastmail.") || host.hasSuffix("fastmail.com") { return URL(string: "https://caldav.fastmail.com") }
        return nil
    }
}
