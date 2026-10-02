import Foundation

/// One autofocus point or area as the camera recorded it. Coordinates are fractions (0...1, top-left origin) of
/// the sensor frame the camera reported them in, before the EXIF orientation is applied, so they do not depend on
/// the size of the preview or the RAW (V-01).
public struct AFPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double?
    public var height: Double?

    public init(x: Double, y: Double, width: Double? = nil, height: Double? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The same point in the upright picture, for an EXIF orientation 1...8 (anything else is read as 1).
    public func upright(orientation: Int) -> AFPoint {
        let (ux, uy): (Double, Double) = switch orientation {
        case 2: (1 - x, y)
        case 3: (1 - x, 1 - y)
        case 4: (x, 1 - y)
        case 5: (y, x)
        case 6: (1 - y, x)
        case 7: (1 - y, 1 - x)
        case 8: (y, 1 - x)
        default: (x, y)
        }
        let swaps = orientation >= 5 && orientation <= 8
        return AFPoint(x: ux, y: uy, width: swaps ? height : width, height: swaps ? width : height)
    }
}

/// What a camera's maker note adds to the standard EXIF: a lens name where EXIF has none, and where it focused.
public struct MakerNoteInfo: Sendable, Equatable {
    public var lens: String?
    public var afMode: String?
    public var afPoints: [AFPoint] = []
    /// The frame `afPoints` refer to, in the camera's own pixels, when it said so.
    public var afFrameWidth: Int?
    public var afFrameHeight: Int?
    /// EXIF orientation of the file (1...8): what turns the sensor frame upright.
    public var orientation = 1

    public init() {}

    /// Where `Z` goes: the middle of the AF points, in the upright picture (0...1); nil when the camera recorded none.
    public var focusAnchor: AFPoint? {
        guard !afPoints.isEmpty else { return nil }
        let n = Double(afPoints.count)
        let mid = AFPoint(x: afPoints.reduce(0) { $0 + $1.x } / n, y: afPoints.reduce(0) { $0 + $1.y } / n)
        return mid.upright(orientation: orientation)
    }

    /// Rows for the inspector. "Not available" stands in for a brand or a body whose AF data is not read.
    public var afFields: [ExifInfo.Field] {
        var out: [ExifInfo.Field] = []
        if let afMode { out.append(.init("AF mode", afMode)) }
        guard let anchor = focusAnchor else {
            out.append(.init("AF point", "AF data not available"))
            return out
        }
        let percent = "\(Int((anchor.x * 100).rounded()))%, \(Int((anchor.y * 100).rounded()))%"
        let count = afPoints.count > 1 ? "\(afPoints.count) points, centered at " : ""
        var text = count + percent + " from the top left"
        if let w = afFrameWidth, let h = afFrameHeight, afPoints.count == 1, let p = afPoints.first {
            text += " (\(Int((p.x * Double(w)).rounded())), \(Int((p.y * Double(h)).rounded())) in \(w) × \(h))"
        }
        out.append(.init("AF point", text))
        return out
    }
}
