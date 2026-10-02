import CoreGraphics
import Foundation
import Metal
import Testing
@testable import Canvas

/// A 64×48 image: left half red, right half blue.
private func halves() -> CGImage {
    let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
    return context.makeImage()!
}

/// B, G, R, A bytes of the pixel at (x, y) of a staged view.
private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    for i in 0..<4 { bytes[i] = data[offset + i] }
    return bytes
}

@Test func stagedUploadBuildsTheTextureAndShowsTheCallerTheSamePixels() async throws {
    let gpu = try #require(LoupeGPU.shared)
    let result = try await gpu.prepare(halves(), orientation: .right) { staged in
        (width: staged.image.width, height: staged.image.height, left: pixel(staged.image, x: 4, y: 4),
         right: pixel(staged.image, x: 60, y: 4))
    }
    let (prepared, seen) = try #require(result)
    #expect(prepared.displaySize == CGSize(width: 48, height: 64))
    #expect(prepared.texture.width == 64 && prepared.texture.height == 48)
    #expect(prepared.texture.mipmapLevelCount == 7)
    #expect(seen.width == 64 && seen.height == 48)
    #expect(seen.left[2] > 200 && seen.left[0] < 50)     // red: B G R A order
    #expect(seen.right[0] > 200 && seen.right[2] < 50)   // blue
    // The texture holds the same pixels the caller saw.
    var texel = [UInt8](repeating: 0, count: 4)
    prepared.texture.getBytes(&texel, bytesPerRow: 4, from: MTLRegionMake2D(60, 4, 1, 1), mipmapLevel: 0)
    #expect(texel == seen.right)
}

@Test func stagedUploadMatchesThePlainUpload() async throws {
    let gpu = try #require(LoupeGPU.shared)
    let plain = try #require(gpu.prepare(halves(), orientation: .up))
    let staged = try #require(try await gpu.prepare(halves(), orientation: .up) { _ in 0 }).image
    #expect(staged.byteCost == plain.byteCost)
    var a = [UInt8](repeating: 0, count: 4), b = a
    plain.texture.getBytes(&a, bytesPerRow: 4, from: MTLRegionMake2D(10, 10, 1, 1), mipmapLevel: 0)
    staged.texture.getBytes(&b, bytesPerRow: 4, from: MTLRegionMake2D(10, 10, 1, 1), mipmapLevel: 0)
    #expect(a == b)
}

@Test func stagedUploadOfACancelledTaskThrowsBeforeTheCopy() async throws {
    let gpu = try #require(LoupeGPU.shared)
    let task = Task { () -> Bool in
        withUnsafeCurrentTask { $0?.cancel() }
        do { _ = try await gpu.prepare(halves(), orientation: .up) { _ in 0 }; return false } catch is CancellationError { return true } catch { return false }
    }
    #expect(await task.value)
}

@Test func stagedUploadRefusesAnEmptyOrOversizedImage() async throws {
    let gpu = try #require(LoupeGPU.shared)
    let huge = CGContext(data: nil, width: 16385, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    #expect(try await gpu.prepare(huge, orientation: .up) { _ in 0 } == nil)
}
