import Foundation

/// What focus peaking looks for (V-06).
public enum PeakingMode: String, CaseIterable, Sendable {
    /// Gradient magnitude (Sobel) of the luma: the outlines of what is sharp.
    case edges
    /// High-pass (Laplacian) of the luma, with a lower threshold: texture and small detail, and some noise.
    case fineDetail

    public var title: String {
        switch self {
        case .edges: "Edges"
        case .fineDetail: "Fine detail"
        }
    }

    public var other: PeakingMode { self == .edges ? .fineDetail : .edges }
}

/// How the overlay looks and how strict it is. `nil` where a `PeakingStyle?` is taken means peaking is off.
public struct PeakingStyle: Equatable, Sendable {
    public var mode: PeakingMode
    /// Overlay color, each channel 0...1, in the picture's own color space.
    public var color: SIMD3<Float>
    /// 0 marks only the strongest edges, 1 marks faint ones too. See ``PeakingThreshold``.
    public var sensitivity: Double

    public static let defaultColor = SIMD3<Float>(1, 0, 1)
    public static let defaultSensitivity = 0.5

    public init(mode: PeakingMode = .edges, color: SIMD3<Float> = defaultColor, sensitivity: Double = defaultSensitivity) {
        self.mode = mode
        self.color = color
        self.sensitivity = sensitivity
    }
}

/// The meaning of the sensitivity slider, kept apart from the GPU code so it can be tested.
///
/// The edge strength is stored as a luma step: a clean jump of `d` (0...1, encoded values) between two neighboring
/// pixels reads as `d` in both modes. The mask keeps the square root of it, which gives the dark end of an 8-bit
/// texture more steps; ``stored`` is the same companding applied to a threshold.
public enum PeakingThreshold {
    /// The luma step that Edges needs at sensitivity 0 and at 1. Between them the scale is geometric, so each
    /// notch of the slider changes the strictness by the same factor. Tune by eye.
    public static let strictest = 0.30
    public static let loosest = 0.02

    /// The luma step (0...1) a pixel must show to be marked. Both modes use one scale: the Fine detail kernel is
    /// divided so that the same amount of sensor noise passes at the same setting in either (see `peakFine`).
    public static func lumaStep(sensitivity: Double, mode: PeakingMode) -> Double {
        let s = min(max(sensitivity.isFinite ? sensitivity : PeakingStyle.defaultSensitivity, 0), 1)
        return strictest * pow(loosest / strictest, s)
    }

    /// The same threshold on the mask's stored scale (the square root of the step).
    public static func stored(sensitivity: Double, mode: PeakingMode) -> Float {
        Float(lumaStep(sensitivity: sensitivity, mode: mode).squareRoot())
    }
}
