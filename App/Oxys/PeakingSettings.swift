import Canvas
import Foundation

/// The stored settings for focus peaking (V-06), read by Loupe and edited in Settings → Analysis. Each is a user
/// default, so a change applies to the open window at once.
enum PeakingSettings {
    static let modeKey = "peakingMode"
    static let redKey = "peakingRed"
    static let greenKey = "peakingGreen"
    static let blueKey = "peakingBlue"
    static let sensitivityKey = "peakingSensitivity"

    static var mode: PeakingMode {
        UserDefaults.standard.string(forKey: modeKey).flatMap(PeakingMode.init(rawValue:)) ?? .edges
    }

    static var style: PeakingStyle {
        let defaults = UserDefaults.standard
        func channel(_ key: String, _ fallback: Float) -> Float {
            guard let value = defaults.object(forKey: key) as? Double, value.isFinite else { return fallback }
            return Float(min(max(value, 0), 1))
        }
        let fallback = PeakingStyle.defaultColor
        let sensitivity = defaults.object(forKey: sensitivityKey) as? Double ?? PeakingStyle.defaultSensitivity
        return PeakingStyle(mode: mode,
                            color: SIMD3(channel(redKey, fallback.x), channel(greenKey, fallback.y), channel(blueKey, fallback.z)),
                            sensitivity: min(max(sensitivity.isFinite ? sensitivity : PeakingStyle.defaultSensitivity, 0), 1))
    }

    static func setMode(_ mode: PeakingMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    }

    static func reset() {
        for key in [modeKey, redKey, greenKey, blueKey, sensitivityKey] { UserDefaults.standard.removeObject(forKey: key) }
    }
}
