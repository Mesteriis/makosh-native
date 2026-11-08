import Foundation

/// A minimal namespace-aware XML tree for WebDAV multistatus replies.
/// External entities are never resolved.
final class CalDAVNode {
    let namespace: String
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [CalDAVNode] = []

    init(namespace: String, name: String, attributes: [String: String]) {
        self.namespace = namespace
        self.name = name
        self.attributes = attributes
    }

    static let dav = "DAV:", caldav = "urn:ietf:params:xml:ns:caldav", apple = "http://apple.com/ns/ical/"

    func child(_ name: String, _ namespace: String = dav) -> CalDAVNode? { children.first { $0.name == name && $0.namespace == namespace } }
    func all(_ name: String, _ namespace: String = dav) -> [CalDAVNode] { children.filter { $0.name == name && $0.namespace == namespace } }
    func descendants(_ name: String, _ namespace: String = dav) -> [CalDAVNode] {
        children.flatMap { ($0.name == name && $0.namespace == namespace ? [$0] : []) + $0.descendants(name, namespace) }
    }
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func parse(_ data: Data) throws -> CalDAVNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { throw CalendarFailure.invalidInput("dav xml") }
        return root
    }

    /// One `<response>` of a multistatus: its href and the props of its 200 propstats.
    struct Response {
        let href: String
        let props: CalDAVNode
        let status: String?
    }

    static func responses(_ data: Data) throws -> [Response] {
        try parse(data).all("response").map { response in
            let merged = CalDAVNode(namespace: dav, name: "prop", attributes: [:])
            for propstat in response.all("propstat") where propstat.child("status")?.trimmed.contains(" 200 ") ?? true {
                merged.children += propstat.child("prop")?.children ?? []
            }
            return Response(href: response.child("href")?.trimmed ?? "", props: merged, status: response.child("status")?.trimmed)
        }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: CalDAVNode?
        var stack: [CalDAVNode] = []
        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            let node = CalDAVNode(namespace: namespaceURI ?? "", name: elementName, attributes: attributes)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
    }
}

extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
