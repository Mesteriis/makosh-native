import Foundation
import MakoshCore

/// Turns the graph of a person's sketch into proposed dossier observations. Pure: only nodes
/// linked by an edge to one of the run's input nodes count, values are deduplicated against the
/// dossier, identifiers that have no place in a dossier (device ids, IPs) are left on the server.
public enum OSINTGraphMapping {
    public static let service = "osint"

    public static func identity(serverID: UUID, sketchID: String) -> ServiceIdentity {
        ServiceIdentity(service: service, accountID: serverID.uuidString, externalID: sketchID)
    }

    public static func observations(
        graph: FlowsintGraph, inputNodeIDs: Set<String>, sketchID: String, serverID: UUID, person: Person, now: Date, limit: Int = 200
    ) -> (observations: [Observation], truncated: Bool) {
        let nodes = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var neighborIDs: [String] = []
        var seenIDs = Set<String>()
        for edge in graph.edges {
            let other: String?
            if inputNodeIDs.contains(edge.source), !inputNodeIDs.contains(edge.target) {
                other = edge.target
            } else if inputNodeIDs.contains(edge.target), !inputNodeIDs.contains(edge.source) {
                other = edge.source
            } else {
                other = nil
            }
            if let other, seenIDs.insert(other).inserted { neighborIDs.append(other) }
        }

        var known = Set<String>()
        for field in PersonListField.allCases where field != .tags {
            for value in person.values(field) { known.insert(key(field.rawValue, value)) }
        }
        for observation in person.observations { known.insert(key(observation.field, observation.value)) }

        var candidates: [(field: String, value: String, enricher: String?)] = []
        // Input phones carry what the phone enrichers wrote onto the node itself.
        for id in inputNodeIDs.sorted() {
            guard let node = nodes[id], FlowsintNodeType(wireType: node.type) == .phone, let number = node.primaryValue else { continue }
            let parts = ["country", "carrier", "line_type"].compactMap { node.properties[$0]?.stringValue }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { continue }
            candidates.append(("phone.info", "\(displayPhone(number)) — \(parts.joined(separator: ", "))", enricher(node)))
        }
        for id in neighborIDs {
            guard let node = nodes[id], let type = FlowsintNodeType(wireType: node.type), let primary = node.primaryValue else { continue }
            let enricherName = enricher(node)
            switch type {
            case .email: candidates.append(("emails", PersonMatching.normalizedEmail(primary), enricherName))
            case .phone: candidates.append(("phones", displayPhone(primary), enricherName))
            case .username: candidates.append(("usernames", primary, enricherName))
            case .socialAccount:
                let platform = (node.properties["platform"]?.stringValue ?? "unknown").lowercased()
                let handle: String
                if let url = node.properties["profile_url"]?.stringValue, !url.isEmpty {
                    handle = url
                } else {
                    let username: String
                    if case .object(let object)? = node.properties["username"], let value = object["value"]?.stringValue {
                        username = value
                    } else {
                        username = node.properties["username"]?.stringValue ?? primary
                    }
                    handle = "\(platform):\(username)"
                }
                candidates.append(("social.\(platform)", handle, enricherName))
            case .gravatar:
                guard node.properties["exists"] != .bool(false), let src = node.properties["src"]?.stringValue else { continue }
                candidates.append(("avatar", src, enricherName))
            case .breach:
                let title = node.properties["title"]?.stringValue ?? primary
                let date = node.properties["breachdate"]?.stringValue
                candidates.append(("breach", date.map { "\(title), \($0)" } ?? title, enricherName))
            case .device:
                let parts = ["os", "last_seen"].compactMap { node.properties[$0]?.stringValue }.filter { !$0.isEmpty }
                guard !parts.isEmpty else { continue }
                candidates.append(("leak.device", parts.joined(separator: ", "), enricherName))
            case .domain: candidates.append(("domain", primary.lowercased(), enricherName))
            case .organization: candidates.append(("organization.suggested", primary, enricherName))
            case .ip: candidates.append(("domain.ip", primary, enricherName))
            case .whois:
                var parts = [node.properties["registrar"]?.stringValue]
                if case .object(let organization)? = node.properties["organization"] { parts.append(organization["name"]?.stringValue) }
                parts += [node.properties["country"]?.stringValue, node.properties["creation_date"]?.stringValue]
                let details = parts.compactMap { $0 }.filter { !$0.isEmpty }
                candidates.append(
                    ("domain.whois", details.isEmpty ? primary : "\(primary): \(details.joined(separator: ", "))", enricherName))
            case .asn:
                var label = primary
                if case .number(let number)? = node.properties["number"] { label = "AS\(Int(number))" }
                if let name = node.properties["name"]?.stringValue, !name.isEmpty { label += " \(name)" }
                if let country = node.properties["country"]?.stringValue, !country.isEmpty { label += " (\(country))" }
                candidates.append(("organization.asn", label, enricherName))
            case .individual:
                // A DeHashed record: contacts the leak lists, and what it says about the person. Never passwords.
                for email in strings(node.properties["email_addresses"]) {
                    candidates.append(("emails", PersonMatching.normalizedEmail(email), enricherName))
                }
                for phone in strings(node.properties["phone_numbers"]) { candidates.append(("phones", displayPhone(phone), enricherName)) }
                for username in strings(node.properties["usernames"]) { candidates.append(("usernames", username, enricherName)) }
                if let name = node.properties["full_name"]?.stringValue, !name.isEmpty {
                    candidates.append(("leak.name", name, enricherName))
                }
                if let birth = node.properties["birth_date"]?.stringValue, !birth.isEmpty {
                    candidates.append(("leak.birthdate", birth, enricherName))
                }
                for ip in strings(node.properties["ip_addresses"]) { candidates.append(("leak.ip", ip, enricherName)) }
                for profile in strings(node.properties["social_media_profiles"]) {
                    candidates.append(("leak.social", profile, enricherName))
                }
            }
        }

        var result: [Observation] = []
        var truncated = false
        for candidate in candidates {
            guard !candidate.value.isEmpty, known.insert(key(candidate.field, candidate.value)).inserted else { continue }
            if result.count >= limit {
                truncated = true
                break
            }
            var identity = identity(serverID: serverID, sketchID: sketchID)
            if let enricher = candidate.enricher { identity.externalID += "/\(enricher)" }
            result.append(
                Observation(
                    field: candidate.field, value: candidate.value, source: SourceStamp(identity: identity, fetchedAt: now),
                    status: .proposed))
        }
        return (result, truncated)
    }

    /// The dossier form of a number: the normalized digits in international notation.
    /// A list property as strings: an array, or one string.
    private static func strings(_ value: JSONValue?) -> [String] {
        switch value {
        case .array(let items)?: items.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case .string(let text)?: text.isEmpty ? [] : [text]
        default: []
        }
    }

    private static func displayPhone(_ value: String) -> String {
        let digits = PersonMatching.normalizedPhone(value)
        return digits.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : "+" + digits
    }

    private static func enricher(_ node: FlowsintNode) -> String? {
        node.metadata["enricher"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Dedup key: list fields compare normalized, everything else exact.
    private static func key(_ field: String, _ value: String) -> String {
        switch field {
        case "emails": "emails|" + PersonMatching.normalizedEmail(value)
        case "phones": "phones|" + PersonMatching.normalizedPhone(value)
        case "usernames": "usernames|" + value.lowercased()
        default: field + "|" + value
        }
    }
}
