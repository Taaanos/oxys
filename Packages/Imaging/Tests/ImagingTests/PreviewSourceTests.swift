import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Imaging

// MARK: - Synthetic files (no camera files are committed)

/// A real, decodable JPEG of a flat color, optionally with an Exif orientation.
private func makeJPEG(width: Int, height: Int, orientation: UInt32? = nil) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [:]
    if let orientation { props[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(dest, context.makeImage()!, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return out as Data
}

private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
private func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }

/// A little-endian TIFF with IFD0 (optional orientation) whose next IFD holds `jpeg` as a JPEGInterchangeFormat thumbnail
/// large enough to count as a preview.
private func makeTIFFContainer(jpeg: Data, orientation: UInt16? = nil) -> Data {
    var d = Data("II".utf8) + Data([42, 0, 8, 0, 0, 0])
    let ifd0Entries = orientation.map { [(UInt16(0x0112), UInt16(3), UInt32($0))] } ?? []
    let ifd0Size = 2 + ifd0Entries.count * 12 + 4
    let ifd1 = 8 + ifd0Size
    d += le16(UInt16(ifd0Entries.count))
    for e in ifd0Entries { d += le16(e.0) + le16(e.1) + le32(1) + le16(UInt16(e.2)) + Data([0, 0]) }
    d += le32(UInt32(ifd1))
    let blob = ifd1 + 2 + 2 * 12 + 4
    d += le16(2)
    d += le16(0x0201) + le16(4) + le32(1) + le32(UInt32(blob))
    d += le16(0x0202) + le16(4) + le32(1) + le32(UInt32(jpeg.count))
    d += le32(0)
    d += jpeg
    return d
}

private func write(_ data: Data, named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-\(UUID().uuidString)-\(name)")
    try data.write(to: url)
    return url
}

// MARK: - RAW containers

@Test func rawPreviewUsesContainerOrientationWhenJPEGHasNone() throws {
    let url = try write(makeTIFFContainer(jpeg: makeJPEG(width: 1024, height: 683), orientation: 6), named: "a.dng")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try PreviewSource.open(url, isRaw: true)
    let decoded = try source.decodeLoupe()
    #expect(source.kind == .raw)
    #expect(decoded.orientation == .right)
    #expect(decoded.image.width == 1024 && decoded.image.height == 683)
    #expect(decoded.displaySize.width == 683 && decoded.displaySize.height == 1024)
    #expect(source.loupePixelSize?.width == 683)
}

@Test func previewsOwnExifOrientationBeatsTheContainers() throws {
    let url = try write(makeTIFFContainer(jpeg: makeJPEG(width: 1024, height: 683, orientation: 3), orientation: 6), named: "b.dng")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try PreviewSource.open(url, isRaw: true).decodeLoupe().orientation == .down)
}

@Test func loupeDecodesDownToTheRequestedLongEdge() throws {
    let url = try write(makeTIFFContainer(jpeg: makeJPEG(width: 1200, height: 800)), named: "c.dng")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try PreviewSource.open(url, isRaw: true)
    let small = try source.decodeLoupe(maxPixelSize: 600)
    #expect(max(small.image.width, small.image.height) == 600)
    #expect(small.sourceWidth == 1200)
    let never = try source.decodeLoupe(maxPixelSize: 5000)   // never upscaled past the preview
    #expect(never.image.width == 1200)
}

@Test func untaggedPreviewIsSRGBAndInteropR03IsAdobeRGB() throws {
    let url = try write(makeTIFFContainer(jpeg: makeJPEG(width: 800, height: 600)), named: "d.dng")
    defer { try? FileManager.default.removeItem(at: url) }
    let decoded = try PreviewSource.open(url, isRaw: true).decodeLoupe()
    #expect(decoded.image.colorSpace?.name == CGColorSpace.sRGB as CFString)
    #expect(PreviewSource.colorSpace(hasICC: false, interop: "R03").name == CGColorSpace.adobeRGB1998 as CFString)
    #expect(PreviewSource.colorSpace(hasICC: false, interop: "R98").name == CGColorSpace.sRGB as CFString)
    #expect(PreviewSource.colorSpace(hasICC: false, interop: nil).name == CGColorSpace.sRGB as CFString)
}

// MARK: - Originals

@Test func jpegOriginalIsItsOwnPreviewWithItsOrientation() throws {
    let url = try write(makeJPEG(width: 640, height: 480, orientation: 8), named: "e.jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try PreviewSource.open(url, isRaw: false)
    let decoded = try source.decodeLoupe()
    #expect(source.kind == .original)
    #expect(decoded.orientation == .left)
    #expect(decoded.sourceDisplaySize.width == 480)
    let grid = try source.decodeGrid(longEdge: 160)
    #expect(max(grid.image.width, grid.image.height) == 160)
}

// MARK: - Failures

@Test func rawWithNoPreviewThrowsNoPreview() throws {
    let url = try write(Data("II".utf8) + Data([42, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0]), named: "f.dng")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: PreviewError.noPreview) { try PreviewSource.open(url, isRaw: true) }
}

