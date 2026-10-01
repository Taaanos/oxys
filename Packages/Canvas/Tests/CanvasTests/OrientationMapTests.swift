import CoreGraphics
import CoreImage
import ImageIO
import Testing
@testable import Canvas

/// A 3×2 image whose six pixels are all different, so any mix-up of axes shows.
private func testImage() -> CGImage {
    let width = 3, height = 2
    var bytes = [UInt8]()
    for i in 0..<(width * height) { bytes += [UInt8(i * 40 + 10), UInt8(255 - i * 30), UInt8(i * 7), 255] }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

private func pixels(of image: CGImage) -> [[UInt8]] {
    let (w, h) = (image.width, image.height)
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (0..<(w * h)).map { Array(bytes[($0 * 4)..<($0 * 4 + 4)]) }
}

@Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt32])
func cornerMapAgreesWithCoreImage(raw: UInt32) throws {
    let orientation = try #require(CGImagePropertyOrientation(rawValue: raw))
    let source = testImage()
    let sourcePixels = pixels(of: source)
    let upright = CIImage(cgImage: source).oriented(orientation)
    let rendered = try #require(CIContext().createCGImage(upright, from: upright.extent))
    let displayed = pixels(of: rendered)

    let (dw, dh) = (rendered.width, rendered.height)
    #expect((dw, dh) == (orientation.swapsAxes ? (2, 3) : (3, 2)))
    let map = OrientationMap(orientation)
    for y in 0..<dh {
        for x in 0..<dw {
            // The center of each displayed pixel, as a fraction of the upright image.
            let p = map.sourcePoint(displayX: (CGFloat(x) + 0.5) / CGFloat(dw), displayY: (CGFloat(y) + 0.5) / CGFloat(dh))
            let sx = Int(p.x * CGFloat(source.width)), sy = Int(p.y * CGFloat(source.height))
            #expect(displayed[y * dw + x] == sourcePixels[sy * source.width + sx], "orientation \(raw) at \(x),\(y)")
        }
    }
}

@Test func fitCentersAndKeepsAspect() {
    let rect = FitGeometry.fitRect(imageSize: CGSize(width: 3000, height: 2000), viewSize: CGSize(width: 1000, height: 1000))
    #expect(rect.width == 1000)
    #expect(abs(rect.height - 667) <= 1)
    #expect(abs(rect.midY - 500) <= 0.5)
    let tall = FitGeometry.fitRect(imageSize: CGSize(width: 2000, height: 3000), viewSize: CGSize(width: 1000, height: 500))
    #expect(abs(tall.width - 333) <= 1)
    #expect(tall.height == 500)
}

@Test func fitSnapsToDevicePixels() {
    let rect = FitGeometry.fitRect(imageSize: CGSize(width: 1616, height: 1080), viewSize: CGSize(width: 801.3, height: 500.7),
                                   backingScale: 2)
    for v in [rect.minX, rect.minY, rect.maxX, rect.maxY] { #expect((v * 2).rounded() == v * 2) }
}

@Test func fitOfEmptyIsZero() {
    #expect(FitGeometry.fitRect(imageSize: .zero, viewSize: CGSize(width: 10, height: 10)) == .zero)
    #expect(FitGeometry.fitRect(imageSize: CGSize(width: 10, height: 10), viewSize: .zero) == .zero)
}

@Test func preparedImageHasMipsAndUprightSize() throws {
    let gpu = try #require(LoupeGPU.shared)
    let prepared = try #require(gpu.prepare(testImage(), orientation: .right))
    #expect(prepared.displaySize == CGSize(width: 2, height: 3))
    #expect(prepared.texture.mipmapLevelCount == 2)
}
