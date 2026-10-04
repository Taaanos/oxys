import CoreImage
import Foundation
import Testing
@testable import Imaging

// V-19: lens correction for the developed RAW.

@Test func lensCorrectionStateFollowsTheSettingAndTheCamera() {
    #expect(LensCorrection(requested: false, supported: true) == .off)
    #expect(LensCorrection(requested: false, supported: false) == .off)
    #expect(LensCorrection(requested: true, supported: true) == .applied)
    #expect(LensCorrection(requested: true, supported: false) == .notSupported)
    #expect([LensCorrection.applied, .off, .notSupported].map(\.title) == ["Applied", "Off", "Not supported"])
}

// MARK: - Corpus files (not in the repo; skipped when absent)

private let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData")
/// DJI FC8482, 48 MP: the decoder corrects it from data inside the DNG.
private let supported = corpus.appendingPathComponent("DJI_20260908055536_0845_D.DNG")
/// Canon EOS 7D: the decoder has no correction for it.
private let unsupported = corpus.appendingPathComponent("Canon - EOS 7D - RAW (3_2).CR2")
/// Sony 20 MP: supported, smaller, for the setting-off comparison.
private let sony = corpus.appendingPathComponent("DSC01014.ARW")

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// The developed frame as 8-bit RGBA, rendered the same way every time.
private func pixels(_ filter: CIRAWFilter) throws -> (bytes: [UInt8], extent: CGRect) {
    let image = try #require(filter.outputImage)
    let extent = image.extent
    let width = Int(extent.width), height = Int(extent.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CIContext(options: [.cacheIntermediates: false])
    context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: extent, format: .RGBA8,
                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return (bytes, extent)
}

/// The filter as V-02 set it up before this story: neutral, lens correction off.
private func beforeV19(_ url: URL) throws -> CIRAWFilter {
    let filter = try #require(CIRAWFilter(imageURL: url))
    RawDeveloper.neutralize(filter)
    return filter
}

@Test(.enabled(if: exists(sony)))
func settingOffDevelopsTheSamePixelsAsBefore() throws {
    let off = try RawDeveloper.neutralFilter(for: sony, minLongEdge: 1024, lensCorrection: false)
    #expect(off.isLensCorrectionSupported && !off.isLensCorrectionEnabled)
    #expect(LensCorrection(requested: false, filter: off) == .off)
    #expect(try pixels(off).bytes == pixels(beforeV19(sony)).bytes)
}

@Test(.enabled(if: exists(supported)))
func settingOnCorrectsASupportedCameraAndKeepsTheExtent() throws {
    let off = try RawDeveloper.neutralFilter(for: supported, minLongEdge: 1024, lensCorrection: false)
    let on = try RawDeveloper.neutralFilter(for: supported, minLongEdge: 1024, lensCorrection: true)
    #expect(on.isLensCorrectionEnabled)
    #expect(LensCorrection(requested: true, filter: on) == .applied)
    let a = try pixels(off), b = try pixels(on)
    // The extent is `nativeSize` after orientation; this file is upright, so it is the same size.
    #expect(b.extent == a.extent)
    #expect(b.extent.size == on.nativeSize)
    #expect(a.bytes != b.bytes)
}

@Test(.enabled(if: exists(unsupported)))
func settingOnLeavesAnUnsupportedCameraAsItWas() throws {
    let off = try RawDeveloper.neutralFilter(for: unsupported, minLongEdge: 1024, lensCorrection: false)
    let on = try RawDeveloper.neutralFilter(for: unsupported, minLongEdge: 1024, lensCorrection: true)
    #expect(!on.isLensCorrectionSupported)
    #expect(LensCorrection(requested: true, filter: on) == .notSupported)
    let a = try pixels(off), b = try pixels(on)
    #expect(a.extent == b.extent)
    #expect(a.bytes == b.bytes)
}
