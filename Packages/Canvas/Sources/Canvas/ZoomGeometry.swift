import CoreGraphics

/// Fit, or a scale in physical screen pixels per image pixel (1 is 1:1, 2 is 200%).
public enum ZoomLevel: Sendable, Equatable {
    case fit
    case scale(CGFloat)

    /// One image pixel per physical screen pixel.
    public static let actual = ZoomLevel.scale(1)

    public var isFit: Bool { self == .fit }
}

/// What the info strip needs to say about the zoom.
public struct ZoomInfo: Sendable, Equatable {
    public var level: ZoomLevel
    /// Screen pixels per image pixel, in percent of physical pixels (100 is 1:1).
    public var percent: Int

    public var isActualSize: Bool { level == .actual }
}

public enum ZoomDirection: Sendable { case `in`, out }

/// The fixed stops of `=` and `−`.
public enum ZoomSteps {
    /// 25, 50, 100, 200 and 400%, in scale.
    public static let stops: [CGFloat] = [0.25, 0.5, 1, 2, 4]
    /// The most a pinch or a step zooms in.
    public static let maxScale: CGFloat = 4

    /// The next stop from `current` (a scale, in physical pixels per image pixel) towards `direction`: Fit, then
    /// every step above Fit's own scale. Nil when already at the end. Between stops (after a pinch) it goes to
    /// the nearest stop in that direction.
    public static func next(from current: CGFloat, fit: CGFloat, direction: ZoomDirection) -> ZoomLevel? {
        let epsilon: CGFloat = 0.005
        let above = stops.filter { $0 > fit + epsilon }
        switch direction {
        case .in:
            if current < fit - epsilon { return .fit }
            return above.first { $0 > current + epsilon }.map(ZoomLevel.scale)
        case .out:
            if let below = above.last(where: { $0 < current - epsilon }) { return .scale(below) }
            return current > fit + epsilon ? .fit : nil
        }
    }
}

/// Where the image sits when zoomed, in drawable pixels with a top-left origin. All of it is pure so it can be
/// tested without a window.
public enum ZoomGeometry {
    /// Drawable pixels per image pixel at 1:1. A scaled display mode ("More Space") is rendered at a larger
    /// size than the panel and resampled by the system, so one drawable pixel is less than one physical pixel:
    /// the mode's framebuffer width over the panel's native width. 1 at the default mode, and when unknown.
    public static func oneToOneScale(modePixelWidth: Int, nativePixelWidth: Int) -> CGFloat {
        guard modePixelWidth > 0, nativePixelWidth > 0 else { return 1 }
        return CGFloat(modePixelWidth) / CGFloat(nativePixelWidth)
    }

    /// Drawable pixels per image pixel at Fit.
    public static func fitScale(imageSize: CGSize, viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }

    /// The image's rect when `scale` drawable pixels cover one image pixel and `center` (0...1 in the image) is
    /// at the middle of the view. An axis smaller than the view is centered; a larger one never shows a gap at
    /// either edge. The origin is whole pixels, so at 1:1 every image pixel lands on one drawable pixel.
    public static func rect(imageSize: CGSize, viewSize: CGSize, scale: CGFloat, center: CGPoint) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0, scale > 0
        else { return .zero }
        let width = imageSize.width * scale, height = imageSize.height * scale
        func origin(_ size: CGFloat, _ view: CGFloat, _ center: CGFloat) -> CGFloat {
            if size <= view { return ((view - size) / 2).rounded() }
            let wanted = (view / 2 - center * size).rounded()
            return min(0, max(view - size.rounded(), wanted))
        }
        return CGRect(x: origin(width, viewSize.width, center.x), y: origin(height, viewSize.height, center.y),
                      width: width, height: height)
    }

    /// The center that keeps the image point `imagePoint` (0...1) under the view point `viewPoint` at `scale`.
    public static func center(keeping imagePoint: CGPoint, under viewPoint: CGPoint, imageSize: CGSize,
                              viewSize: CGSize, scale: CGFloat) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0, scale > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: imagePoint.x + (viewSize.width / 2 - viewPoint.x) / (imageSize.width * scale),
                       y: imagePoint.y + (viewSize.height / 2 - viewPoint.y) / (imageSize.height * scale))
    }

    /// The image point (0...1) at the middle of the view for a rect, the inverse of ``rect(imageSize:viewSize:scale:center:)``.
    public static func center(of rect: CGRect, viewSize: CGSize) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (viewSize.width / 2 - rect.minX) / rect.width, y: (viewSize.height / 2 - rect.minY) / rect.height)
    }

    /// The center after the content moves by `delta` drawable pixels (a pan), stopping at the image edges. An
    /// axis that fits inside the view does not move.
    public static func panned(center: CGPoint, by delta: CGPoint, imageSize: CGSize, viewSize: CGSize, scale: CGFloat) -> CGPoint {
        let current = rect(imageSize: imageSize, viewSize: viewSize, scale: scale, center: center)
        guard current != .zero else { return center }
        let moved = self.center(of: current.offsetBy(dx: delta.x, dy: delta.y), viewSize: viewSize)
        return self.center(of: rect(imageSize: imageSize, viewSize: viewSize, scale: scale, center: moved), viewSize: viewSize)
    }
}
