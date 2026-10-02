import Canvas
import Foundation

/// The stored settings for the clipping overlays (V-07), read by Loupe and edited in the `⌥H` popover and in
/// Settings → Analysis. Each is a user default, so a change applies to the open window at once.
enum ClippingSettings {
    static let highlightKey = "clippingHighlight"
    static let shadowKey = "clippingShadow"
    static let patternKey = "clippingPattern"

    static var thresholds: ClippingThresholds {
        let defaults = UserDefaults.standard
        return ClippingThresholds(highlight: defaults.object(forKey: highlightKey) as? Int ?? ClippingThresholds.defaultHighlight,
                                  shadow: defaults.object(forKey: shadowKey) as? Int ?? ClippingThresholds.defaultShadow)
    }

    static var pattern: Bool { UserDefaults.standard.bool(forKey: patternKey) }

    static func reset() {
        for key in [highlightKey, shadowKey, patternKey] { UserDefaults.standard.removeObject(forKey: key) }
    }
}
