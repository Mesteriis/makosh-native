import Foundation
import MakoshCore

/// An address book found at a CardDAV server.
public struct RemoteAddressBook: Equatable, Sendable {
    public var url: URL
    public var name: String
    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

/// RFC 6352 CardDAV with Basic authentication over HTTPS only (Yandex, iCloud, Fastmail…).
public actor CardDAVAdapter: PersonBookAdapter {
    let collection: URL
    let login: String
    let password: String
    let http: PersonsHTTP

    /// Where reading stopped: a server sync token, or the ETags of every card.
    enum Cursor: Codable {
        case token(String)
        case etags([String: String])
        init?(data: Data?) {
            guard let data, let value = try? JSONDecoder().decode(Cursor.self, from: data) else { return nil }
            self = value
        }
        var data: Data? { try? JSONEncoder().encode(self) }
    }

    public init(collection: URL, login: String, password: String, http: PersonsHTTP) {
        self.collection = collection
        self.login = login
        self.password = password
        self.http = http
    }

    public var capabilities: PersonBookCapabilities {
        PersonBookCapabilities(acceptsOrganizations: true, requiresPhoneOrPeer: false, supportsMarker: true)
    }

    // MARK: Requests

    static func authorization(_ login: String, _ password: String) -> String {
        "Basic " + Data((login + ":" + password).utf8).base64EncodedString()
    }

    static func dav(
        _ url: URL, method: String, depth: String? = nil, body: String? = nil, login: String, password: String,
        headers: [String: String] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization(login, password), forHTTPHeaderField: "Authorization")
        if let depth { request.setValue(depth, forHTTPHeaderField: "Depth") }
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    static let namespaces = #"xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav""#

    static func propfind(_ props: String) -> String {
        #"<?xml version="1.0" encoding="utf-8"?><d:propfind "# + namespaces + "><d:prop>" + props + "</d:prop></d:propfind>"
    }

    func request(_ url: URL, method: String, depth: String? = nil, body: String? = nil, headers: [String: String] = [:]) -> URLRequest {
        Self.dav(url, method: method, depth: depth, body: body, login: login, password: password, headers: headers)
    }

    // MARK: Discovery

    public static func discover(server: URL, login: String, password: String, http: PersonsHTTP) async throws -> [RemoteAddressBook] {
        guard server.scheme == "https", server.host != nil else { throw PersonsFailure.invalidInput("https required") }
        var principal: URL?
        for candidate in [server.appendingPathComponent(".well-known/carddav"), server] {
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await http.send(
                    dav(
                        candidate, method: "PROPFIND", depth: "0", body: propfind("<d:current-user-principal/>"), login: login,
                        password: password),
                    stage: "discover")
            } catch PersonsFailure.rejected(code: 401, _) {
                throw PersonsFailure.signInRequired
            } catch PersonsFailure.rejected(code: 403, _) {
                throw PersonsFailure.noAccess
            } catch { continue }
            let base = response.url ?? candidate
            if let href = try DAVNode.responses(data).compactMap({ $0.props.child("current-user-principal")?.child("href")?.trimmed })
                .first,
                let url = URL(string: href, relativeTo: base)?.absoluteURL
            {
                principal = url
                break
            }
        }
        guard let principal, principal.host == server.host else { throw PersonsFailure.rejected(code: 404, stage: "discover") }
        let (homeData, _) = try await http.send(
            dav(
                principal, method: "PROPFIND", depth: "0", body: propfind("<card:addressbook-home-set/>"), login: login, password: password),
            stage: "discover")
        guard
            let href = try DAVNode.responses(homeData).compactMap({
                $0.props.child("addressbook-home-set", DAVNode.carddav)?.child("href")?.trimmed
            }).first, let home = URL(string: href, relativeTo: principal)?.absoluteURL, home.host == server.host
        else { throw PersonsFailure.rejected(code: 404, stage: "discover") }
        let (data, _) = try await http.send(
            dav(
                home, method: "PROPFIND", depth: "1", body: propfind("<d:resourcetype/><d:displayname/>"), login: login, password: password),
            stage: "books")
        return try DAVNode.responses(data).compactMap { response in
            guard response.props.child("resourcetype")?.child("addressbook", DAVNode.carddav) != nil,
                let url = URL(string: response.href, relativeTo: home)?.absoluteURL, url.host == server.host
            else { return nil }
            return RemoteAddressBook(url: url, name: response.props.child("displayname")?.trimmed ?? url.lastPathComponent)
        }
    }

