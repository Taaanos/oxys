import CoreGraphics
import ImageIO

extension CGImage {
    /// A copy with `orientation` applied, so the pixels are stored the way they are shown. Grid draws these
    /// with a plain layer, which cannot rotate. Nil only when no bitmap context could be made.
    public func upright(_ orientation: CGImagePropertyOrientation) -> CGImage? {
        if orientation == .up { return self }
        return displayReady(orientation)
    }

    /// True when Core Animation can hand the pixels to the GPU as they are: 8-bit BGRA, premultiplied, rows a
    /// multiple of 64 bytes, and (when `space` is given) already in that color space. Any other layout, or an image
    /// in another space, is converted by a copy on the main thread when the layer is committed (P-08: that copy was
    /// the longest frame of a first Grid pass).
    public func isDisplayReady(in space: CGColorSpace? = nil) -> Bool {
        guard bitsPerComponent == 8, bitsPerPixel == 32, alphaInfo == .premultipliedFirst,
              bitmapInfo.contains(.byteOrder32Little), bytesPerRow % 64 == 0, let own = colorSpace, own.model == .rgb
        else { return false }
        return space.map { CFEqual(own, $0) } ?? true
    }

    /// `upright(_:)` for a layer's `contents` (P-08): always in the layout `isDisplayReady` names, so a thumbnail
    /// decoded on a loader thread costs nothing when it is committed. `space` is the color space of the window the
    /// layer is in; without it the image keeps its own (sRGB when it has none that suits). Returns `self` when it is
    /// already so and needs no rotation. Nil only when no bitmap context could be made.
    public func displayReady(_ orientation: CGImagePropertyOrientation = .up, in target: CGColorSpace? = nil) -> CGImage? {
        if orientation == .up, isDisplayReady(in: target) { return self }
        let swaps = orientation.swapsAxes
        let w = swaps ? height : width, h = swaps ? width : height
        let space = target.flatMap { $0.model == .rgb ? $0 : nil }
            ?? colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: (w * 4 + 63) & ~63, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let (cw, ch) = (CGFloat(width), CGFloat(height))
        // Maps the stored image's rect onto the upright canvas (EXIF 1...8).
        let transform: CGAffineTransform = switch orientation {
        case .up: .identity
        case .upMirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: cw, ty: 0)
        case .down: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: cw, ty: ch)
        case .downMirrored: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: ch)
        case .leftMirrored: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: ch, ty: cw)
        case .right: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: cw)
        case .rightMirrored: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: ch, ty: 0)
        @unknown default: .identity
        }
        context.concatenate(transform)
        context.draw(self, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        return context.makeImage()
    }
}