@Test func truncatedRawNeverCrashes() throws {
    let full = makeTIFFContainer(jpeg: makeJPEG(width: 1024, height: 683), orientation: 1)
    for cut in stride(from: 0, to: full.count, by: max(1, full.count / 40)) {
        let url = try write(full.prefix(cut), named: "g.dng")
        defer { try? FileManager.default.removeItem(at: url) }
        // Either it refuses to open, or it opens and decodes or throws: nothing traps.
        if let source = try? PreviewSource.open(url, isRaw: true) { _ = try? source.decodeLoupe() }
    }
}

@Test func corruptJPEGBytesThrowCorrupt() throws {
    var jpeg = makeJPEG(width: 1024, height: 683)
    jpeg.replaceSubrange(20..<jpeg.count, with: Data(repeating: 0xAB, count: jpeg.count - 20))
    let url = try write(makeTIFFContainer(jpeg: jpeg), named: "h.dng")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: (any Error).self) { try PreviewSource.open(url, isRaw: true).decodeLoupe() }
}

@Test func missingFileThrowsUnreadable() {
    let url = URL(fileURLWithPath: "/nonexistent/oxys/x.arw")
    #expect(throws: (any Error).self) { try PreviewSource.open(url, isRaw: true) }
}

@Test func garbageOriginalThrowsCorrupt() throws {
    let url = try write(Data(repeating: 0x42, count: 2000), named: "i.jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try PreviewSource.open(url, isRaw: false)
    #expect(throws: PreviewError.corrupt) { try source.decodeLoupe() }
}

// MARK: - P-02: deferred decode and scaling

@Test func deferredDecodeKeepsSizeOrientationAndPixels() throws {
    let url = try write(makeTIFFContainer(jpeg: makeJPEG(width: 1024, height: 683), orientation: 6), named: "p2a.dng")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try PreviewSource.open(url, isRaw: true)
    let eager = try source.decodeLoupe(maxPixelSize: 8192)
    let deferred = try source.decodeLoupe(maxPixelSize: 8192, deferred: true)
    #expect(deferred.image.width == eager.image.width && deferred.image.height == eager.image.height)
    #expect(deferred.orientation == eager.orientation)
    // Drawing the deferred image gives the pixels the eager one has.
    func firstPixel(_ image: CGImage) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixel
    }
    #expect(firstPixel(deferred.image) == firstPixel(eager.image))
}

@Test func deferredDecodeStillScalesWhenTheLimitIsBelowTheImage() throws {
    let url = try write(makeTIFFContainer(jpeg: makeJPEG(width: 1200, height: 800)), named: "p2b.dng")
    defer { try? FileManager.default.removeItem(at: url) }
    let small = try PreviewSource.open(url, isRaw: true).decodeLoupe(maxPixelSize: 600, deferred: true)
    #expect(max(small.image.width, small.image.height) == 600)
}