    // MARK: Reading

    public func changes(cursor: Data?) async throws -> RemoteCardChanges {
        switch Cursor(data: cursor) {
        case .etags(let previous)?:
            return try await etagDiff(previous: previous, full: false)
        case .token(let token)?:
            do { return try await syncCollection(token: token, full: false) } catch PersonsFailure.rejected(let code, _)
                where [400, 403, 409].contains(code)
            {
                return try await syncCollection(token: "", full: true)
            }
        case nil:
            do { return try await syncCollection(token: "", full: true) } catch PersonsFailure.rejected(let code, _)
                where [400, 403, 405, 409, 501].contains(code)
            {
                return try await etagDiff(previous: [:], full: true)
            }
        }
    }

    private func syncCollection(token: String, full: Bool) async throws -> RemoteCardChanges {
        let body =
            #"<?xml version="1.0" encoding="utf-8"?><d:sync-collection "# + Self.namespaces + "><d:sync-token>" + token.davEscaped
            + "</d:sync-token><d:sync-level>1</d:sync-level><d:prop><d:getetag/><card:address-data/></d:prop></d:sync-collection>"
        let (data, _) = try await http.send(request(collection, method: "REPORT", depth: "1", body: body), stage: "sync")
        let root = try DAVNode.parse(data)
        let newToken = root.child("sync-token")?.trimmed
        var result = RemoteCardChanges(cards: [], cursor: newToken.flatMap { Cursor.token($0).data }, full: full)
        var missing: [URL] = []
        for response in try DAVNode.responses(data) {
            guard let href = URL(string: response.href, relativeTo: collection)?.absoluteURL, href.host == collection.host,
                href != collection
            else { continue }
            if response.status?.contains(" 404 ") == true {
                result.removedExternalIDs.append(href.absoluteString)
                continue
            }
            let etag = response.props.child("getetag")?.trimmed
            if let text = response.props.child("address-data", DAVNode.carddav)?.text, !text.isEmpty {
                append(text, href: href, etag: etag, into: &result)
            } else {
                missing.append(href)
            }
        }
        if !missing.isEmpty { try await multiget(missing, into: &result) }
        return result
    }

    private func etagDiff(previous: [String: String], full: Bool) async throws -> RemoteCardChanges {
        let body =
            #"<?xml version="1.0" encoding="utf-8"?><card:addressbook-query "# + Self.namespaces
            + "><d:prop><d:getetag/></d:prop></card:addressbook-query>"
        let (data, _) = try await http.send(request(collection, method: "REPORT", depth: "1", body: body), stage: "query")
        var current: [String: String] = [:]
        for response in try DAVNode.responses(data) {
            guard let href = URL(string: response.href, relativeTo: collection)?.absoluteURL, href.host == collection.host,
                href != collection,
                let etag = response.props.child("getetag")?.trimmed
            else { continue }
            current[href.absoluteString] = etag
        }
        var result = RemoteCardChanges(cards: [], cursor: Cursor.etags(current).data, full: full)
        result.removedExternalIDs = previous.keys.filter { current[$0] == nil }.sorted()
        let changed = current.filter { previous[$0.key] != $0.value }.keys.sorted().compactMap(URL.init(string:))
        if !changed.isEmpty { try await multiget(changed, into: &result) }
        return result
    }

