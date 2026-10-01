import Foundation
import Sidecar

/// What is known about a photo's sidecar. M-08 writes to `file`, refuses when `problem` is set, and the
/// inspector shows the rest.
public struct SidecarInfo: Sendable, Hashable {
    /// The sidecar read, and the one M-08 patches. Nil when the photo has none.
    public var file: URL?
    /// The other naming style's file when both exist (M-07/Q1). Not read.
    public var alsoPresent: URL?
    /// Set when the sidecar could not be parsed: the decision stays empty and M-08 must not overwrite the file.
    public var problem: String?
    /// A label that is not one of the five names, such as Lightroom's custom "Select" (M-07/Q2). Kept as read;
    /// M-08 leaves it alone until the user sets a new label.
    public var unknownLabel: String?
    /// True when the decision came from XMP inside the image file (JPEG, DNG, TIFF, HEIC), not a sidecar.
    public var isEmbedded = false
    /// True once the sidecar read has finished for this photo, so "no sidecar" can be told from "not read yet".
    public var isRead = false

    public init() {}

    /// Short lines for the info strip until the inspector exists: the problem first, then what is worth knowing.
    public var notes: [String] {
        var lines: [String] = []
        if let problem, let file { lines.append("Can't read \(file.lastPathComponent): \(problem). It won't be overwritten") }
        if let unknownLabel { lines.append("Other label: \(unknownLabel)") }
        if isEmbedded { lines.append("Rating read from the image file") }
        if let alsoPresent { lines.append("Also \(alsoPresent.lastPathComponent), not used") }
        return lines
    }

    /// The decision in `result`, and the sidecar state that goes with it.
    static func resolve(_ result: SidecarReadResult) -> (SidecarInfo, Decision?) {
        var info = SidecarInfo()
        info.isRead = true
        switch result {
        case .none:
            return (info, nil)
        case .malformed(let files, let reason):
            info.file = files.primary
            info.alsoPresent = files.alsoPresent
            info.problem = reason
            return (info, nil)
        case .sidecar(let files, let props):
            info.file = files.primary
            info.alsoPresent = files.alsoPresent
            return (info.withLabel(of: props), Decision(props))
        case .embedded(let props):
            info.isEmbedded = true
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
