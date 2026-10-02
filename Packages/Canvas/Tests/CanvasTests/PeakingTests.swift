import Foundation
import CoreGraphics
import Metal
import Testing
@testable import Canvas

// MARK: helpers

/// A gray picture made from a function of the pixel, as sRGB.
private func gray(_ width: Int, _ height: Int, _ value: (Int, Int) -> Double) -> CGImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let v = UInt8((min(max(value(x, y), 0), 1) * 255).rounded())
            let i = (y * width + x) * 4
            pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func prepared(_ image: CGImage) throws -> PreparedImage {
    let gpu = try #require(LoupeGPU.shared)
    return try #require(gpu.prepare(image, orientation: .up))
}

/// Repeatable noise in 0...1.
private func noise(_ width: Int, _ height: Int) -> [Double] {
    var state: UInt64 = 0x2545F4914F6CDD1D
    return (0..<(width * height)).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 40) / Double(1 << 24)
    }
}

/// `values` blurred with a box of `radius` pixels (0 leaves it alone).
private func boxBlur(_ values: [Double], _ width: Int, _ height: Int, radius: Int) -> [Double] {
    guard radius > 0 else { return values }
    var out = values
    for y in 0..<height {
        for x in 0..<width {
            var sum = 0.0, count = 0.0
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let sx = min(max(x + dx, 0), width - 1), sy = min(max(y + dy, 0), height - 1)
                    sum += values[sy * width + sx]
                    count += 1
                }
            }
            out[y * width + x] = sum / count
        }
    }
    return out
}

// MARK: settings

@Test func sensitivityMapsToAStrictnessThatFallsAsItRises() {
    for mode in PeakingMode.allCases {
        var last = Double.infinity
        for s in stride(from: 0.0, through: 1.0, by: 0.1) {
            let step = PeakingThreshold.lumaStep(sensitivity: s, mode: mode)
            #expect(step < last)
            last = step
        }
    }
    #expect(abs(PeakingThreshold.lumaStep(sensitivity: 0, mode: .edges) - PeakingThreshold.strictest) < 1e-9)
    #expect(abs(PeakingThreshold.lumaStep(sensitivity: 1, mode: .edges) - PeakingThreshold.loosest) < 1e-9)
}

@Test func bothModesShareOneScale() {
    for s in [0.0, 0.5, 1.0] {
        #expect(PeakingThreshold.lumaStep(sensitivity: s, mode: .fineDetail) == PeakingThreshold.lumaStep(sensitivity: s, mode: .edges))
    }
}

@Test func sensitivityOutOfRangeOrNotANumberStaysInRange() {
    #expect(PeakingThreshold.lumaStep(sensitivity: -3, mode: .edges) == PeakingThreshold.lumaStep(sensitivity: 0, mode: .edges))
    #expect(PeakingThreshold.lumaStep(sensitivity: 9, mode: .edges) == PeakingThreshold.lumaStep(sensitivity: 1, mode: .edges))
    let fromNaN = PeakingThreshold.lumaStep(sensitivity: .nan, mode: .edges)
    #expect(fromNaN == PeakingThreshold.lumaStep(sensitivity: PeakingStyle.defaultSensitivity, mode: .edges))
}

@Test func storedThresholdIsTheSquareRootOfTheStep() {
    let step = PeakingThreshold.lumaStep(sensitivity: 0.5, mode: .edges)
    #expect(abs(Double(PeakingThreshold.stored(sensitivity: 0.5, mode: .edges)) - step.squareRoot()) < 1e-6)
}

@Test func modeSwitchesBetweenTheTwo() {
    #expect(PeakingMode.edges.other == .fineDetail)
    #expect(PeakingMode.fineDetail.other == .edges)
}

@Test func levelCountReachesOneByOneButStopsAtTheCap() {
    #expect(PeakingGPU.levelCount(width: 1, height: 1) == 1)
    #expect(PeakingGPU.levelCount(width: 4, height: 2) == 3)
    #expect(PeakingGPU.levelCount(width: 37, height: 21) == 6)
    #expect(PeakingGPU.levelCount(width: 6000, height: 4000) == PeakingGPU.maxLevels)
}

// MARK: the analysis on the GPU

@Test func aFlatPictureHasNothingToMark() throws {
    let gpu = try #require(LoupeGPU.shared)
    let image = try prepared(gray(64, 48) { _, _ in 0.5 })
    for mode in PeakingMode.allCases {
        let mask = try #require(gpu.peakingMaskBytes(of: image, mode: mode))
        #expect(mask.bytes.allSatisfy { $0 == 0 })
        #expect(gpu.peakingDensity(of: image, style: PeakingStyle(mode: mode)) == 0)
    }
}

