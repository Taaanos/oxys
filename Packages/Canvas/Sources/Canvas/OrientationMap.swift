import CoreGraphics
import ImageIO

/// Where each corner of the upright (displayed) image reads from in the stored pixels, for an EXIF orientation.
/// Texture coordinates run 0...1 with the origin at the stored image's top left, so the GPU does the rotation
/// and the decoded pixels never need rewriting.
public struct OrientationMap: Sendable, Equatable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomLeft: CGPoint
    public var bottomRight: CGPoint

    public init(_ orientation: CGImagePropertyOrientation) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch orientation {
        case .up:            (topLeft, topRight, bottomLeft, bottomRight) = (p(0, 0), p(1, 0), p(0, 1), p(1, 1))
        case .upMirrored:    (topLeft, topRight, bottomLeft, bottomRight) = (p(1, 0), p(0, 0), p(1, 1), p(0, 1))
        case .down:          (topLeft, topRight, bottomLeft, bottomRight) = (p(1, 1), p(0, 1), p(1, 0), p(0, 0))
        case .downMirrored:  (topLeft, topRight, bottomLeft, bottomRight) = (p(0, 1), p(1, 1), p(0, 0), p(1, 0))
        case .leftMirrored:  (topLeft, topRight, bottomLeft, bottomRight) = (p(0, 0), p(0, 1), p(1, 0), p(1, 1))
        case .right:         (topLeft, topRight, bottomLeft, bottomRight) = (p(0, 1), p(0, 0), p(1, 1), p(1, 0))
        case .rightMirrored: (topLeft, topRight, bottomLeft, bottomRight) = (p(1, 1), p(1, 0), p(0, 1), p(0, 0))
        case .left:          (topLeft, topRight, bottomLeft, bottomRight) = (p(1, 0), p(1, 1), p(0, 0), p(0, 1))
        @unknown default:    (topLeft, topRight, bottomLeft, bottomRight) = (p(0, 0), p(1, 0), p(0, 1), p(1, 1))
        }
    }

    /// The stored-image position (0...1) that displays at `(x, y)` in the upright image (0...1, top-left origin).
    public func sourcePoint(displayX x: CGFloat, displayY y: CGFloat) -> CGPoint {
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        return lerp(lerp(topLeft, topRight, x), lerp(bottomLeft, bottomRight, x), y)
    }
}

extension CGImagePropertyOrientation {
    /// Whether the displayed width and height are the stored height and width.
    public var swapsAxes: Bool { rawValue >= 5 }
}
