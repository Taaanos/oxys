import CoreGraphics

extension CGImage {
    /// A copy scaled down so its long edge is `longEdge` (P-02: the 512 px thumbnail comes from the pixels
    /// already decoded for Loupe, not from a second decode). An image that is not larger is returned as is.
    /// Nil only when no bitmap context could be made.
    public func downscaled(longEdge: Int) -> CGImage? {
        let long = max(width, height)
        guard long > longEdge, longEdge > 0 else { return self }
        let scale = Double(longEdge) / Double(long)
        let w = max(1, Int((Double(width) * scale).rounded()))
        let h = max(1, Int((Double(height) * scale).rounded()))
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
