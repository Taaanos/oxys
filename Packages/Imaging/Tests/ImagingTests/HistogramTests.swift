import CoreGraphics
import Foundation
import Testing
@testable import Imaging

@Suite struct HistogramTests {
    private func image(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                bytes[(y * width + x) * 4] = r
                bytes[(y * width + x) * 4 + 1] = g
                bytes[(y * width + x) * 4 + 2] = b
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func flatGrayFillsOneBinInEveryChannel() throws {
        let h = try #require(Histogram.compute(image(width: 16, height: 8) { _, _ in (100, 100, 100) }, source: .preview))
        #expect(h.pixelCount == 128)
        for bins in [h.red, h.green, h.blue, h.luminance] {
            #expect(bins[100] == 128)
            #expect(bins.reduce(0, +) == 128)
        }
    }

    @Test func channelsAreSeparate() throws {
        let h = try #require(Histogram.compute(image(width: 10, height: 10) { _, _ in (255, 0, 128) }, source: .preview))
        #expect(h.red[255] == 100 && h.green[0] == 100 && h.blue[128] == 100)
        // 0.2126 * 255 + 0.0722 * 128 = 63.4
        #expect(h.luminance[63] == 100)
    }

    @Test func halfBlackHalfWhiteClipsBothEnds() throws {
        let h = try #require(Histogram.compute(image(width: 10, height: 10) { x, _ in x < 5 ? (0, 0, 0) : (255, 255, 255) }, source: .preview))
        #expect(h.luminance[0] == 50 && h.luminance[255] == 50)
        #expect(h.clippedShadowsPercent == 50)
        #expect(h.clippedHighlightsPercent == 50)
    }

    @Test func clippingIsThePerChannelMaximum() throws {
        // A quarter of the pixels have only red blown; the rest are mid-gray.
        let h = try #require(Histogram.compute(image(width: 4, height: 4) { x, y in x == 0 ? (255, 90, 90) : (90, 90, 90) }, source: .preview))
        #expect(h.clippedHighlightsPercent == 25)
        #expect(h.clippedShadowsPercent == 0)
    }

    @Test func rampHasOnePixelPerBin() throws {
        let h = try #require(Histogram.compute(image(width: 256, height: 1) { x, _ in (UInt8(x), UInt8(x), UInt8(x)) }, source: .preview))
        #expect(h.red.allSatisfy { $0 == 1 })
        #expect(h.luminance.allSatisfy { $0 == 1 })
    }

    @Test func largeImagesAreScaledDownAndKeepFlatAreas() throws {
        let h = try #require(Histogram.compute(image(width: 400, height: 200) { x, _ in x < 200 ? (0, 0, 0) : (255, 255, 255) },
                                               source: .raw, maxEdge: 100))
        #expect(h.source == .raw)
        #expect(h.pixelCount == 100 * 50)
        // Only the seam column can blend; the flat halves stay in the end bins.
        #expect(h.luminance[0] + h.luminance[255] >= h.pixelCount - 50)
    }
}
