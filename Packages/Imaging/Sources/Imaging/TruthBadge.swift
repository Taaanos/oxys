import Foundation

/// What the truth badge says (V-05): which pixels are on screen and whether the zoom stretches them. Pure, so the
/// wording and the warning rules can be tested; the view only draws it.
public struct TruthBadge: Equatable, Sendable {
    public enum Source: Sendable, Equatable {
        /// The embedded preview of a RAW file.
        case preview
        /// A RAW file being developed; the preview is still on screen.
        case developing
        /// The developed RAW.
        case raw
        /// A JPEG, TIFF or similar: the file's own pixels.
        case file
        /// The camera JPEG or HEIC of a RAW+JPEG pair (V-10): the file's own pixels, but not the RAW's.
        case cameraJPEG
        /// A screen-size frame (P-03) is up while the full-size preview loads. Fine at Fit, a stretched picture past it.
        case loadingFullSize
    }

    public var text: String
    /// True when the pixels on screen are not the sensor's, or are stretched past one screen pixel each. The view
    /// draws it with a triangle, so the warning never rests on color.
    public var isWarning: Bool

    /// - Parameters:
    ///   - percent: screen pixels per image pixel of the picture on screen, in percent (100 is 1:1).
    ///   - longEdge: long side of the picture on screen, in pixels.
    ///   - sensorLongEdge: long side of the sensor (EXIF); nil when unknown.
    public static func make(source: Source, percent: Int, isFit: Bool, longEdge: Int?, sensorLongEdge: Int?) -> TruthBadge {
        let enlarged = percent > 100
        let factor = Self.factor(percent)
        switch source {
        case .developing:
            return TruthBadge(text: "Developing", isWarning: true)
        case .loadingFullSize:
            // At Fit the screen-size frame has a pixel for every pixel of the screen, as the full one would.
            if isFit { return make(source: .preview, percent: percent, isFit: isFit, longEdge: longEdge, sensorLongEdge: sensorLongEdge) }
            return TruthBadge(text: "Loading full size", isWarning: true)
        case .raw:
            if enlarged { return TruthBadge(text: "RAW enlarged \(factor)", isWarning: false) }
            return TruthBadge(text: percent == 100 && !isFit ? "RAW 1:1" : "RAW", isWarning: false)
        case .file:
            if enlarged { return TruthBadge(text: "Enlarged \(factor)", isWarning: true) }
            return TruthBadge(text: percent == 100 && !isFit ? "1:1" : "Full file", isWarning: false)
        case .cameraJPEG:
            if enlarged { return TruthBadge(text: "Camera JPEG enlarged \(factor)", isWarning: true) }
            return TruthBadge(text: percent == 100 && !isFit ? "Camera JPEG 1:1" : "Camera JPEG", isWarning: false)
        case .preview:
            if enlarged { return TruthBadge(text: "Preview enlarged \(factor)", isWarning: true) }
            // At 1:1 a preview is still not the sensor unless it has the sensor's pixel count.
            if percent == 100, !isFit, longEdge.map({ l in sensorLongEdge.map { l < $0 } ?? true }) ?? true {
                return TruthBadge(text: "Preview 1:1, not sensor pixels", isWarning: true)
            }
            return TruthBadge(text: longEdge.map { "Preview \($0) px" } ?? "Preview", isWarning: false)
        }
    }

    /// "2.4×", one decimal, no trailing ".0".
    static func factor(_ percent: Int) -> String {
        let value = (Double(percent) / 10).rounded() / 10
        return (value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)) + "×"
    }
}

extension TruthBadge {
    /// What VoiceOver hears for the badge.
    public var spoken: String { isWarning ? "warning, \(text)" : text }
}
