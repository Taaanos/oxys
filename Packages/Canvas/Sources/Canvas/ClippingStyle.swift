import Foundation

/// The two clipping thresholds, in whole percent of the full level range (V-07).
///
/// A pixel is a *highlight* when any channel reaches the highlight level, and a *shadow* when all channels are at or
/// below the shadow level. Levels are compared as 8-bit values, so "98%" means a channel of 250 or more, and "2%" a
/// channel of 5 or less. Whole percents only: the field in the popover steps by 1%.
public struct ClippingThresholds: Equatable, Sendable {
    public static let defaultHighlight = 98
    public static let defaultShadow = 2
    /// Highlight 50...100, shadow 0...50: the two can never cross.
    public static let highlightRange = 50...100
    public static let shadowRange = 0...50

    public private(set) var highlight: Int
    public private(set) var shadow: Int

    public init(highlight: Int = defaultHighlight, shadow: Int = defaultShadow) {
        self.highlight = min(max(highlight, Self.highlightRange.lowerBound), Self.highlightRange.upperBound)
        self.shadow = min(max(shadow, Self.shadowRange.lowerBound), Self.shadowRange.upperBound)
    }

    /// The lowest 8-bit value that counts as a highlight.
    public var highlightByte: Int { Int((Double(highlight) * 255 / 100 - 1e-6).rounded(.up)) }
    /// The highest 8-bit value that counts as a shadow.
    public var shadowByte: Int { Int((Double(shadow) * 255 / 100 + 1e-6).rounded(.down)) }
}

/// Which clipping overlays are drawn.
public struct ClippingMarks: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let highlights = ClippingMarks(rawValue: 1)
    public static let shadows = ClippingMarks(rawValue: 2)
}

/// What the overlay looks like and which marks it draws. `nil` where a `ClippingStyle?` is taken means off.
public struct ClippingStyle: Equatable, Sendable {
    public var marks: ClippingMarks
    public var thresholds: ClippingThresholds
    /// Diagonal stripes instead of solid color, for people who cannot tell red from blue. The two directions differ.
    public var pattern: Bool

    public init(marks: ClippingMarks, thresholds: ClippingThresholds = ClippingThresholds(), pattern: Bool = false) {
        self.marks = marks
        self.thresholds = thresholds
        self.pattern = pattern
    }
}

/// How much of the whole frame is clipped, counted on source pixels.
public struct ClippingStats: Equatable, Sendable {
    public let highlightPixels: Int
    public let shadowPixels: Int
    public let totalPixels: Int

    public init(highlightPixels: Int, shadowPixels: Int, totalPixels: Int) {
        self.highlightPixels = highlightPixels
        self.shadowPixels = shadowPixels
        self.totalPixels = totalPixels
    }

    /// 0...100.
    public var highlightPercent: Double { totalPixels > 0 ? Double(highlightPixels) * 100 / Double(totalPixels) : 0 }
    public var shadowPercent: Double { totalPixels > 0 ? Double(shadowPixels) * 100 / Double(totalPixels) : 0 }

    /// "0.4%", "12%", "<0.1%" for a few pixels, "0%" for none. One decimal under 10%.
    public static func text(forPercent percent: Double, pixels: Int) -> String {
        if pixels == 0 { return "0%" }
        if percent < 0.05 { return "<0.1%" }
        if percent < 10 { return String(format: "%.1f%%", percent) }
        return String(format: "%.0f%%", percent)
    }

    public var highlightText: String { Self.text(forPercent: highlightPercent, pixels: highlightPixels) }
    public var shadowText: String { Self.text(forPercent: shadowPercent, pixels: shadowPixels) }
}
