import CoreGraphics
import Testing
@testable import Imaging

private func solid(_ width: Int, _ height: Int, gray: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    var bytes = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
}

@Test func lensIsTheRequestedSquare() throws {
    let lens = try #require(GlassLens.apply(to: solid(160, 120, gray: 0.5), edge: 96, background: 0.2))
    #expect(lens.width == 96 && lens.height == 96)
}

@Test func lensLeavesTheMiddleFlatAndTheCornersClear() throws {
    let lens = try #require(GlassLens.apply(to: solid(160, 160, gray: 0.5), edge: 160, background: 0.2))
    let middle = pixel(lens, 80, 80)
    let flat = pixel(lens, 40, 80)               // inside the rim, on the same flat picture
    #expect(middle.r == flat.r && middle.a == 255)
    #expect(pixel(lens, 0, 0).a == 0)            // outside the rounded corner
    #expect(pixel(lens, 159, 159).a == 0)
    #expect(pixel(lens, 80, 1).a > 0)            // the straight edge is inside the shape
}

@Test func rimIsLitOnTheTopLeftAndShadedOnTheBottomRight() throws {
    let lens = try #require(GlassLens.apply(to: solid(160, 160, gray: 0.5), edge: 160, background: 0.5))
    let flat = pixel(lens, 80, 80).r
    let lit = pixel(lens, 40, 8), shaded = pixel(lens, 120, 151)
    #expect(lit.r > flat + 5)
    #expect(shaded.r < flat - 5)
}

@Test func tooSmallAnEdgeIsRefused() {
    #expect(GlassLens.apply(to: solid(10, 10, gray: 0.5), edge: 4, background: 0.2) == nil)
}

@Test func overlayIsDrawnUnderTheGlass() throws {
    // A red square in the middle: the lens keeps the middle flat, so the mark shows there unchanged.
    let lens = try #require(GlassLens.apply(to: solid(160, 160, gray: 0.5), edge: 160, background: 0.2) { ctx in
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 60, width: 40, height: 40))
    })
    let mark = pixel(lens, 80, 80)
    #expect(mark.r > 200 && mark.g < 40)
    #expect(pixel(lens, 40, 80).g > 100)    // beside the mark the picture is untouched
}

@Test func overlayNearTheEdgeIsBentByTheRim() throws {
    let marked = try #require(GlassLens.apply(to: solid(160, 160, gray: 0.5), edge: 160, background: 0.2) { ctx in
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 6, width: 160, height: 10))   // a stripe 6 to 16 px from the bottom edge, rows 144 to 153
    })
    // On a flat picture row 150 would be solid red. The rim samples from further in, so the stripe is pushed out
    // toward the edge and the pixel is no longer solid red.
    let there = pixel(marked, 80, 150)
    #expect(!(there.r > 240 && there.g < 20))
}