@Test func deferredDecodeOfAnOriginalWorks() throws {
    let url = try write(makeJPEG(width: 640, height: 480, orientation: 8), named: "p2c.jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let decoded = try PreviewSource.open(url, isRaw: false).decodeLoupe(maxPixelSize: 8192, deferred: true)
    #expect(decoded.image.width == 640 && decoded.orientation == .left)
}

@Test func downscaledKeepsTheAspectAndNeverEnlarges() throws {
    let big = try #require(makeImage(width: 3000, height: 2000))
    let small = try #require(big.downscaled(longEdge: 512))
    #expect(small.width == 512 && small.height == 341)
    let same = try #require(small.downscaled(longEdge: 512))
    #expect(same.width == 512)
    let tallSource = try #require(makeImage(width: 1000, height: 4000))
    let tall = try #require(tallSource.downscaled(longEdge: 400))
    #expect(tall.width == 100 && tall.height == 400)
}

private func makeImage(width: Int, height: Int) -> CGImage? {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
}

// MARK: - P-03: decode at a fraction of the size

@Test func aSubsampledDecodeHasAFractionOfThePixelsAndKeepsOrientationAndSourceSize() throws {
    let url = try write(makeTIFFContainer(jpeg: makeJPEG(width: 1600, height: 1000), orientation: 6), named: "p3a.dng")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try PreviewSource.open(url, isRaw: true)
    let half = try #require(try source.decodeLoupe(subsampledBy: 2))
    #expect((half.image.width, half.image.height) == (800, 500))
    #expect(half.orientation == .right)
    #expect((half.sourceWidth, half.sourceHeight) == (1600, 1000))
    #expect(half.sourceDisplaySize == (1000, 1600))
    let eighth = try #require(try source.decodeLoupe(subsampledBy: 8))
    #expect((eighth.image.width, eighth.image.height) == (200, 125))
}

@Test func aSubsampledDecodeOfAJpegOriginalWorks() throws {
    let url = try write(makeJPEG(width: 640, height: 480), named: "p3b.jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let quarter = try #require(try PreviewSource.open(url, isRaw: false).decodeLoupe(subsampledBy: 4))
    #expect((quarter.image.width, quarter.image.height) == (160, 120))
}

@Test func theLongEdgeOfThePreviewIsKnownWithoutDecoding() throws {
    let raw = try write(makeTIFFContainer(jpeg: makeJPEG(width: 1600, height: 1000)), named: "p3c.dng")
    let jpeg = try write(makeJPEG(width: 640, height: 480), named: "p3d.jpg")
    defer { try? FileManager.default.removeItem(at: raw); try? FileManager.default.removeItem(at: jpeg) }
    #expect(try PreviewSource.open(raw, isRaw: true).loupeLongEdge == 1600)
    #expect(try PreviewSource.open(jpeg, isRaw: false).loupeLongEdge == 640)
}

// MARK: - B-8: pixel limit

/// A decodable JPEG whose frame header (SOF) says `width` x `height`. The entropy data does not match, so a decode fails,
/// but ImageIO and the locators read the claimed size.
private func makeJPEGClaiming(width: Int, height: Int) -> Data {
    var jpeg = makeJPEG(width: 64, height: 64)
    let marker = (0..<(jpeg.count - 1)).first { jpeg[$0] == 0xFF && (jpeg[$0 + 1] == 0xC0 || jpeg[$0 + 1] == 0xC2) }!
    let sof = marker + 5  // FF C0, length (2), precision (1), then height and width
    jpeg[sof] = UInt8(height >> 8); jpeg[sof + 1] = UInt8(height & 0xFF)
    jpeg[sof + 2] = UInt8(width >> 8); jpeg[sof + 3] = UInt8(width & 0xFF)
    return jpeg
}

@Test func decodedPixelsFollowTheSizeOptions() {
    #expect(PreviewSource.decodedPixels(width: 6000, height: 4000, maxPixelSize: nil, subsample: nil) == 24_000_000)
    #expect(PreviewSource.decodedPixels(width: 6000, height: 4000, maxPixelSize: 3000, subsample: nil) == 3000 * 2000)
    #expect(PreviewSource.decodedPixels(width: 6000, height: 4000, maxPixelSize: 9000, subsample: nil) == 24_000_000)
    #expect(PreviewSource.decodedPixels(width: 6000, height: 4000, maxPixelSize: nil, subsample: 4) == 1500 * 1000)
    #expect(PreviewSource.decodedPixels(width: 65535, height: 65535, maxPixelSize: 8192, subsample: nil) == 8192 * 8192)
}

@Test func theLimitIsAboutTheOutputNotTheSource() throws {
    try PreviewSource.checkSize(width: 65535, height: 65535, maxPixelSize: 8192, subsample: nil)
    try PreviewSource.checkSize(width: 65535, height: 65535, maxPixelSize: nil, subsample: 8)
    try PreviewSource.checkSize(width: 14_000, height: 14_000, maxPixelSize: nil, subsample: nil)
    #expect(throws: PreviewError.tooLarge(megapixels: 4295)) {
        try PreviewSource.checkSize(width: 65535, height: 65535, maxPixelSize: nil, subsample: nil)
    }
    #expect(throws: PreviewError.tooLarge(megapixels: 4295)) {
        try PreviewSource.checkSize(width: 65535, height: 65535, maxPixelSize: 8192, subsample: nil, inputLimited: true)
    }
}

@Test func aHugeJPEGIsRefusedAtFullSizeBeforeItIsDecoded() throws {
    let url = try write(makeJPEGClaiming(width: 65535, height: 65535), named: "huge.jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try PreviewSource.open(url, isRaw: false)
    #expect(throws: PreviewError.tooLarge(megapixels: 4295)) { try source.decodeLoupe() }
    #expect(throws: PreviewError.tooLarge(megapixels: 4295)) { try source.decodeLoupe(maxPixelSize: nil, deferred: true) }
    // Scaled down, the size is allowed: the decode goes ahead and fails on the bad bytes, not on the limit.
    #expect(throws: PreviewError.corrupt) { try source.decodeLoupe(maxPixelSize: 8192, deferred: true) }
    #expect(throws: PreviewError.corrupt) { try source.decodeGrid(longEdge: 320) }
}

@Test func aHugeEmbeddedPreviewIsRefusedAtFullSize() throws {
    let url = try write(makeTIFFContainer(jpeg: makeJPEGClaiming(width: 30000, height: 30000)), named: "huge.dng")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try PreviewSource.open(url, isRaw: true)
    #expect(throws: PreviewError.tooLarge(megapixels: 900)) { try source.decodeLoupe() }
    #expect(PreviewError.tooLarge(megapixels: 900).errorDescription == "Preview too large to show (900 megapixels).")
}
