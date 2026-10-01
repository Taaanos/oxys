import CoreGraphics

/// Fit or 1:1 (M-15 adds steps between and beyond).
public enum ZoomMode: Sendable, Equatable {
    case fit
    /// One image pixel per physical screen pixel.
    case actual
}

/// What the info strip needs to say about the zoom.
public struct ZoomInfo: Sendable, Equatable {
    public var mode: ZoomMode
    /// Screen pixels per image pixel, in percent of physical pixels (100 is 1:1).
    public var percent: Int
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
}
