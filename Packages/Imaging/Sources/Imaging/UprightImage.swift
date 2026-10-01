import CoreGraphics
import ImageIO

extension CGImage {
    /// A copy with `orientation` applied, so the pixels are stored the way they are shown. Grid draws these
    /// with a plain layer, which cannot rotate. Nil only when no bitmap context could be made.
    public func upright(_ orientation: CGImagePropertyOrientation) -> CGImage? {
        if orientation == .up { return self }
        let swaps = orientation.swapsAxes
        let w = swaps ? height : width, h = swaps ? width : height
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
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
