import Foundation

/// What a write changes. Rating is always written; the label is written, removed or left as it is.
public struct SidecarEdit: Sendable, Hashable {
    public enum LabelChange: Sendable, Hashable {
        /// Leave `xmp:Label` exactly as it is (an unknown label such as Lightroom's "Select", M-07/Q2).
        case keep
        case set(String)
        case remove
    }

    public var rating: Int
    public var label: LabelChange

    public init(rating: Int, label: LabelChange) {
        self.rating = min(max(rating, -1), 5)
        self.label = label
    }
}

public struct XMPPatchError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Changes `xmp:Rating`, `xmp:Label` and `xmp:MetadataDate` inside an XMP packet and keeps every other byte.
///
/// A toolkit would re-serialize the whole packet. This scans the bytes once, records where each start tag,
/// attribute value and element body sits, and then replaces, removes or inserts only those spans.
public enum XMPPatcher {
    static let xmpNamespace = "http://ns.adobe.com/xap/1.0/"
    static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    /// A minimal packet for a photo's first decision: one `rdf:Description` declaring the XMP namespace.
    public static let template = Data("""
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>

        """.utf8)

    /// `existing` is the file's current bytes, or nil to start from the template. Throws when the bytes are not
    /// an XMP packet this can patch safely; the caller then leaves the file alone.
    public static func patch(_ existing: Data?, edit: SidecarEdit, date: Date) throws -> Data {
        let bytes = [UInt8](existing ?? template)
        let doc = try Scanner(bytes).scan()
        var wanted: [(name: String, value: String?)] = [("Rating", String(edit.rating))]
        switch edit.label {
        case .keep: break
        case .set(let name): wanted.append(("Label", name))
        case .remove: wanted.append(("Label", nil))
        }
        wanted.append(("MetadataDate", metadataDate(date)))

        var edits: [Edit] = []
        var missing: [(name: String, value: String)] = []
        for (name, value) in wanted {
            var found = false
            for element in doc.elements where element.isRDFDescription {
                for attr in element.attributes where doc.isXMP(attr.name, in: element) == name {
                    found = true
                    if let value { edits.append(Edit(range: attr.value, text: escape(value))) }
                    else { edits.append(Edit(range: attr.span, text: "")) }
                }
            }
            for element in doc.elements where doc.isXMPChild(element) == name {
                found = true
                if let value { edits.append(element.setText(escape(value))) }
                else { edits.append(Edit(range: element.removalSpan(in: bytes), text: "")) }
            }
            if !found, let value { missing.append((name, value)) }
        }
        if !missing.isEmpty { edits.append(try doc.insertion(for: missing, bytes: bytes)) }

        var out = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        }
        return Data(out)
    }

    /// `2026-10-01T20:30:00+02:00`, the form Lightroom writes.
    static func metadataDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter.string(from: date)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    struct Edit {
        var range: Range<Int>
        var text: String
    }

    struct Attribute {
        var name: String
        /// Leading whitespace through the closing quote: what removing the attribute deletes.
        var span: Range<Int>
        /// Between the quotes.
        var value: Range<Int>
    }

    struct Element {
        var name: String
        var parent: Int?
        /// Prefix to namespace URI in force on this element, the default namespace under "".
        var scope: [String: String]
        var attributes: [Attribute] = []
        var open: Range<Int>
        /// Where a new attribute goes: the `>` or `/>` that ends the start tag.
        var insertAt: Int
        var selfClosing: Bool
        var close: Range<Int>?

        var isRDFDescription = false

        func setText(_ text: String) -> Edit {
            if selfClosing {
                let qname = name
                return Edit(range: open, text: "<\(qname)>\(text)</\(qname)>")
            }
            return Edit(range: open.upperBound..<(close?.lowerBound ?? open.upperBound), text: text)
        }

        /// The element, and the indentation before it, so removing it leaves no blank line behind.
        func removalSpan(in bytes: [UInt8]) -> Range<Int> {
            var start = open.lowerBound
            while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
            if start > 0, bytes[start - 1] == 0x0A { start -= 1; if start > 0, bytes[start - 1] == 0x0D { start -= 1 } }
            return start..<(selfClosing ? open.upperBound : (close?.upperBound ?? open.upperBound))
        }
    }

    struct Document {
        var elements: [Element]

        func resolve(_ qname: String, in element: Element, isAttribute: Bool) -> (uri: String?, local: String) {
            let parts = qname.split(separator: ":", maxSplits: 1).map(String.init)
            let (prefix, local) = parts.count == 2 ? (parts[0], parts[1]) : ("", qname)
            if prefix.isEmpty && isAttribute { return (nil, local) }
            return (element.scope[prefix], local)
        }

        /// The local name when `attr` is in the XMP namespace and one of ours.
        func isXMP(_ attr: String, in element: Element) -> String? {
            let (uri, local) = resolve(attr, in: element, isAttribute: true)
            return uri == xmpNamespace ? local : nil
        }

        /// The local name when `element` is a direct child of an `rdf:Description`, in the XMP namespace.
        func isXMPChild(_ element: Element) -> String? {
            guard let parent = element.parent, elements[parent].isRDFDescription else { return nil }
            let (uri, local) = resolve(element.name, in: element, isAttribute: false)
            return uri == xmpNamespace ? local : nil
        }

        /// Adds the missing properties as attributes of the first `rdf:Description` that has the XMP namespace
        /// in scope, declaring it when none has, or as a new `rdf:Description` when the packet has none.
        func insertion(for missing: [(name: String, value: String)], bytes: [UInt8]) throws -> Edit {
            func attributes(_ prefix: String) -> String {
                missing.map { " \(prefix):\($0.name)=\"\(escape($0.value))\"" }.joined()
            }
            for element in elements where element.isRDFDescription {
                if let prefix = element.scope.filter({ !$0.key.isEmpty && $0.value == xmpNamespace }).keys.min() {
                    return Edit(range: element.insertAt..<element.insertAt, text: attributes(prefix))
                }
            }
            if let element = elements.first(where: { $0.isRDFDescription }) {
                var prefix = "xmp", n = 1
                while let bound = element.scope[prefix], bound != xmpNamespace { n += 1; prefix = "xmp\(n)" }
                let declare = " xmlns:\(prefix)=\"\(xmpNamespace)\""
                return Edit(range: element.insertAt..<element.insertAt, text: declare + attributes(prefix))
            }
            guard let rdf = elements.first(where: { resolve($0.name, in: $0, isAttribute: false) == (rdfNamespace, "RDF") }),
                  let close = rdf.close else { throw XMPPatchError(message: "no rdf:RDF element to add a description to") }
            let rdfPrefix = rdf.name.split(separator: ":").dropLast().first.map { $0 + ":" } ?? ""
            let text = "<\(rdfPrefix)Description \(rdfPrefix)about=\"\" xmlns:xmp=\"\(xmpNamespace)\"\(attributes("xmp"))/>\n"
            return Edit(range: close.lowerBound..<close.lowerBound, text: text)
        }
    }

    /// One pass over the bytes. UTF-8 (or ASCII) only: a UTF-16 packet is refused rather than guessed at.
    struct Scanner {
        let b: [UInt8]
        init(_ bytes: [UInt8]) { b = bytes }

        func scan() throws -> Document {
            guard !b.prefix(512).contains(0) else { throw XMPPatchError(message: "not a UTF-8 XMP packet") }
            var elements: [Element] = []
            var stack: [Int] = []
            var i = 0
            while i < b.count {
                guard b[i] == 0x3C else { i += 1; continue }
                if starts(i, "<!--") { i = try find("-->", from: i + 4) + 3 }
                else if starts(i, "<![CDATA[") { i = try find("]]>", from: i + 9) + 3 }
                else if starts(i, "<?") { i = try find("?>", from: i + 2) + 2 }
                else if starts(i, "<!") { throw XMPPatchError(message: "a DOCTYPE in an XMP packet") }
                else if starts(i, "</") {
                    let end = try find(">", from: i)
                    guard let top = stack.popLast() else { throw XMPPatchError(message: "unbalanced end tag") }
                    elements[top].close = i..<(end + 1)
                    i = end + 1
                } else {
                    var (element, next) = try startTag(at: i, parent: stack.last, scope: stack.last.map { elements[$0].scope } ?? [:])
                    let (uri, local) = (element.scope[prefix(of: element.name)], element.name.split(separator: ":").last.map(String.init))
                    element.isRDFDescription = uri == rdfNamespace && local == "Description"
                    elements.append(element)
                    if !element.selfClosing { stack.append(elements.count - 1) }
                    i = next
                }
            }
            guard stack.isEmpty else { throw XMPPatchError(message: "unclosed element") }
            return Document(elements: elements)
        }

        private func prefix(of qname: String) -> String {
            qname.contains(":") ? String(qname.split(separator: ":", maxSplits: 1)[0]) : ""
        }

        private func starts(_ i: Int, _ s: StaticString) -> Bool {
            let n = s.utf8CodeUnitCount
            guard i + n <= b.count else { return false }
            return s.withUTF8Buffer { buf in (0..<n).allSatisfy { b[i + $0] == buf[$0] } }
        }

        private func find(_ s: StaticString, from: Int) throws -> Int {
            var i = from
            while i < b.count { if starts(i, s) { return i }; i += 1 }
            throw XMPPatchError(message: "unterminated markup")
        }

        private func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

        private func startTag(at start: Int, parent: Int?, scope inherited: [String: String]) throws -> (Element, Int) {
            var i = start + 1
            let nameStart = i
            while i < b.count, !isSpace(b[i]), b[i] != 0x2F, b[i] != 0x3E { i += 1 }
            guard i > nameStart, i < b.count else { throw XMPPatchError(message: "bad start tag") }
            let name = String(decoding: b[nameStart..<i], as: UTF8.self)
            var attributes: [Attribute] = []
            var scope = inherited
            while true {
                let wsStart = i
                while i < b.count, isSpace(b[i]) { i += 1 }
                guard i < b.count else { throw XMPPatchError(message: "unterminated start tag") }
                if b[i] == 0x3E || b[i] == 0x2F { break }
                let attrStart = i
                while i < b.count, !isSpace(b[i]), b[i] != 0x3D { i += 1 }
                let attrName = String(decoding: b[attrStart..<i], as: UTF8.self)
                while i < b.count, isSpace(b[i]) { i += 1 }
                guard i < b.count, b[i] == 0x3D else { throw XMPPatchError(message: "attribute without a value") }
                i += 1
                while i < b.count, isSpace(b[i]) { i += 1 }
                guard i < b.count, b[i] == 0x22 || b[i] == 0x27 else { throw XMPPatchError(message: "unquoted attribute") }
                let quote = b[i]
                let valueStart = i + 1
                i = valueStart
                while i < b.count, b[i] != quote { i += 1 }
                guard i < b.count else { throw XMPPatchError(message: "unterminated attribute") }
                attributes.append(Attribute(name: attrName, span: wsStart..<(i + 1), value: valueStart..<i))
                i += 1
                let value = String(decoding: b[valueStart..<(i - 1)], as: UTF8.self)
                if attrName == "xmlns" { scope[""] = value } else if attrName.hasPrefix("xmlns:") { scope[String(attrName.dropFirst(6))] = value }
            }
            let insertAt = i
            let selfClosing = b[i] == 0x2F
            if selfClosing { i += 1 }
            guard i < b.count, b[i] == 0x3E else { throw XMPPatchError(message: "bad start tag end") }
            var element = Element(name: name, parent: parent, scope: scope, open: start..<(i + 1),
                                  insertAt: insertAt, selfClosing: selfClosing)
            element.attributes = attributes
            return (element, i + 1)
        }
    }
}