@Test func aCleanStepIsMarkedAtTheEdgeAndNowhereElse() throws {
    let gpu = try #require(LoupeGPU.shared)
    // Black on the left, white from column 32: the strongest possible step.
    let image = try prepared(gray(64, 16) { x, _ in x < 32 ? 0 : 1 })
    let mask = try #require(gpu.peakingMaskBytes(of: image, mode: .edges))
    func column(_ x: Int) -> UInt8 { mask.bytes[8 * mask.width + x] }
    #expect(column(31) == 255 && column(32) == 255)
    // The smoothing before the gradient widens the edge by a pixel on each side, and no more.
    #expect(column(30) > 0 && column(33) > 0 && column(30) < 255)
    #expect(column(28) == 0 && column(35) == 0 && column(0) == 0 && column(63) == 0)
}

@Test func aCleanStepReadsItsSizeInEdgesAndSomethingInFineDetail() throws {
    // A clean jump of d reads d in Edges. Fine detail is scaled to match Edges on noise, so it reads about a third.
    let gpu = try #require(LoupeGPU.shared)
    let image = try prepared(gray(64, 16) { x, _ in x < 32 ? 0.2 : 0.6 })
    let edges = try #require(gpu.peakingMaskBytes(of: image, mode: .edges))
    let fine = try #require(gpu.peakingMaskBytes(of: image, mode: .fineDetail))
    let step = 0.4
    // Stored values are square roots of the step.
    let expected = Int((step.squareRoot() * 255).rounded())
    #expect(abs(Int(edges.bytes[8 * 64 + 32]) - expected) <= 2)
    #expect(fine.bytes[8 * 64 + 32] > 0 && fine.bytes[8 * 64 + 20] == 0)
}

@Test func moreBlurMeansLessDensityInBothModes() throws {
    let gpu = try #require(LoupeGPU.shared)
    let w = 96, h = 96
    let base = noise(w, h)
    for mode in PeakingMode.allCases {
        let densities = try [0, 1, 2, 4].map { radius -> Double in
            let values = boxBlur(base, w, h, radius: radius)
            let image = try prepared(gray(w, h) { x, y in values[y * w + x] })
            return try #require(gpu.peakingDensity(of: image, style: PeakingStyle(mode: mode)))
        }
        #expect(densities[0] > densities[1] && densities[1] > densities[2] && densities[2] > densities[3], "\(mode): \(densities)")
    }
}

