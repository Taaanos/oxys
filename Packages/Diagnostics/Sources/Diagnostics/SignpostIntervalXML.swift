import Foundation

/// One finished signpost interval from an Instruments export.
public struct SignpostInterval: Sendable, Equatable {
    public var name: String
    public var subsystem: String
    public var durationNanoseconds: Int
    public var durationMilliseconds: Double { Double(durationNanoseconds) / 1_000_000 }
}

/// Parses `xctrace export` output for the `OSSignpostIntervals` table.
///
/// The export de-duplicates repeated values: the first occurrence of a `<signpost-name>` or `<subsystem>`
/// element carries an `id` and its text, later ones are empty elements with `ref="<id>"`. Both forms are resolved.
public final class SignpostIntervalXML: NSObject, XMLParserDelegate {
    public static func parse(_ data: Data) throws -> [SignpostInterval] {
        let me = SignpostIntervalXML()
        let parser = XMLParser(data: data)
        parser.delegate = me
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        return me.intervals
    }

    private var intervals: [SignpostInterval] = []
    private var table: [String: String] = [:]          // id → text, for the two de-duplicated elements
    private var inRow = false
    private var current: String?                        // element whose text we are collecting
    private var currentID: String?
    private var text = ""
    private var name: String?, subsystem: String?, duration: Int?

    public func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                       qualifiedName: String?, attributes attrs: [String: String]) {
        switch element {
        case "row":
            inRow = true; name = nil; subsystem = nil; duration = nil
        case "signpost-name", "subsystem", "duration":
            guard inRow else { return }
            if let ref = attrs["ref"] {
                resolve(element, table[ref])
            } else {
                current = element; currentID = attrs["id"]; text = ""
            }
        default: break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    public func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == current {
            if let id = currentID { table[id] = text }
            resolve(element, text)
            current = nil; currentID = nil
        } else if element == "row" {
            if inRow, let name, let subsystem, let duration {
                intervals.append(SignpostInterval(name: name, subsystem: subsystem, durationNanoseconds: duration))
            }
            inRow = false
        }
    }

    private func resolve(_ element: String, _ value: String?) {
        guard let value else { return }
        switch element {
        case "signpost-name": name = value
        case "subsystem": subsystem = value
        default: duration = Int(value)
        }
    }
}

public extension [SignpostInterval] {
    /// Durations in milliseconds per interval name, for one subsystem.
    func durations(subsystem: String) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        for i in self where i.subsystem == subsystem { out[i.name, default: []].append(i.durationMilliseconds) }
        return out
    }
}
