import Foundation

/// A minimal namespace-aware XML tree for WebDAV multistatus replies.
/// External entities are never resolved.
final class DAVNode {
    let namespace: String
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [DAVNode] = []

    init(namespace: String, name: String, attributes: [String: String]) {
        self.namespace = namespace
        self.name = name
        self.attributes = attributes
    }

    static let dav = "DAV:", carddav = "urn:ietf:params:xml:ns:carddav"

    func child(_ name: String, _ namespace: String = dav) -> DAVNode? { children.first { $0.name == name && $0.namespace == namespace } }
    func all(_ name: String, _ namespace: String = dav) -> [DAVNode] { children.filter { $0.name == name && $0.namespace == namespace } }
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func parse(_ data: Data) throws -> DAVNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { throw PersonsFailure.invalidInput("dav xml") }
        return root
    }

    /// One `<response>` of a multistatus: its href and the props of its 200 propstats.
    struct Response {
        let href: String
        let props: DAVNode
        let status: String?
    }

    static func responses(_ data: Data) throws -> [Response] {
        try parse(data).all("response").map { response in
            let merged = DAVNode(namespace: dav, name: "prop", attributes: [:])
            for propstat in response.all("propstat") where propstat.child("status")?.trimmed.contains(" 200 ") ?? true {
                merged.children += propstat.child("prop")?.children ?? []
            }
            return Response(href: response.child("href")?.trimmed ?? "", props: merged, status: response.child("status")?.trimmed)
        }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: DAVNode?
        var stack: [DAVNode] = []
        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            let node = DAVNode(namespace: namespaceURI ?? "", name: elementName, attributes: attributes)
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
    var davEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
