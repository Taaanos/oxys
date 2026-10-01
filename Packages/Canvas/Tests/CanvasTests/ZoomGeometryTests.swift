import CoreGraphics
import Testing
@testable import Canvas

@Suite struct ZoomGeometryTests {
    let image = CGSize(width: 6000, height: 4000)
    let view = CGSize(width: 3000, height: 2000)

    @Test func oneToOneIsExactAtTheDefaultMode() {
        #expect(ZoomGeometry.oneToOneScale(modePixelWidth: 3024, nativePixelWidth: 3024) == 1)
    }

    @Test func scaledModeRendersMorePixelsThanThePanelHas() {
        // "More Space": 3600 rendered pixels resampled onto a 3024 pixel panel.
        let s = ZoomGeometry.oneToOneScale(modePixelWidth: 3600, nativePixelWidth: 3024)
        #expect(abs(s - 3600.0 / 3024.0) < 1e-9)
        #expect(ZoomGeometry.oneToOneScale(modePixelWidth: 0, nativePixelWidth: 3024) == 1)
    }

    @Test func oneToOneShowsEveryImagePixelOnOneDrawablePixel() {
        let rect = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: CGPoint(x: 0.5, y: 0.5))
        #expect(rect.size == image)
        #expect(rect.origin.x == -1500 && rect.origin.y == -1000)
        #expect(rect.origin.x == rect.origin.x.rounded())
    }

    @Test func pointUnderPointerStaysUnderPointer() {
        // Fit rect for this image in this view, then zoom to 1:1 with the pointer on an arbitrary spot.
        let fit = ZoomGeometry.fitScale(imageSize: image, viewSize: view)
        let fitRect = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: fit, center: CGPoint(x: 0.5, y: 0.5))
        let pointer = CGPoint(x: 1200, y: 700)
        let u = CGPoint(x: (pointer.x - fitRect.minX) / fitRect.width, y: (pointer.y - fitRect.minY) / fitRect.height)
        let center = ZoomGeometry.center(keeping: u, under: pointer, imageSize: image, viewSize: view, scale: 1)
        let zoomed = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: center)
        let under = CGPoint(x: zoomed.minX + u.x * zoomed.width, y: zoomed.minY + u.y * zoomed.height)
        #expect(abs(under.x - pointer.x) <= 1 && abs(under.y - pointer.y) <= 1)
    }

    @Test func neverShowsAGapAtAnEdge() {
        let corner = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: CGPoint(x: 0, y: 1))
        #expect(corner.minX == 0 && corner.maxY == view.height)
        let far = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: CGPoint(x: 5, y: -5))
        #expect(far.maxX == view.width && far.minY == 0)
    }

    @Test func smallImageIsCenteredNotPanned() {
        let small = CGSize(width: 1000, height: 500)
        let rect = ZoomGeometry.rect(imageSize: small, viewSize: view, scale: 1, center: CGPoint(x: 0, y: 0))
        #expect(rect.origin == CGPoint(x: 1000, y: 750))
    }

    @Test func centerRoundTrips() {
        let c = CGPoint(x: 0.3, y: 0.6)
        let rect = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: c)
        let back = ZoomGeometry.center(of: rect, viewSize: view)
        #expect(abs(back.x - c.x) < 0.001 && abs(back.y - c.y) < 0.001)
    }
}
