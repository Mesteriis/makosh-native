import Foundation

enum ConnectionSecurity: String, Codable, Sendable { case tls, startTLS, none }
struct MailAccountConfig: Codable, Sendable {
    var id: String; var displayName: String; var email: String
    var imapHost: String; var imapPort: Int; var imapSecurity: ConnectionSecurity; var imapUsername: String
    var smtpHost: String; var smtpPort: Int; var smtpSecurity: ConnectionSecurity; var smtpUsername: String
}
struct ComposeAttachment: Codable, Sendable {
    var filename: String; var mimeType: String; var data: Data
}
struct CalendarEvent: Codable, Sendable {
    var summary: String; var start: Date?; var end: Date?; var location: String?; var organizer: String?; var raw: String
}
