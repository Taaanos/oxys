import CoreGraphics

/// Luminance and RGB histograms of one image (M-17), 256 bins each, over the image's own encoded values.
public struct Histogram: Sendable, Equatable {
    /// Where the pixels came from: the embedded preview in the MVP, the developed RAW from V-02.
    public enum Source: String, Sendable { case preview = "Preview", raw = "RAW" }

    public static let binCount = 256

    public let red: [UInt32]
    public let green: [UInt32]
    public let blue: [UInt32]
    /// Rec. 709 weights on the encoded values (M-17/Q2).
    public let luminance: [UInt32]
    public let pixelCount: Int
    public let source: Source

    public init(red: [UInt32], green: [UInt32], blue: [UInt32], luminance: [UInt32], pixelCount: Int, source: Source) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
        self.pixelCount = pixelCount
        self.source = source
    }

    /// Share of pixels (0...100) in the lowest bin of the most affected of R, G and B.
    public var clippedShadowsPercent: Double { percent([red[0], green[0], blue[0]]) }
    /// Share of pixels (0...100) in the highest bin of the most affected of R, G and B.
    public var clippedHighlightsPercent: Double {
        percent([red[Self.binCount - 1], green[Self.binCount - 1], blue[Self.binCount - 1]])
    }

    private func percent(_ counts: [UInt32]) -> Double {
        pixelCount > 0 ? Double(counts.max() ?? 0) * 100 / Double(pixelCount) : 0
    }

    /// Computes the histograms of `image`. An image larger than `maxEdge` on its long side is first scaled down
    /// to that edge, which keeps the cost near 1 ms whatever the preview size; flat areas, and so clipped
    /// areas, are unchanged by the scaling. Nil only when no bitmap context could be made.
    public static func compute(_ image: CGImage, source: Source, maxEdge: Int = 1024) -> Histogram? {
        let long = max(image.width, image.height)
        let scale = long > maxEdge ? Double(maxEdge) / Double(long) : 1
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return count(rgba: pixels, pixelCount: w * h, source: source)
    }

    /// Bins tightly packed R, G, B, X bytes.
    static func count(rgba pixels: [UInt8], pixelCount: Int, source: Source) -> Histogram {
        var r = [UInt32](repeating: 0, count: binCount), g = r, b = r, l = r
        pixels.withUnsafeBufferPointer { p in
            r.withUnsafeMutableBufferPointer { r in
                g.withUnsafeMutableBufferPointer { g in
                    b.withUnsafeMutableBufferPointer { b in
                        l.withUnsafeMutableBufferPointer { l in
                            for i in 0..<pixelCount {
                                let pr = UInt32(p[i * 4]), pg = UInt32(p[i * 4 + 1]), pb = UInt32(p[i * 4 + 2])
                                r[Int(pr)] += 1
                                g[Int(pg)] += 1
                                b[Int(pb)] += 1
                                // 0.2126, 0.7152, 0.0722 in 16-bit fixed point; the weights sum to 65536.
                                l[Int((13933 * pr + 46871 * pg + 4732 * pb + 32768) >> 16)] += 1
                            }
                        }
                    }
                }
            }
        }
        return Histogram(red: r, green: g, blue: b, luminance: l, pixelCount: pixelCount, source: source)
    }
}
