import Containers
import Foundation

/// Area of an autofocus box as fractions of the sensor frame (both dimensions always present together).
public struct AFAreaSize: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var swapped: AFAreaSize { AFAreaSize(width: height, height: width) }
}

/// Dimensions of a sensor/AF coordinate frame in pixels (both dimensions always present together).
public struct FrameDimensions: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One autofocus point or area as the camera recorded it. Coordinates are fractions (0...1, top-left origin) of
/// the sensor frame the camera reported them in, before the EXIF orientation is applied, so they do not depend on
/// the size of the preview or the RAW (V-01).
public struct AFPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var area: AFAreaSize?

    public var width: Double? { area?.width }
    public var height: Double? { area?.height }

    public init(x: Double, y: Double, area: AFAreaSize? = nil) {
        self.x = x
        self.y = y
        self.area = area
    }

    /// The same point in the upright picture, for a validated EXIF orientation (1...8).
    public func upright(orientation: ExifOrientation) -> AFPoint {
        let (ux, uy): (Double, Double) = switch orientation {
        case .up: (x, y)
        case .upMirrored: (1 - x, y)
        case .down: (1 - x, 1 - y)
        case .downMirrored: (x, 1 - y)
        case .leftMirrored: (y, x)
        case .right: (1 - y, x)
        case .rightMirrored: (1 - y, 1 - x)
        case .left: (y, 1 - x)
        }
        return AFPoint(x: ux, y: uy, area: orientation.swapsAxes ? area?.swapped : area)
    }
}

/// Recorded autofocus points, guaranteed non-empty, paired with the sensor frame size they refer to.
/// Eliminates orphaned frame sizes with empty point lists and half-set `(width, nil)` dimensions.
public struct AFDetection: Sendable, Equatable {
    public let points: [AFPoint]
    public var frameSize: FrameDimensions?

    public init?(points: [AFPoint], frameSize: FrameDimensions? = nil) {
        guard !points.isEmpty else { return nil }
        self.points = points
        self.frameSize = frameSize
    }
}

/// What a camera's maker note adds to the standard EXIF: a lens name where EXIF has none, and where it focused.
public struct MakerNoteInfo: Sendable, Equatable {
    public var lens: String?
    public var afMode: String?
    public var af: AFDetection?
    /// EXIF orientation of the file (1...8): what turns the sensor frame upright.
    public var orientation: ExifOrientation = .up

    public var afPoints: [AFPoint] { af?.points ?? [] }
    public var afFrameWidth: Int? { af?.frameSize?.width }
    public var afFrameHeight: Int? { af?.frameSize?.height }

    public init() {}

    /// Where `Z` goes: the middle of the AF points, in the upright picture (0...1); nil when the camera recorded none.
    public var focusAnchor: AFPoint? {
        guard let af else { return nil }
        let n = Double(af.points.count)
        let mid = AFPoint(x: af.points.reduce(0) { $0 + $1.x } / n, y: af.points.reduce(0) { $0 + $1.y } / n)
        return mid.upright(orientation: orientation)
    }

    /// Rows for the inspector. "Not available" stands in for a brand or a body whose AF data is not read.
    public var afFields: [ExifInfo.Field] {
        var out: [ExifInfo.Field] = []
        if let afMode { out.append(.init("AF mode", afMode)) }
        guard let af, let anchor = focusAnchor else {
            out.append(.init("AF point", "AF data not available"))
            return out
        }
        let percent = "\(Int((anchor.x * 100).rounded()))%, \(Int((anchor.y * 100).rounded()))%"
        let count = af.points.count > 1 ? "\(af.points.count) points, centered at " : ""
        var text = count + percent + " from the top left"
        if let frame = af.frameSize, af.points.count == 1, let p = af.points.first {
            text += " (\(Int((p.x * Double(frame.width)).rounded())), \(Int((p.y * Double(frame.height)).rounded())) in \(frame.width) × \(frame.height))"
        }
        out.append(.init("AF point", text))
        return out
    }
}
