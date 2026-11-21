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

    private enum Field: String {
        case name = "signpost-name"
        case subsystem = "subsystem"
        case duration = "duration"
    }

    private struct Collecting {
        var field: Field
        var id: String?
        var text = ""
    }

    private struct RowState {
        var name: String?
        var subsystem: String?
        var duration: Int?
        var collecting: Collecting?

        mutating func apply(_ field: Field, _ value: String) {
            switch field {
            case .name: name = value
            case .subsystem: subsystem = value
            case .duration: duration = Int(value)
            }
        }
    }

    private enum ParseState {
        case outsideRow
        case inRow(RowState)
    }

    private var intervals: [SignpostInterval] = []
    private var table: [String: String] = [:]          // id → text, for the two de-duplicated elements
    private var state: ParseState = .outsideRow

    public func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                       qualifiedName: String?, attributes attrs: [String: String]) {
        if element == "row" {
            state = .inRow(RowState())
            return
        }
        guard case .inRow(var row) = state, let field = Field(rawValue: element) else { return }
        if let ref = attrs["ref"] {
            if let value = table[ref] { row.apply(field, value) }
        } else {
            row.collecting = Collecting(field: field, id: attrs["id"])
        }
        state = .inRow(row)
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard case .inRow(var row) = state, var collecting = row.collecting else { return }
        collecting.text += string
        row.collecting = collecting
        state = .inRow(row)
    }

    public func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard case .inRow(var row) = state else { return }
        if element == "row" {
            if let name = row.name, let subsystem = row.subsystem, let duration = row.duration {
                intervals.append(SignpostInterval(name: name, subsystem: subsystem, durationNanoseconds: duration))
            }
            state = .outsideRow
        } else if let collecting = row.collecting, collecting.field.rawValue == element {
            if let id = collecting.id { table[id] = collecting.text }
            row.apply(collecting.field, collecting.text)
            row.collecting = nil
            state = .inRow(row)
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
