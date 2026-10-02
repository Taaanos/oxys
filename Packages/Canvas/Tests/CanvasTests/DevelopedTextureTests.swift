import CoreImage
import Testing
@testable import Canvas

/// The RAW path renders a CIImage into a texture; at 1:1 every texel must be one image pixel, upright.
@Test func developedTextureKeepsEveryPixelAndTheirPlace() throws {
    let gpu = try #require(LoupeGPU.shared)
    // 4 x 2 image, CI origin bottom left: top row red, green, blue, white; bottom row black, black, black, black.
    // Colors in Display P3 itself, the texture's encoding, so the primaries come back as 0 and 255.
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIColor { CIColor(red: r, green: g, blue: b, colorSpace: p3)! }
    let top = [color(1, 0, 0), color(0, 1, 0), color(0, 0, 1), color(1, 1, 1)]
    var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 2))
    for (i, color) in top.enumerated() {
        image = CIImage(color: color).cropped(to: CGRect(x: CGFloat(i), y: 1, width: 1, height: 1)).composited(over: image)
    }
    let prepared = try #require(try gpu.prepare(developed: image))
    #expect(prepared.displaySize == CGSize(width: 4, height: 2))
    let read = try #require(gpu.readback(prepared, maxEdge: 4))
    #expect(read.width == 4 && read.height == 2)
    // BGRA. Top-left texel is red, so B 0, G 0, R ~255.
    func texel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * read.width + x) * 4
        return (Int(read.bgra[i + 2]), Int(read.bgra[i + 1]), Int(read.bgra[i]))
    }
    #expect(texel(0, 0).r > 240 && texel(0, 0).g < 20 && texel(0, 0).b < 20)
    #expect(texel(1, 0).g > 240 && texel(1, 0).r < 20)
    #expect(texel(2, 0).b > 240 && texel(2, 0).r < 20)
    #expect(texel(3, 0).r > 240 && texel(3, 0).g > 240 && texel(3, 0).b > 240)
    #expect(texel(0, 1).r < 10 && texel(0, 1).g < 10 && texel(0, 1).b < 10)
}

@Test func readbackPicksTheSmallestLevelWithinTheEdge() throws {
    let gpu = try #require(LoupeGPU.shared)
    let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
    let prepared = try #require(try gpu.prepare(developed: image))
    let read = try #require(gpu.readback(prepared, maxEdge: 100))
    #expect(max(read.width, read.height) <= 100)
    #expect(read.width == 75 && read.height == 50)
}

@Test func cancelledDevelopStopsBeforeRendering() async throws {
    let gpu = try #require(LoupeGPU.shared)
    let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    let task = Task { () -> Bool in
        withUnsafeCurrentTask { $0?.cancel() }
        do { _ = try gpu.prepare(developed: image); return false } catch is CancellationError { return true } catch { return false }
    }
    #expect(await task.value)
}
