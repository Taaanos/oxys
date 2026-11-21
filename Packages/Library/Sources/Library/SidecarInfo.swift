import Foundation
import Sidecar

/// What is known about a photo's sidecar. M-08 writes to `file`, refuses when `problem` is set, and the
/// inspector shows the rest.
public struct SidecarInfo: Sendable, Hashable {
    /// Where this photo's XMP state came from. Illegal combinations (e.g. embedded with a sidecar file,
    /// malformed without a file, or a sidecar file while unread) are unrepresentable.
    public enum Source: Sendable, Hashable {
        /// The sidecar read has not finished yet.
        case unread
        /// Read finished: no sidecar and no embedded XMP.
        case none
        /// Read from XMP inside the image file (JPEG, DNG, TIFF, HEIC), not a sidecar.
        case embedded
        /// A readable sidecar file; `alsoPresent` is the other naming style when both exist (M-07/Q1).
        case sidecar(file: URL, alsoPresent: URL? = nil)
        /// A sidecar that could not be parsed or safely patched: M-08 must not overwrite it.
        case malformed(file: URL, alsoPresent: URL? = nil, reason: String)
    }

    public var source: Source = .unread
    /// A label that is not one of the five names, such as Lightroom's custom "Select" (M-07/Q2). Kept as read;
    /// M-08 leaves it alone until the user sets a new label.
    public var unknownLabel: String?
    /// Set when another program changed the sidecar while a decision of ours was still waiting to be written,
    /// and ours replaced it (M-10/Q2). The inspector shows it; cleared by the next outside change.
    public var overwrittenOutsideChange: String?
    /// True while this photo's decision exists only in memory because its sidecar could not be written (M-11).
    public var unsaved = false

    public init(source: Source = .unread) {
        self.source = source
    }

    /// The sidecar read, and the one M-08 patches. Nil when the photo has none.
    public var file: URL? {
        switch source {
        case .sidecar(let file, _), .malformed(let file, _, _): file
        case .unread, .none, .embedded: nil
        }
    }

    /// The other naming style's file when both exist (M-07/Q1). Not read.
    public var alsoPresent: URL? {
        switch source {
        case .sidecar(_, let also), .malformed(_, let also, _): also
        case .unread, .none, .embedded: nil
        }
    }

    /// Set when the sidecar could not be parsed: the decision stays empty and M-08 must not overwrite the file.
    public var problem: String? {
        if case .malformed(_, _, let reason) = source { return reason }
        return nil
    }

    /// True when the decision came from XMP inside the image file (JPEG, DNG, TIFF, HEIC), not a sidecar.
    public var isEmbedded: Bool { source == .embedded }

    /// True once the sidecar read has finished for this photo, so "no sidecar" can be told from "not read yet".
    public var isRead: Bool { source != .unread }

    mutating func markWritten(file url: URL) {
        switch source {
        case .malformed: break
        case .sidecar(_, let also): source = .sidecar(file: url, alsoPresent: also)
        case .unread, .none, .embedded: source = .sidecar(file: url)
        }
    }

    mutating func markRemoved() {
        switch source {
        case .sidecar, .malformed: source = .none
        case .unread, .none, .embedded: break
        }
    }

    mutating func markMalformed(reason: String) {
        switch source {
        case .sidecar(let file, let also), .malformed(let file, let also, _):
            source = .malformed(file: file, alsoPresent: also, reason: reason)
        case .unread, .none, .embedded:
            break
        }
    }

    /// Short lines for the info strip until the inspector exists: the problem first, then what is worth knowing.
    public var notes: [String] {
        var lines: [String] = []
        if case .malformed(let file, _, let problem) = source {
            lines.append("Can't read \(file.lastPathComponent): \(problem). It won't be overwritten")
        }
        if unsaved { lines.insert("Not saved yet: the decision is kept in memory", at: 0) }
        if let overwrittenOutsideChange { lines.append(overwrittenOutsideChange) }
        if let unknownLabel { lines.append("Other label: \(unknownLabel)") }
        if isEmbedded { lines.append("Rating read from the image file") }
        if let alsoPresent { lines.append("Also \(alsoPresent.lastPathComponent), not used") }
        return lines
    }

    /// The decision in `result`, and the sidecar state that goes with it.
    static func resolve(_ result: SidecarReadResult) -> (SidecarInfo, Decision?) {
        switch result {
        case .none:
            return (SidecarInfo(source: .none), nil)
        case .malformed(let files, let reason):
            return (SidecarInfo(source: .malformed(file: files.primary, alsoPresent: files.alsoPresent, reason: reason)), nil)
        case .sidecar(let files, let props):
            let info = SidecarInfo(source: .sidecar(file: files.primary, alsoPresent: files.alsoPresent))
            return (info.withLabel(of: props), Decision(props))
        case .embedded(let props):
            let info = SidecarInfo(source: .embedded)
            return (info.withLabel(of: props), Decision(props))
        }
    }

    private func withLabel(of props: XMPProperties) -> SidecarInfo {
        var info = self
        if let label = props.label, ColorLabel(xmpName: label) == nil { info.unknownLabel = label }
        return info
    }
}

extension ColorLabel {
    /// Labels match exactly and case-sensitively (F-04): `Red` is red, `red` is not.
    init?(xmpName: String) {
        guard let match = ColorLabel.allCases.first(where: { $0.name == xmpName }) else { return nil }
        self = match
    }
}

extension Decision {
    /// No rating means 0 stars; a label that is not one of ours leaves the label empty.
    init(_ props: XMPProperties) {
        self.init(rating: props.rating ?? 0, label: props.label.flatMap(ColorLabel.init(xmpName:)))
    }
}
