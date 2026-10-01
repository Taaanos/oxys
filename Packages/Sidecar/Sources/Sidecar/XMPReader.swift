import Foundation

/// The two properties Oxys cares about, as found in a sidecar. Anything else in the file is ignored.
public struct XMPProperties: Sendable, Hashable {
    /// `xmp:Rating`, -1 to 5. Nil when absent or not a whole number.
    public var rating: Int?
    /// `xmp:Label` exactly as written (matching is case-sensitive, F-04). Nil when absent or empty.
    public var label: String?

    public init(rating: Int? = nil, label: String? = nil) {
        self.rating = rating
        self.label = label
    }
}

public struct XMPParseError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// A namespace-aware read of `xmp:Rating` and `xmp:Label`. Matches by namespace URI, so the `xap:` prefix of
/// older Adobe files and any other prefix work. Handles attributes and child elements, any number of
/// `rdf:Description` blocks, and files with or without the `<?xpacket?>` wrapper.
public enum XMPReader {
    public static let xmpNamespaces: Set<String> = ["http://ns.adobe.com/xap/1.0/"]
    static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    public static func parse(_ data: Data) throws -> XMPProperties {
        let collector = Collector()
        let parser = XMLParser(data: data)
        // Namespaces are resolved by hand: with `shouldProcessNamespaces` the parser reports attributes by
        // qualified name only and gives no prefix bindings, so attribute namespaces could not be checked.
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse(), collector.sawRDF else {
            let reason = parser.parserError?.localizedDescription ?? "no rdf:RDF element"
            throw XMPParseError(message: reason)
        }
        return collector.properties
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var properties = XMPProperties()
        var sawRDF = false
        /// One prefix-to-URI scope per open element; the default namespace has the empty prefix.
        private var scopes: [[String: String]] = []
        /// Set while inside a child element `<xmp:Rating>` or `<xmp:Label>`; its text accumulates here.
        private var capturing: (depth: Int, name: String, text: String)?

        private func resolve(_ qualified: String, isAttribute: Bool) -> (uri: String?, local: String) {
            let parts = qualified.split(separator: ":", maxSplits: 1).map(String.init)
            let (prefix, local) = parts.count == 2 ? (parts[0], parts[1]) : ("", qualified)
            // An unprefixed attribute has no namespace; an unprefixed element takes the default one.
            if prefix.isEmpty && isAttribute { return (nil, local) }
            for scope in scopes.reversed() { if let uri = scope[prefix] { return (uri, local) } }
            return (nil, local)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            var scope: [String: String] = [:]
            for (key, value) in attributes {
                if key == "xmlns" { scope[""] = value } else if key.hasPrefix("xmlns:") { scope[String(key.dropFirst(6))] = value }
            }
            scopes.append(scope)
            let (uri, local) = resolve(elementName, isAttribute: false)
            if uri == XMPReader.rdfNamespace {
                if local == "RDF" { sawRDF = true }
                if local == "Description" {
                    for (key, value) in attributes where !key.hasPrefix("xmlns") {
                        let (attrURI, attrLocal) = resolve(key, isAttribute: true)
                        if let attrURI, XMPReader.xmpNamespaces.contains(attrURI) { set(attrLocal, value) }
                    }
                }
            } else if let uri, XMPReader.xmpNamespaces.contains(uri), local == "Rating" || local == "Label" {
                capturing = (scopes.count, local, "")
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            capturing?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if let capture = capturing, capture.depth == scopes.count {
                set(capture.name, capture.text)
                capturing = nil
            }
            scopes.removeLast()
        }

        private func set(_ name: String, _ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "Rating":
                if let n = Int(value) { properties.rating = min(max(n, -1), 5) }
            case "Label":
                properties.label = value.isEmpty ? nil : value
            default: break
            }
        }
    }
}