@Test func higherSensitivityMarksAtLeastAsMuch() throws {
    let gpu = try #require(LoupeGPU.shared)
    let values = boxBlur(noise(64, 64), 64, 64, radius: 1)
    let image = try prepared(gray(64, 64) { x, y in values[y * 64 + x] })
    let densities = try stride(from: 0.0, through: 1.0, by: 0.25).map {
        try #require(gpu.peakingDensity(of: image, style: PeakingStyle(sensitivity: $0)))
    }
    for (a, b) in zip(densities, densities.dropFirst()) { #expect(b >= a) }
    #expect(densities.last! > densities.first!)
}

@Test func theCountsAboveLevelZeroAddUpToThePixelsThatPassed() throws {
    let gpu = try #require(LoupeGPU.shared)
    // A 3 x 3 white patch on black in a 512 x 384 picture: 0.005% of the pixels.
    let image = try prepared(gray(512, 384) { x, y in (200..<203).contains(x) && (100..<103).contains(y) ? 1 : 0 })
    let style = PeakingStyle()
    let base = try #require(gpu.peakingMaskBytes(of: image, mode: .edges, style: style))
    let cut = Int((PeakingThreshold.stored(sensitivity: style.sensitivity, mode: .edges) * 255).rounded(.up))
    let passed = base.bytes.filter { Int($0) >= cut }.count
    #expect(passed > 9)
    let top = try #require(gpu.peakingMaskBytes(of: image, mode: .edges, style: style, level: base.levels - 1))
    #expect(base.levels == PeakingGPU.maxLevels && top.bytes.count == 4 * 3)
    #expect(top.bytes.reduce(0) { $0 + Int($1) } == passed)
}

@Test func theLastRowAndColumnOfAnOddSizedPictureAreCounted() throws {
    let gpu = try #require(LoupeGPU.shared)
    // One bright pixel in the bottom right corner of a 37 x 21 picture, where odd sizes drop a row and a column.
    let image = try prepared(gray(37, 21) { x, y in x == 36 && y == 20 ? 1 : 0 })
    let style = PeakingStyle(mode: .fineDetail)
    let base = try #require(gpu.peakingMaskBytes(of: image, mode: .fineDetail, style: style))
    let cut = Int((PeakingThreshold.stored(sensitivity: style.sensitivity, mode: .fineDetail) * 255).rounded(.up))
    let passed = base.bytes.filter { Int($0) >= cut }.count
    #expect(passed > 0)
    let top = try #require(gpu.peakingMaskBytes(of: image, mode: .fineDetail, style: style, level: base.levels - 1))
    #expect(top.bytes.reduce(0) { $0 + Int($1) } == passed)
}

// MARK: the overlay pass

/// Draws the overlay for `image` into a `width` x `height` target (the whole target is the picture) and returns
/// which target pixels were painted.
private func overlayPixels(_ image: PreparedImage, width: Int, height: Int, style: PeakingStyle = PeakingStyle()) throws -> [Bool] {
    let gpu = try #require(LoupeGPU.shared)
    let peaking = try #require(gpu.peaking)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = try #require(gpu.device.makeTexture(descriptor: descriptor))
    let buffer = try #require(gpu.queue.makeCommandBuffer())
    let threshold = PeakingThreshold.stored(sensitivity: style.sensitivity, mode: style.mode)
    let mask = try #require(peaking.makeMask(for: image, mode: style.mode, threshold: threshold, reusing: nil, in: buffer))
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    pass.colorAttachments[0].storeAction = .store
    let encoder = try #require(buffer.makeRenderCommandEncoder(descriptor: pass))
    var quad = Quad(rect: CGRect(x: 0, y: 0, width: width, height: height), in: CGSize(width: width, height: height), map: OrientationMap(.up))
    var params = PeakParams(color: SIMD4(style.color, 1),
                            threshold: threshold,
                            levels: UInt32(mask.levels))
    encoder.setRenderPipelineState(peaking.overlay)
    encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
    encoder.setFragmentTexture(mask.texture, index: 0)
    encoder.setFragmentBytes(&params, length: MemoryLayout<PeakParams>.stride, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    // BGRA: magenta is blue and red lit, green dark.
    return (0..<(width * height)).map { bytes[$0 * 4] > 200 && bytes[$0 * 4 + 2] > 200 && bytes[$0 * 4 + 1] < 50 }
}

@Test func peakingShadersBuild() throws {
    #expect(try #require(LoupeGPU.shared).peaking != nil)
}

@Test func atOneToOneTheOverlayPaintsTheSourcePixelsThatPass() throws {
    let image = try prepared(gray(64, 16) { x, _ in x < 32 ? 0 : 1 })
    let painted = try overlayPixels(image, width: 64, height: 16)
    func at(_ x: Int, _ y: Int) -> Bool { painted[y * 64 + x] }
    #expect(at(31, 8) && at(32, 8))
    #expect(!at(27, 8) && !at(36, 8) && !at(0, 8) && !at(63, 8))
}

@Test func zoomedInEachSourcePixelCoversItsBlock() throws {
    // 4x: source column 32 (the first white one) covers target columns 128...131, and the black one before it 124...127.
    let image = try prepared(gray(64, 16) { x, _ in x < 32 ? 0 : 1 })
    let painted = try overlayPixels(image, width: 256, height: 64)
    func at(_ x: Int, _ y: Int) -> Bool { painted[y * 256 + x] }
    #expect((124...131).allSatisfy { at($0, 30) })
    #expect(!at(100, 30) && !at(160, 30))
}

@Test func zoomedOutASmallSharpAreaIsStillPainted() throws {
    // The 3 x 3 patch is 1/170 of the picture's width. Shown 8 times smaller, it must not vanish.
    let image = try prepared(gray(512, 384) { x, y in (200..<203).contains(x) && (100..<103).contains(y) ? 1 : 0 })
    let painted = try overlayPixels(image, width: 64, height: 48)
    let columns = 23...27, rows = 10...14   // 200/8 = 25, 100/8 = 12.5
    #expect(columns.contains { x in rows.contains { y in painted[y * 64 + x] } })
    // Nothing is painted far from it.
    #expect(!painted[5 * 64 + 5] && !painted[40 * 64 + 50])
}

@Test func zoomedOutAPictureWithoutEdgesStaysClean() throws {
    let image = try prepared(gray(512, 384) { _, _ in 0.4 })
    #expect(try overlayPixels(image, width: 64, height: 48).allSatisfy { !$0 })
}

@Test func zoomedOutNoiseAloneIsNotPainted() throws {
    // Noise of about 2% of the range on a flat picture, shown 8 times smaller. Some single pixels pass the threshold in
    // Fine detail, but isolated ones must not light the picture up.
    let w = 512, h = 384
    let n = noise(w, h)
    let image = try prepared(gray(w, h) { x, y in 0.5 + (n[y * w + x] - 0.5) * 0.08 })
    let painted = try overlayPixels(image, width: 64, height: 48, style: PeakingStyle(mode: .fineDetail))
    #expect(painted.filter { $0 }.count < painted.count / 50)
}

@Test func changingTheThresholdRebuildsTheCountsAndKeepsTheMask() throws {
    let gpu = try #require(LoupeGPU.shared)
    let peaking = try #require(gpu.peaking)
    let values = boxBlur(noise(128, 128), 128, 128, radius: 1)
    let image = try prepared(gray(128, 128) { x, y in values[y * 128 + x] })
    let buffer = try #require(gpu.queue.makeCommandBuffer())
    let mask = try #require(peaking.makeMask(for: image, mode: .edges, threshold: 0.9, reusing: nil, in: buffer))
    peaking.rebuildPyramid(of: mask, threshold: 0.2, in: buffer)
    #expect(mask.pyramidThreshold == 0.2)
    buffer.commit()
    buffer.waitUntilCompleted()
}
