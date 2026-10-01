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
