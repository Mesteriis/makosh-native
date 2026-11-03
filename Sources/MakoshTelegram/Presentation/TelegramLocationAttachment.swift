import Foundation
import TelegramCore

/// A received location snapshot. Projection never requests device location or map tiles.
public struct TelegramLocationAttachment: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let title: String
    public let address: String?
    public let isLive: Bool
    public var coordinates: String { "\(latitude), \(longitude)" }
    public var mapsURL: URL? {
        var parts = URLComponents()
        parts.scheme = "maps"
        parts.host = ""
        parts.queryItems = [URLQueryItem(name: "ll", value: "\(latitude),\(longitude)")]
        return parts.url
    }
    // This existing encrypted archive field also retains the received coordinates
    // when the source message disappears. It is never a filename/cache path.
    let archiveDescription: String

    init?(_ map: TelegramMediaMap) {
        guard map.latitude.isFinite, map.longitude.isFinite,
              (-90...90).contains(map.latitude), (-180...180).contains(map.longitude) else { return nil }
        latitude = map.latitude; longitude = map.longitude
        func label(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard value.utf8.count > 2048 else { return value }
            var bytes = Array(value.utf8.prefix(2045))
            while let _ = bytes.last {
                if let prefix = String(bytes: bytes, encoding: .utf8) { return prefix + "…" }
                bytes.removeLast()
            }
            return "…"
        }
        title = label(map.venue?.title) ?? "Геопозиция"
        address = label(map.venue?.address)
        isLive = map.liveBroadcastingTimeout != nil
        // UI labels have a byte budget. Archival metadata retains the original
        // received strings; the existing journal/observation size gates fail
        // visibly and leave capture unacknowledged if an event exceeds bounds.
        var fields = ["Геопозиция", "\(map.latitude), \(map.longitude)"]
        if let venue = map.venue {
            fields.append("Место: \(venue.title)")
            for (label, value) in [("Адрес", venue.address), ("Поставщик", venue.provider), ("Место ID", venue.id), ("Тип места", venue.type)] {
                if let value { fields.append("\(label): \(value)") }
            }
        }
        if let address = map.address {
            for (label, value) in [("Страна", Optional(address.country)), ("Регион", address.state), ("Город", address.city), ("Улица", address.street)] {
                if let value { fields.append("\(label): \(value)") }
            }
        }
        if let heading = map.heading { fields.append("Направление: \(heading)°") }
        if let accuracy = map.accuracyRadius, accuracy.isFinite { fields.append("Точность: \(accuracy) м") }
        if let timeout = map.liveBroadcastingTimeout { fields.append("Трансляция: \(timeout) с") }
        if let radius = map.liveProximityNotificationRadius { fields.append("Радиус уведомлений: \(radius) м") }
        archiveDescription = fields.joined(separator: " · ")
    }
}
