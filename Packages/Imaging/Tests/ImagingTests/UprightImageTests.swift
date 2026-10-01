import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import Imaging

/// A 3 wide, 2 tall image whose pixel (x, y) has red = 10 * (y * 3 + x + 1), read back top row first.
private func marker() -> CGImage {
    var bytes: [UInt8] = []
    for y in 0..<2 { for x in 0..<3 { bytes += [UInt8(10 * (y * 3 + x + 1)), 0, 0, 255] } }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func reds(_ image: CGImage) -> [[Int]] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (0..<h).map { y in (0..<w).map { x in Int(data[(y * w + x) * 4]) / 10 } }
}

@Test func everyExifOrientationMovesPixelsWhereTheSpecSays() throws {
    let source = marker()
    // Stored pixels are 1 2 3 / 4 5 6. Each expectation is the upright picture, top row first.
    let expected: [(CGImagePropertyOrientation, [[Int]])] = [
        (.up, [[1, 2, 3], [4, 5, 6]]),
        (.upMirrored, [[3, 2, 1], [6, 5, 4]]),
        (.down, [[6, 5, 4], [3, 2, 1]]),
        (.downMirrored, [[4, 5, 6], [1, 2, 3]]),
        (.leftMirrored, [[1, 4], [2, 5], [3, 6]]),
        (.right, [[4, 1], [5, 2], [6, 3]]),
        (.rightMirrored, [[6, 3], [5, 2], [4, 1]]),
        (.left, [[3, 6], [2, 5], [1, 4]]),
    ]
    for (orientation, rows) in expected {
        let image = try #require(source.upright(orientation))
        #expect(reds(image) == rows, "orientation \(orientation.rawValue)")
    }
}