    private func multiget(_ hrefs: [URL], into result: inout RemoteCardChanges) async throws {
        for chunk in stride(from: 0, to: hrefs.count, by: 100).map({ Array(hrefs[$0..<min($0 + 100, hrefs.count)]) }) {
            let body =
                #"<?xml version="1.0" encoding="utf-8"?><card:addressbook-multiget "# + Self.namespaces
                + "><d:prop><d:getetag/><card:address-data/></d:prop>" + chunk.map { "<d:href>\($0.path.davEscaped)</d:href>" }.joined()
                + "</card:addressbook-multiget>"
            let (data, _) = try await http.send(request(collection, method: "REPORT", depth: "1", body: body), stage: "multiget")
            for response in try DAVNode.responses(data) {
                guard let href = URL(string: response.href, relativeTo: collection)?.absoluteURL, href.host == collection.host,
                    let text = response.props.child("address-data", DAVNode.carddav)?.text, !text.isEmpty
                else { continue }
                append(text, href: href, etag: response.props.child("getetag")?.trimmed, into: &result)
            }
        }
    }

    /// A card that does not parse is skipped: one bad vCard must not stop the book.
    private func append(_ text: String, href: URL, etag: String?, into result: inout RemoteCardChanges) {
        guard let parsed = try? VCard.parse(text) else { return }
        var imported = parsed.imported
        imported.externalID = href.absoluteString
        imported.kind = parsed.kind == .organization ? .organization : nil
        result.cards.append(
            RemoteCard(externalID: href.absoluteString, etag: etag, makoshID: parsed.makoshID, imported: imported, kind: parsed.kind))
    }

    // MARK: Writing

    private func put(_ url: URL, card: PersonCard, etag: String?, create: Bool, stage: String) async throws -> RemoteCardRef {
        var headers = ["Content-Type": "text/vcard; charset=utf-8"]
        if create { headers["If-None-Match"] = "*" } else if let etag { headers["If-Match"] = etag }
        var request = request(url, method: "PUT", headers: headers)
        request.httpBody = Data(VCard.serialize(card).utf8)
        let (_, response) = try await http.send(request, stage: stage)
        return RemoteCardRef(externalID: url.absoluteString, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    public func create(_ card: PersonCard) async throws -> RemoteCardRef {
        let url = collection.appendingPathComponent(card.makoshID.uuidString.lowercased() + ".vcf")
        return try await put(url, card: card, etag: nil, create: true, stage: "create")
    }

    public func update(externalID: String, etag: String?, card: PersonCard) async throws -> RemoteCardRef {
        guard let url = URL(string: externalID), url.host == collection.host else { throw PersonsFailure.invalidInput("href") }
        return try await put(url, card: card, etag: etag, create: false, stage: "update")
    }

    public func delete(externalID: String, etag: String?) async throws {
        guard let url = URL(string: externalID), url.host == collection.host else { throw PersonsFailure.invalidInput("href") }
        do {
            _ = try await http.send(request(url, method: "DELETE", headers: etag.map { ["If-Match": $0] } ?? [:]), stage: "delete")
        } catch PersonsFailure.rejected(code: 404, _) {
            // Already gone.
        }
    }

    public func find(makoshID: UUID) async throws -> RemoteCardRef? {
        let body =
            #"<?xml version="1.0" encoding="utf-8"?><card:addressbook-query "# + Self.namespaces
            + #"><d:prop><d:getetag/><card:address-data/></d:prop><card:filter><card:prop-filter name="X-MAKOSH-PERSON"><card:text-match collation="i;unicode-casemap" match-type="equals">"#
            + makoshID.uuidString.davEscaped + "</card:text-match></card:prop-filter></card:filter></card:addressbook-query>"
        var result = RemoteCardChanges(cards: [], cursor: nil, full: false)
        do {
            let (data, _) = try await http.send(request(collection, method: "REPORT", depth: "1", body: body), stage: "find")
            for response in try DAVNode.responses(data) {
                guard let href = URL(string: response.href, relativeTo: collection)?.absoluteURL, href.host == collection.host,
                    let text = response.props.child("address-data", DAVNode.carddav)?.text, !text.isEmpty
                else { continue }
                append(text, href: href, etag: response.props.child("getetag")?.trimmed, into: &result)
            }
        } catch PersonsFailure.rejected(let code, _) where [400, 403, 501].contains(code) {
            // The server does not filter on custom properties: read the book and look ourselves.
            result = try await changes(cursor: nil)
        }
        return result.cards.first { $0.makoshID == makoshID }.map { RemoteCardRef(externalID: $0.externalID, etag: $0.etag) }
    }
}
