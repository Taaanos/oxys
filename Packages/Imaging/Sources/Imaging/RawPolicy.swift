import Foundation

/// When a RAW is developed (V-03). The setting says whether the app ever develops; `⇧R` lifts On demand to
/// Always for the session only.
public enum RawMode: String, Sendable, CaseIterable {
    case never, onDemand, always

    public static let `default` = RawMode.onDemand

    public var title: String {
        switch self {
        case .never: "Never"
        case .onDemand: "On demand"
        case .always: "Always"
        }
    }
}

/// The decisions of V-03, kept apart from the views so they can be tested.
public enum RawPolicy {
    /// `R` and `⇧R` work in every mode except Never (V-03/Q1).
    public static func allowsDevelop(_ mode: RawMode) -> Bool { mode != .never }

    /// The mode in force: `⇧R` makes a session Always, unless the setting is Never.
    public static func effective(setting: RawMode, sessionAlways: Bool) -> RawMode {
        setting == .never ? .never : (sessionAlways ? .always : setting)
    }

    /// `⇧R`: Always, and back to On demand. Nil when the setting is Never, where it does nothing.
    public static func toggledSession(setting: RawMode, sessionAlways: Bool) -> Bool? {
        allowsDevelop(setting) ? !sessionAlways : nil
    }

    /// Zooming to 1:1 develops the RAW when the preview has fewer pixels than the sensor. A sensor size that is
    /// not known counts as "more": an honest check is worth one decode. `percent` is of the preview's pixels.
    public static func developsAtActualSize(mode: RawMode, automatic: Bool, isRaw: Bool, isFit: Bool, percent: Int,
                                            previewLongEdge: Int?, sensorLongEdge: Int?) -> Bool {
        guard automatic, allowsDevelop(mode), isRaw, !isFit, percent >= 100 else { return false }
        guard let preview = previewLongEdge, let sensor = sensorLongEdge else { return true }
        return preview < sensor
    }

    /// The long side of a size written "6000 × 4000" (EXIF dimensions), nil if it is not in that form.
    public static func longEdge(ofDimensions text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: "×").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count == 2 ? parts.max() : nil
    }

    /// The photos that develop in the background in Always mode: one in the direction of travel, then one
    /// behind (V-03/Q2). Indices outside the folder are left out. The RAW cache's own cap has the last word.
    public static func neighbors(of index: Int, count: Int, forward: Bool) -> [Int] {
        let first = forward ? index + 1 : index - 1, second = forward ? index - 1 : index + 1
        return [first, second].filter { $0 >= 0 && $0 < count }
    }
}
