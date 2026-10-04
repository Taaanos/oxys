import Foundation
import CoreGraphics
import Metal
import Testing
@testable import Canvas

// MARK: helpers

/// An sRGB picture from a function of the pixel that returns 8-bit red, green, blue.
private func picture(_ width: Int, _ height: Int, _ value: (Int, Int) -> (UInt8, UInt8, UInt8)) -> (image: CGImage, pixels: [(UInt8, UInt8, UInt8)]) {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    var list: [(UInt8, UInt8, UInt8)] = []
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = value(x, y)
            let i = (y * width + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
            list.append((r, g, b))
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return (image, list)
}

private func prepared(_ image: CGImage) throws -> PreparedImage {
    let gpu = try #require(LoupeGPU.shared)
    return try #require(gpu.prepare(image, orientation: .up))
}

/// The count a person would do with a loop: the definitions of the story, on the 8-bit values.
private func independentCount(_ pixels: [(UInt8, UInt8, UInt8)], _ t: ClippingThresholds) -> (Int, Int) {
    var high = 0, low = 0
    for (r, g, b) in pixels {
        if Int(r) >= t.highlightByte || Int(g) >= t.highlightByte || Int(b) >= t.highlightByte { high += 1 }
        if Int(r) <= t.shadowByte && Int(g) <= t.shadowByte && Int(b) <= t.shadowByte { low += 1 }
    }
    return (high, low)
}

private func lcg(_ state: inout UInt64) -> UInt8 {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return UInt8(truncatingIfNeeded: state >> 48)
}

// MARK: thresholds

@Test func defaultsAreNinetyEightAndTwoPercent() {
    let t = ClippingThresholds()
    #expect(t.highlight == 98 && t.shadow == 2)
    #expect(t.highlightByte == 250)   // 98% of 255 is 249.9
    #expect(t.shadowByte == 5)        // 2% of 255 is 5.1
}

@Test func theExtremesAreWhatYouExpect() {
    #expect(ClippingThresholds(highlight: 100).highlightByte == 255)
    #expect(ClippingThresholds(shadow: 0).shadowByte == 0)
    #expect(ClippingThresholds(highlight: 50, shadow: 50).highlightByte == 128)
    #expect(ClippingThresholds(highlight: 50, shadow: 50).shadowByte == 127)
}

@Test func valuesAreKeptInRangeAndCannotCross() {
    let t = ClippingThresholds(highlight: 10, shadow: 90)
    #expect(t.highlight == 50 && t.shadow == 50)
    #expect(ClippingThresholds(highlight: 500, shadow: -3) == ClippingThresholds(highlight: 100, shadow: 0))
}

@Test func percentTextIsShortAndHonest() {
    #expect(ClippingStats.text(forPercent: 0, pixels: 0) == "0%")
    #expect(ClippingStats.text(forPercent: 0.0001, pixels: 3) == "<0.1%")
    #expect(ClippingStats.text(forPercent: 0.43, pixels: 100) == "0.4%")
    #expect(ClippingStats.text(forPercent: 12.4, pixels: 100) == "12%")
    let stats = ClippingStats(highlightPixels: 25, shadowPixels: 0, totalPixels: 100)
    #expect(stats.highlightPercent == 25 && stats.shadowPercent == 0)
}

// MARK: the count

@Test func theReadoutEqualsAnIndependentCountOnSyntheticImages() throws {
    let gpu = try #require(LoupeGPU.shared)
    // Random pixels with a lot near both ends, odd sizes, and a size that is not a multiple of the 16 x 16 group.
    for (w, h) in [(37, 23), (64, 48), (301, 97), (1000, 1)] {
        var state: UInt64 = UInt64(w * 31 + h)
        let made = picture(w, h) { _, _ in
            let pick = lcg(&state) % 4
            func channel() -> UInt8 {
                switch pick {
                case 0: 240 &+ lcg(&state) % 16      // near white
                case 1: lcg(&state) % 12             // near black
                default: lcg(&state)
                }
            }
            return (channel(), channel(), channel())
        }
        let image = try prepared(made.image)
        for thresholds in [ClippingThresholds(), ClippingThresholds(highlight: 90, shadow: 10), ClippingThresholds(highlight: 100, shadow: 0), ClippingThresholds(highlight: 75, shadow: 25)] {
            let stats = try #require(gpu.clippingStats(of: image, thresholds: thresholds))
            let (high, low) = independentCount(made.pixels, thresholds)
            #expect(stats.highlightPixels == high, "highlights \(w)x\(h) \(thresholds)")
            #expect(stats.shadowPixels == low, "shadows \(w)x\(h) \(thresholds)")
            #expect(stats.totalPixels == w * h)
        }
    }
}

@Test func anyChannelMakesAHighlightAndAllChannelsMakeAShadow() throws {
    let gpu = try #require(LoupeGPU.shared)
    // Four pixels: pure red channel blown, white, dark in one channel only, black.
    let colors: [(UInt8, UInt8, UInt8)] = [(255, 10, 10), (255, 255, 255), (0, 0, 200), (0, 0, 0)]
    let made = picture(4, 1) { x, _ in colors[x] }
    let stats = try #require(gpu.clippingStats(of: try prepared(made.image), thresholds: ClippingThresholds()))
    // Red-blown and white are highlights; (0, 0, 200) is not (200 is below 250). Only black is a shadow:
    // (0, 0, 200) has one bright channel.
    #expect(stats.highlightPixels == 2)
    #expect(stats.shadowPixels == 1)
}

@Test func aFlatMiddleGrayHasNoClippingAndAWhiteFrameIsAllHighlight() throws {
    let gpu = try #require(LoupeGPU.shared)
    let gray = picture(40, 30) { _, _ in (128, 128, 128) }
    let a = try #require(gpu.clippingStats(of: try prepared(gray.image), thresholds: ClippingThresholds()))
    #expect(a.highlightPixels == 0 && a.shadowPixels == 0)
    let white = picture(40, 30) { _, _ in (255, 255, 255) }
    let b = try #require(gpu.clippingStats(of: try prepared(white.image), thresholds: ClippingThresholds()))
    #expect(b.highlightPixels == 1200 && b.highlightPercent == 100 && b.shadowPixels == 0)
}

// MARK: the overlay pass

/// Draws the overlay for `image` into a `width` x `height` target (the whole target is the picture) and returns
/// (red-painted, blue-painted) per target pixel.
private func overlayPixels(_ image: PreparedImage, width: Int, height: Int, marks: ClippingMarks = [.highlights, .shadows],
                           thresholds: ClippingThresholds = ClippingThresholds(), pattern: Bool = false) throws -> [(red: Bool, blue: Bool)] {
    let gpu = try #require(LoupeGPU.shared)
    let clipping = try #require(gpu.clipping)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = try #require(gpu.device.makeTexture(descriptor: descriptor))
    let buffer = try #require(gpu.queue.makeCommandBuffer())
    let mask = try #require(clipping.makeMask(for: image, thresholds: thresholds, reusing: nil, in: buffer))
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    pass.colorAttachments[0].storeAction = .store
    let encoder = try #require(buffer.makeRenderCommandEncoder(descriptor: pass))
    var quad = Quad(rect: CGRect(x: 0, y: 0, width: width, height: height), in: CGSize(width: width, height: height), map: OrientationMap(.up))
    var params = ClipParams(highlightColor: ClippingGPU.highlightColor, shadowColor: ClippingGPU.shadowColor, levels: UInt32(mask.levels),
                            flags: (marks.contains(.highlights) ? 1 : 0) | (marks.contains(.shadows) ? 2 : 0) | (pattern ? 4 : 0))
    encoder.setRenderPipelineState(clipping.overlay)
    encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
    encoder.setFragmentTexture(mask.texture, index: 0)
    encoder.setFragmentBytes(&params, length: MemoryLayout<ClipParams>.stride, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    // BGRA. Red is mostly red; blue is mostly blue.
    return (0..<(width * height)).map { i in
        let b = bytes[i * 4], g = bytes[i * 4 + 1], r = bytes[i * 4 + 2]
        return (r > 200 && b < 80, b > 200 && r < 80 && g > 60)
    }
}

@Test func shadersBuild() throws {
    #expect(try #require(LoupeGPU.shared).clipping != nil)
}

@Test func atOneToOneRedMarksHighlightsAndBlueMarksShadows() throws {
    // Left third black, middle gray, right third white.
    let made = picture(60, 8) { x, _ in x < 20 ? (0, 0, 0) : x < 40 ? (128, 128, 128) : (255, 255, 255) }
    let painted = try overlayPixels(try prepared(made.image), width: 60, height: 8)
    func at(_ x: Int) -> (red: Bool, blue: Bool) { painted[4 * 60 + x] }
    #expect(at(5).blue && !at(5).red)
    #expect(!at(30).blue && !at(30).red)
    #expect(at(50).red && !at(50).blue)
}

@Test func eachMarkDrawsAlone() throws {
    let made = picture(60, 8) { x, _ in x < 30 ? (0, 0, 0) : (255, 255, 255) }
    let image = try prepared(made.image)
    let onlyHigh = try overlayPixels(image, width: 60, height: 8, marks: .highlights)
    #expect(onlyHigh[4 * 60 + 5] == (false, false) && onlyHigh[4 * 60 + 50].red)
    let onlyLow = try overlayPixels(image, width: 60, height: 8, marks: .shadows)
    #expect(onlyLow[4 * 60 + 5].blue && onlyLow[4 * 60 + 50] == (false, false))
}

@Test func aSmallBlownSpotSurvivesZoomingOut() throws {
    // One white pixel in a mid-gray 512 x 512 picture, shown at 64 x 64 (8x smaller).
    let made = picture(512, 512) { x, y in x == 301 && y == 77 ? (255, 255, 255) : (120, 120, 120) }
    let painted = try overlayPixels(try prepared(made.image), width: 64, height: 64)
    #expect(painted.filter { $0.red }.count >= 1)
    #expect(painted.filter { $0.blue }.isEmpty)
}

@Test func stripesLeaveGapsAndFlatGrayStaysClear() throws {
    let white = picture(48, 48) { _, _ in (255, 255, 255) }
    let striped = try overlayPixels(try prepared(white.image), width: 48, height: 48, pattern: true)
    let marked = striped.filter { $0.red }.count
    #expect(marked > 48 * 48 / 4 && marked < 48 * 48 * 3 / 4)
    let gray = picture(48, 48) { _, _ in (128, 128, 128) }
    #expect(try overlayPixels(try prepared(gray.image), width: 48, height: 48).allSatisfy { !$0.red && !$0.blue })
}

// MARK: kept masks count against the budget (P-06)

@Test func aMaskCountsItsTextureOnceEvenWhenAnotherMaskReusesIt() throws {
    let gpu = try #require(LoupeGPU.shared)
    let clipping = try #require(gpu.clipping), peaking = try #require(gpu.peaking)
    let image = try prepared(picture(64, 48) { _, _ in (128, 128, 128) }.image)
    let buffer = try #require(gpu.queue.makeCommandBuffer())

    let first = try #require(clipping.makeMask(for: image, thresholds: ClippingThresholds(), reusing: nil, in: buffer))
    #expect(first.allocation.bytes == first.texture.allocatedSize && first.allocation.bytes > 0)
    #expect(OverlayMemory.bytes >= first.allocation.bytes)
    // New thresholds on the same picture: the texture is reused, so the bytes belong to one allocation.
    let second = try #require(clipping.makeMask(for: image, thresholds: ClippingThresholds(highlight: 90), reusing: first, in: buffer))
    #expect(second.texture === first.texture && second.allocation === first.allocation)

    let edges = try #require(peaking.makeMask(for: image, mode: .edges, threshold: 0.9, reusing: nil, in: buffer))
    let fine = try #require(peaking.makeMask(for: image, mode: .fineDetail, threshold: 0.9, reusing: edges, in: buffer))
    #expect(fine.texture === edges.texture && fine.allocation === edges.allocation)
    #expect(OverlayMemory.bytes >= first.allocation.bytes + edges.allocation.bytes)
    buffer.commit()
    buffer.waitUntilCompleted()
}
