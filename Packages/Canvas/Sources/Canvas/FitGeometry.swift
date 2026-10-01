import CoreGraphics

/// Where the image sits in the view at Fit: as large as the view allows, centered, aspect kept.
public enum FitGeometry {
    /// The image's rect in view points. `imageSize` is the upright size in pixels, `viewSize` in points.
    /// With `backingScale` the rect is snapped to whole device pixels so the edges stay crisp.
    public static func fitRect(imageSize: CGSize, viewSize: CGSize, backingScale: CGFloat = 1) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0, backingScale > 0
        else { return .zero }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let width = imageSize.width * scale, height = imageSize.height * scale
        let rect = CGRect(x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2, width: width, height: height)
        func snap(_ v: CGFloat) -> CGFloat { (v * backingScale).rounded() / backingScale }
        let (x0, y0, x1, y1) = (snap(rect.minX), snap(rect.minY), snap(rect.maxX), snap(rect.maxY))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
